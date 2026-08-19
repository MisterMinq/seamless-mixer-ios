import Foundation
import MediaPlayer
import PlaylistCore

/// Turns a Source Selection Hub's current selection into a real, saved
/// playlist — the "Build Mix" action, and the first place the whole stack
/// runs together for real: `MPMediaQuery` item resolution -> `TrackAnalyzer`
/// (for anything not already analyzed) -> `Sequencer` -> persistence via
/// `DatabaseManager`.
///
/// **Resolves all five per-source selection types (genre, playlist, artist,
/// album, songs), plus "whole library" as of 2026-08-20.** Andy's own
/// insight, correctly pointing at real reuse (though "whole library" itself
/// had never actually been wired up before this): the per-track "resolve,
/// analyze if needed, save" loop below is the exact same mechanism
/// `LibraryScanner` (the first-run scan) runs — see that type's own doc
/// comment — just over a bounded source here instead of the whole library.
///
/// **Still has a real safety valve, though, not an unconditional green
/// light.** Andy's real library likely runs to hundreds/thousands of tracks
/// (the Source Selection design notes reference "hundreds of artists"
/// alone) — inline-analyzing all of that synchronously the *first* time
/// "whole library" is used, with nothing analyzed yet, would repeat the
/// exact mistake this project already learned to avoid (Rule 6's sandbox
/// RAM ceiling, the deliberately-8-track-not-whole-library real-audio
/// validation set), and this slice has no true background continuation yet
/// (`LibraryScanner` is foreground-only for now — see its own doc comment).
/// So `performBuild` checks how many of the whole library's tracks are
/// still unanalyzed before committing to an inline analyze loop; a small
/// gap (the common case once `LibraryScanner` has run at least once) still
/// analyzes inline exactly like any other source, but a large gap throws
/// `BuildError.needsLibraryScanFirst` instead of silently grinding through
/// a long, unstoppable foreground wait — directly implementing item 5 of
/// the confirmed "First-Run Library Analysis — UX" design ("a large gap...
/// should prompt to finish the bulk scan first rather than silently
/// stalling on a huge inline wait").
///
/// Entirely unverified against real data — this environment has no media
/// library and Codemagic's Simulator build has none either, same category
/// of gap as `SourceSelectionViewModel`. Needs a real-device check once
/// Andy can install a build.
@MainActor
final class MixBuilder: ObservableObject {
    enum BuildError: Error, LocalizedError {
        case noSupportedSources
        case emptyPool
        case allExcluded
        case databaseUnavailable
        /// **Added 2026-08-20**, alongside "whole library" finally getting
        /// wired up — see `wholeLibraryInlineAnalyzeThreshold`'s own doc
        /// comment for what "too many" means and why.
        case needsLibraryScanFirst(unanalyzedCount: Int)

        var errorDescription: String? {
            switch self {
            case .noSupportedSources:
                return "Pick one or more playlists, genres, artists, albums, or songs to build a mix from."
            case .needsLibraryScanFirst(let unanalyzedCount):
                return "Your whole library hasn't been analyzed yet — \(unanalyzedCount) songs still need it, which would take a while to do right now. Run \"Scan your library\" in Settings first, then try building a whole-library mix again."
            case .emptyPool:
                return "None of the selected songs could be used for a seamless mix."
            case .allExcluded:
                // **Reworded 2026-08-17, refined 2026-08-20** — see
                // `DRMExclusionSummary.message`'s own doc comment: the
                // 2026-08-17 wording avoided blaming a subscription since
                // this app has no reliable way to confirm that's the cause.
                // Andy's 2026-08-20 finding gives a real, actionable next
                // step instead — a track can be listed and playable without
                // being downloaded to the device — so this copy now
                // suggests that directly rather than just "check back later."
                return "None of the songs in this selection can be used for seamless mixing right now — they may not be downloaded to this device yet. Try downloading them in the Music app, or pick a different source."
            case .databaseUnavailable:
                return "Couldn't open the library database."
            }
        }
    }

    @Published private(set) var isBuilding = false
    @Published private(set) var progressText = ""
    @Published var buildError: String?
    /// Set after a successful build/refresh when some of the selected pool
    /// couldn't be included — the confirmed DRM-Exclusion UX's "quiet,
    /// factual line" (e.g. "44 of 47 songs included — 3 aren't available
    /// for seamless mixing"), added 2026-08-14. This was designed back when
    /// the schema/DRM-exclusion behavior was first confirmed but never
    /// actually surfaced anywhere — `Sequencer` was always silently
    /// excluding unanalyzed/DRM-protected tracks with zero visibility into
    /// how many or why, which real-device feedback flagged as indistinguishable
    /// from a real bug (a source with far fewer songs in the built mix than
    /// expected). `nil` when nothing was excluded, so a caller can treat
    /// "show this message" and "don't" with a single optional check.
    @Published private(set) var lastBuildExclusionMessage: String?

    /// - Parameter keepAll: when true, includes every analyzed/DRM-accessible
    ///   track in the pool and ignores `targetSeconds` entirely — the iOS
    ///   equivalent of `playlist_mixer.py`'s `--keep-all`, threaded straight
    ///   through to `Sequencer.sequence(..., keepAll:)`, which already
    ///   supported this. Added 2026-08-14, the UI-level half of a gap real
    ///   feedback surfaced: a bounded source (a genre, an artist) had no way
    ///   to be included in full, only trimmed to a target length.
    /// - Parameter extraCrossfadeSec: **added 2026-08-19**, per Andy's
    ///   direct request ("can the crossfade be extended... a time setting
    ///   how long this can be"). Added on top of each transition's own
    ///   tempo-derived crossfade length (`CrossfadeTiming`), and stored on
    ///   the resulting `Playlist` row itself so Refresh can reuse the same
    ///   choice later without asking again. Defaults to 0 (today's exact
    ///   behavior).
    /// - Parameter useWholeLibrary: **added 2026-08-20.** When true,
    ///   `selectedSources` is ignored and the pool is every song in the
    ///   library (`MediaLibraryResolver.allSongs()`) — see this file's own
    ///   top-of-file doc comment for the safety valve that keeps this from
    ///   turning into an unstoppable foreground wait on a never-scanned
    ///   library.
    /// - Returns: the newly-created `Playlist` on success (caller navigates
    ///   to Playlist Detail with it, per the confirmed Navigation Flow —
    ///   Build Mix lands on Playlist Detail, not back on My Mixes), or `nil`
    ///   on failure (`buildError` is set for the caller's alert).
    @discardableResult
    func build(selectedSources: [SelectedSource], mode: PlaylistMode, targetSeconds: Double, keepAll: Bool = false, extraCrossfadeSec: Double = 0, useWholeLibrary: Bool = false, store: PlaylistStore) async -> Playlist? {
        guard !isBuilding else { return nil }
        isBuilding = true
        buildError = nil
        lastBuildExclusionMessage = nil
        defer { isBuilding = false; progressText = "" }

        do {
            let playlist = try await performBuild(selectedSources: selectedSources, mode: mode, targetSeconds: targetSeconds, keepAll: keepAll, extraCrossfadeSec: extraCrossfadeSec, useWholeLibrary: useWholeLibrary, store: store)
            store.refresh()
            return playlist
        } catch {
            buildError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// A never-scanned library's whole-song pool is treated as "too many to
    /// analyze inline" past this many still-unanalyzed tracks — chosen as a
    /// round number comfortably inside what a single-genre/artist/album
    /// Build Mix already does inline today without complaint, not tuned
    /// against a real measurement. Revisit if it turns out to feel wrong in
    /// either direction once Andy can actually test this against his real
    /// library.
    private let wholeLibraryInlineAnalyzeThreshold = 30

    private func performBuild(selectedSources: [SelectedSource], mode: PlaylistMode, targetSeconds: Double, keepAll: Bool, extraCrossfadeSec: Double, useWholeLibrary: Bool, store: PlaylistStore) async throws -> Playlist {
        // All five confirmed source types (per ADR-7) are resolvable as of
        // 2026-08-16 — `.songs` (individual song picks) was the last
        // holdout, previously filtered out defensively since nothing ever
        // produced a `.songs`-typed `SelectedSource`. `SongPickerView` now
        // does, so no filtering happens here anymore. "Whole library" is
        // handled entirely separately below, as of 2026-08-20 — it was
        // never modeled as a `SelectedSource` (it's the separate
        // `useWholeLibrary` toggle), so this guard only covers the
        // per-source path.
        guard !selectedSources.isEmpty || useWholeLibrary else { throw BuildError.noSupportedSources }

        guard let db = store.db else { throw BuildError.databaseUnavailable }

        progressText = "Finding songs…"
        let items: [MPMediaItem]
        if useWholeLibrary {
            items = MediaLibraryResolver.allSongs()
            let unanalyzedCount = try await countUnanalyzed(items: items, db: db)
            if unanalyzedCount > wholeLibraryInlineAnalyzeThreshold {
                throw BuildError.needsLibraryScanFirst(unanalyzedCount: unanalyzedCount)
            }
        } else {
            items = MediaLibraryResolver.resolveItems(for: selectedSources)
        }
        guard !items.isEmpty else { throw BuildError.emptyPool }

        var pool: [Track] = []
        for (index, item) in items.enumerated() {
            progressText = "Analyzing \(index + 1) of \(items.count)…"
            let track = try await TrackAnalysisCoordinator.upsertAndAnalyzeIfNeeded(item: item, db: db)
            pool.append(track)
        }

        // DRM-Exclusion UX transparency message, computed here (not inside
        // `Sequencer`, which stays unaware of *why* a track didn't qualify)
        // — see `lastBuildExclusionMessage`'s own doc comment for why this
        // was added. `DRMExclusionSummary` (moved into `PlaylistCore`
        // 2026-08-14, alongside `CrossfadeTiming` below, specifically so
        // this logic could be unit-tested — see `DRMExclusionSummaryTests`)
        // mirrors exactly what `Sequencer.sequence` is about to silently
        // filter out via its own `isAnalyzed && hasRawAudioAccess` check,
        // computed independently here so the message reflects the real
        // reason, not a guess.
        let exclusionSummary = DRMExclusionSummary.summarize(pool: pool)
        if exclusionSummary.isAllExcluded {
            throw BuildError.allExcluded
        }
        lastBuildExclusionMessage = exclusionSummary.message

        progressText = "Sequencing…"
        let sequenced = Sequencer.sequence(tracks: pool, targetSeconds: targetSeconds, mode: sequencingMode(for: mode), keepAll: keepAll)
        guard !sequenced.isEmpty else { throw BuildError.emptyPool }

        // A whole-library build has no per-source `SelectedSource`s to name
        // itself from or persist for a later Refresh (per this file's own
        // `useWholeLibrary` doc comment, it was never modeled as one) — so
        // it gets exactly one synthetic source here, matching the "Whole
        // Library" label `.wholeLibrary`'s own doc comment expects. This is
        // what makes `PlaylistNaming.title(for:)` produce "Whole Library
        // Seamless Mix" (its normal 1-source case) and what `Refresh` later
        // reconstructs via `selectedSource(from:)`.
        let effectiveSources = useWholeLibrary
            ? [SelectedSource(id: "wholeLibrary", type: .wholeLibrary, label: "Whole Library")]
            : selectedSources

        progressText = "Saving…"
        return try persist(sequenced: sequenced, sources: effectiveSources, mode: mode, extraCrossfadeSec: extraCrossfadeSec, db: db)
    }

    /// Re-runs sequencing for an already-saved playlist against its own
    /// stored `playlist_sources` and replaces its `playlist_tracks` —
    /// the confirmed "Refresh" overflow-sheet action, and the one Tier 2
    /// item `documentation/Editability_UX_Gap_Analysis.docx` calls out as
    /// most directly delivering on the editability principle ("this is
    /// exactly why the playlist_sources table exists"). Deliberately
    /// reuses `MediaLibraryResolver.resolveItems`/`upsertAndAnalyzeIfNeeded`/
    /// `sequencingMode` rather than duplicating them — the only genuinely
    /// new piece here is replacing the track rows instead of inserting a
    /// new playlist.
    ///
    /// - Note: target duration was never persisted per-playlist (`Playlist`
    ///   has no such column — see CLAUDE.md's schema section), so this
    ///   approximates it from the *current* track list's total duration
    ///   rather than the value used when the playlist was first built,
    ///   which keeps a refresh roughly the same length as before without
    ///   a schema change. Flagged as a deliberate simplification, not an
    ///   oversight — worth a real `target_seconds` column if this proves
    ///   to matter in practice.
    @discardableResult
    func refresh(playlist: Playlist, store: PlaylistStore) async -> Bool {
        guard !isBuilding else { return false }
        isBuilding = true
        buildError = nil
        // `lastBuildExclusionMessage` is reset but not recomputed here --
        // Refresh doesn't currently surface it (kept out of scope for this
        // pass, same "smallest safe slice" reasoning as everywhere else in
        // this file); resetting it at least avoids showing a stale message
        // left over from an earlier Build Mix.
        lastBuildExclusionMessage = nil
        defer { isBuilding = false; progressText = "" }

        do {
            try await performRefresh(playlist: playlist, store: store)
            store.refresh()
            return true
        } catch {
            buildError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private func performRefresh(playlist: Playlist, store: PlaylistStore) async throws {
        guard let db = store.db, let playlistID = playlist.id else { throw BuildError.databaseUnavailable }

        let detail = try db.loadPlaylistDetail(playlistID: playlistID)

        // See `selectedSource(from:)` for how each stored `PlaylistSource`
        // row gets turned back into a resolvable `SelectedSource` -- a
        // playlist built before "whole library" existed as a concept
        // (2026-08-20) has no `.wholeLibrary` row to reconstruct, so this
        // is naturally still just its real per-source picks. A playlist
        // built *after* that has exactly one synthetic `.wholeLibrary`
        // source (see `performBuild`'s own comment), which resolves back
        // to the whole library here too, below.
        let selectedSources = detail.sources.compactMap(selectedSource(from:))
        guard !selectedSources.isEmpty else { throw BuildError.noSupportedSources }

        progressText = "Finding songs…"
        let items = MediaLibraryResolver.resolveItems(for: selectedSources)
        guard !items.isEmpty else { throw BuildError.emptyPool }

        // Same safety valve as `performBuild`'s whole-library path -- a
        // Refresh reconstructs and re-resolves the exact same way a fresh
        // build would, so it can hit the exact same "the library has grown
        // by a lot since this was last built/refreshed" case, just less
        // often in practice.
        if selectedSources.contains(where: { $0.type == .wholeLibrary }) {
            let unanalyzedCount = try await countUnanalyzed(items: items, db: db)
            if unanalyzedCount > wholeLibraryInlineAnalyzeThreshold {
                throw BuildError.needsLibraryScanFirst(unanalyzedCount: unanalyzedCount)
            }
        }

        var pool: [Track] = []
        for (index, item) in items.enumerated() {
            progressText = "Analyzing \(index + 1) of \(items.count)…"
            let track = try await TrackAnalysisCoordinator.upsertAndAnalyzeIfNeeded(item: item, db: db)
            pool.append(track)
        }

        let currentDuration = detail.tracks.reduce(0) { $0 + $1.track.durationSec }
        let targetSeconds = currentDuration > 0 ? currentDuration : 30 * 60

        progressText = "Sequencing…"
        let sequenced = Sequencer.sequence(tracks: pool, targetSeconds: targetSeconds, mode: sequencingMode(for: playlist.mode))
        guard !sequenced.isEmpty else { throw BuildError.emptyPool }

        progressText = "Saving…"
        try replaceTracks(playlistID: playlistID, sequenced: sequenced, extraCrossfadeSec: playlist.extraCrossfadeSec, db: db)
    }

    /// **Added 2026-08-20**, alongside "whole library" — counts how many
    /// of `items` don't already have an analyzed `tracks` row, without
    /// running any analysis itself. `Track.fetchAll(_:keys:)` (a standard
    /// GRDB multi-key convenience, the plural counterpart to `Track
    /// .fetchOne(_:key:)` already used in `TrackAnalysisCoordinator`) reads
    /// every matching row in one query rather than one lookup per item.
    /// Items with no row at all (never seen before) count as unanalyzed
    /// too, same as `TrackAnalysisCoordinator.upsertAndAnalyzeIfNeeded`'s
    /// own `existing?.isAnalyzed` check.
    private func countUnanalyzed(items: [MPMediaItem], db: DatabaseManager) async throws -> Int {
        let ids = items.map { Int64(bitPattern: $0.persistentID) }
        let existingByID: [Int64: Track] = try await db.dbQueue.read { conn in
            let rows = try Track.fetchAll(conn, keys: ids)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentID, $0) })
        }
        return ids.filter { existingByID[$0]?.isAnalyzed != true }.count
    }

    /// Deletes the playlist's existing `playlist_tracks` rows (raw SQL,
    /// same "first non-primary-key query, lower risk as plain SQL" reasoning
    /// `PlaylistDetailLoader` already used) and inserts the newly sequenced
    /// ones — the playlist's own row (name/mode/sources/id) is untouched,
    /// only `updated_at` bumps.
    ///
    /// - Parameter extraCrossfadeSec: the playlist's own already-stored
    ///   `extraCrossfadeSec` (per `Playlist.extraCrossfadeSec`'s own doc
    ///   comment) — Refresh reuses whatever was chosen at the original
    ///   Build Mix, the same way it already reuses `mode`, rather than
    ///   silently resetting to 0.
    private func replaceTracks(playlistID: Int64, sequenced: [Track], extraCrossfadeSec: Double, db: DatabaseManager) throws {
        try db.dbQueue.write { conn in
            try conn.execute(sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?", arguments: [playlistID])

            for (index, track) in sequenced.enumerated() {
                let timing = CrossfadeTiming.timing(for: track, extraSec: extraCrossfadeSec)
                var playlistTrack = PlaylistTrack(
                    playlistID: playlistID,
                    trackPersistentID: track.persistentID,
                    position: index,
                    crossfadeStartOffsetSec: timing.startOffsetSec,
                    crossfadeDurationSec: timing.durationSec,
                    tempoNudgePct: 0
                )
                try playlistTrack.insert(conn)
            }

            if var updatedPlaylist = try Playlist.fetchOne(conn, key: playlistID) {
                updatedPlaylist.updatedAt = Date()
                try updatedPlaylist.update(conn)
            }
        }
    }

    /// Tempo-derived crossfade timing — moved into `PlaylistCore` as
    /// `CrossfadeTiming` on 2026-08-14, alongside `DRMExclusionSummary`
    /// above, specifically so this math could be unit-tested (see
    /// `CrossfadeTimingTests`); this file now just calls it. The two former
    /// `private static func`s that lived here (`crossfadeDurationSec(forBPM:)`,
    /// `crossfadeTiming(for:)`) had no test coverage at all before this move
    /// — a real bug in this exact math (a flat `duration - 5s` placeholder)
    /// shipped from 0.15.5 until real-device listening caught it at 0.19.0,
    /// exactly the kind of regression a unit test would have caught first.

    /// `PlaylistMode` (used by `Playlist`/the mode picker) and `SequencingMode`
    /// (used by `Sequencer.sequence`) are two separate Swift enums with
    /// identical cases/raw-values — a real, pre-existing duplication in the
    /// codebase, not something introduced here. Worth unifying into one
    /// type in a future pass; for now this is an explicit, exhaustive
    /// mapping rather than a raw-value round-trip, so a future case added
    /// to one enum but not the other fails to compile here instead of
    /// silently mismatching.
    private func sequencingMode(for mode: PlaylistMode) -> SequencingMode {
        switch mode {
        case .energyUp: return .energyUp
        case .energyWave: return .energyWave
        case .acousticToFusion: return .acousticToFusion
        case .stay: return .stay
        }
    }

    /// Reconstructs a resolvable `SelectedSource` from a saved
    /// `PlaylistSource` row, the inverse of `persist`'s `sourceValue`
    /// encoding below — genres store their name directly (the natural,
    /// stable lookup key), everything else stores its `persistentID` as a
    /// string (per `PlaylistSource.sourceValue`'s own doc comment: "a genre
    /// name, or an artist's/playlist's/album's persistent ID as a string").
    /// Returns `nil` for a non-genre row whose `sourceValue` doesn't parse
    /// as a persistent ID (defensive against a malformed/pre-this-change
    /// row) rather than crashing — `Refresh` simply won't be able to
    /// re-resolve that one source, same "set aside, don't block" spirit as
    /// everywhere else in this app that deals with a partially-unusable
    /// pool. `.songs` (individual song picks) joined `.artist`/`.album`/
    /// `.playlist`'s persistentID-based reconstruction 2026-08-16, once it
    /// became a real, persistable source type — see `SongPickerView`.
    private func selectedSource(from playlistSource: PlaylistSource) -> SelectedSource? {
        switch playlistSource.sourceType {
        case .genre:
            return SelectedSource(id: "genre:\(playlistSource.sourceValue)", type: .genre, label: playlistSource.sourceLabel)
        case .artist, .album, .playlist, .songs:
            guard let persistentID = MPMediaEntityPersistentID(playlistSource.sourceValue) else { return nil }
            return SelectedSource(
                id: "\(playlistSource.sourceType.rawValue):\(persistentID)", type: playlistSource.sourceType,
                label: playlistSource.sourceLabel, persistentID: persistentID
            )
        case .wholeLibrary:
            // Added 2026-08-20 alongside the case itself -- no persistentID
            // to parse (there was never one to store, see `SourceType
            // .wholeLibrary`'s own doc comment), so this just reconstructs
            // the same synthetic source `performBuild` created originally.
            return SelectedSource(id: "wholeLibrary", type: .wholeLibrary, label: playlistSource.sourceLabel)
        }
    }

    /// - Note: `crossfadeStartOffsetSec`/`crossfadeDurationSec` below are now
    ///   real, tempo-derived transition points (`CrossfadeTiming.timing`), not
    ///   the placeholder `duration - 5s` this used before 2026-08-13's
    ///   real-device-listening fix pass. `tempoNudgePct` is still a
    ///   placeholder (0) — the mixing engine's `AVAudioUnitTimePitch` nodes
    ///   are wired but not driven yet, a separate, not-yet-scoped follow-up
    ///   per CLAUDE.md's "Mixing Engine" section.
    /// - Returns: the persisted `Playlist`, with a real `id` set from the
    ///   insert — Playlist Detail loads its sources/tracks by that id, so
    ///   the caller needs the row back, not just a success flag.
    private func persist(sequenced: [Track], sources: [SelectedSource], mode: PlaylistMode, extraCrossfadeSec: Double, db: DatabaseManager) throws -> Playlist {
        // PlaylistNaming only reads `.sourceLabel` off each element, so a
        // playlistID of 0 here is fine -- these never get persisted, just
        // used to compute the auto-generated name before the real
        // `PlaylistSource` rows (with a real playlistID) are inserted below.
        let namingSources = sources.map {
            PlaylistSource(playlistID: 0, sourceType: $0.type, sourceValue: $0.label, sourceLabel: $0.label)
        }
        let name = PlaylistNaming.title(for: namingSources)

        return try db.dbQueue.write { conn in
            var playlist = Playlist(name: name, mode: mode, extraCrossfadeSec: extraCrossfadeSec)
            try playlist.insert(conn)
            guard let playlistID = playlist.id else { return playlist }

            for source in sources {
                // Per `PlaylistSource.sourceValue`'s own doc comment: a
                // genre stores its name directly (the stable, re-queryable
                // key `MediaLibraryResolver.resolveItems` already uses); everything else
                // stores its `persistentID` so `selectedSource(from:)` can
                // reconstruct an exact, re-resolvable source later (Refresh)
                // rather than matching by display name, which isn't unique.
                let sourceValue = source.type == .genre
                    ? source.label
                    : source.persistentID.map(String.init) ?? source.label
                var playlistSource = PlaylistSource(
                    playlistID: playlistID, sourceType: source.type,
                    sourceValue: sourceValue, sourceLabel: source.label
                )
                try playlistSource.insert(conn)
            }

            for (index, track) in sequenced.enumerated() {
                let timing = CrossfadeTiming.timing(for: track, extraSec: extraCrossfadeSec)
                var playlistTrack = PlaylistTrack(
                    playlistID: playlistID,
                    trackPersistentID: track.persistentID,
                    position: index,
                    crossfadeStartOffsetSec: timing.startOffsetSec,
                    crossfadeDurationSec: timing.durationSec,
                    tempoNudgePct: 0
                )
                try playlistTrack.insert(conn)
            }

            return playlist
        }
    }
}
