import Foundation
import MediaPlayer
import PlaylistCore

/// Turns a Source Selection Hub's current selection into a real, saved
/// playlist — the "Build Mix" action, and the first place the whole stack
/// runs together for real: `MPMediaQuery` item resolution -> `TrackAnalyzer`
/// (for anything not already analyzed) -> `Sequencer` -> persistence via
/// `DatabaseManager`.
///
/// **Resolves all five per-source selection types now (genre, playlist,
/// artist, album, songs) — still deliberately excludes "whole library."** Andy's
/// real library likely runs to hundreds/thousands of tracks (the Source
/// Selection design notes reference "hundreds of artists" alone).
/// Inline-analyzing that much real audio synchronously the first time this
/// code path ever runs would repeat the exact mistake this project already
/// learned to avoid — Rule 6's sandbox RAM ceiling, and the
/// deliberately-8-track-not-whole-library real-audio validation set. A
/// single genre/artist/album/playlist is a naturally bounded pool the same
/// way genre-only was, so extending resolution to all four carries the same
/// risk profile that already shipped; "whole library" specifically still
/// needs the proper background-scan UX (First-Run Library Analysis) first.
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

        var errorDescription: String? {
            switch self {
            case .noSupportedSources:
                return "\"Use your whole library\" isn't wired up yet — pick one or more playlists, genres, artists, albums, or songs instead."
            case .emptyPool:
                return "None of the selected songs could be used for a seamless mix."
            case .allExcluded:
                // **Reworded 2026-08-17** — see `DRMExclusionSummary.message`'s
                // own doc comment for why this no longer blames a
                // subscription: the signal this app has for "real DRM" turned
                // out to be unreliable against Andy's own, fully-owned
                // library, so the copy no longer claims a specific cause it
                // can't actually back up.
                return "None of the songs in this selection can be used for seamless mixing right now. Try a different source, or check back after your library finishes syncing."
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
    /// - Returns: the newly-created `Playlist` on success (caller navigates
    ///   to Playlist Detail with it, per the confirmed Navigation Flow —
    ///   Build Mix lands on Playlist Detail, not back on My Mixes), or `nil`
    ///   on failure (`buildError` is set for the caller's alert).
    @discardableResult
    func build(selectedSources: [SelectedSource], mode: PlaylistMode, targetSeconds: Double, keepAll: Bool = false, store: PlaylistStore) async -> Playlist? {
        guard !isBuilding else { return nil }
        isBuilding = true
        buildError = nil
        lastBuildExclusionMessage = nil
        defer { isBuilding = false; progressText = "" }

        do {
            let playlist = try await performBuild(selectedSources: selectedSources, mode: mode, targetSeconds: targetSeconds, keepAll: keepAll, store: store)
            store.refresh()
            return playlist
        } catch {
            buildError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    private func performBuild(selectedSources: [SelectedSource], mode: PlaylistMode, targetSeconds: Double, keepAll: Bool, store: PlaylistStore) async throws -> Playlist {
        // All five confirmed source types (per ADR-7) are resolvable as of
        // 2026-08-16 — `.songs` (individual song picks) was the last
        // holdout, previously filtered out defensively since nothing ever
        // produced a `.songs`-typed `SelectedSource`. `SongPickerView` now
        // does, so no filtering happens here anymore. "Whole library" itself
        // is still the one genuinely unsupported case — it was never
        // modeled as a `SelectedSource` at all (it's the separate
        // `useWholeLibrary` toggle), so there's nothing to filter here for
        // it; `hasSelection`/the Hub's own UI already keep Build Mix
        // disabled or erroring for that case upstream of this function.
        guard !selectedSources.isEmpty else { throw BuildError.noSupportedSources }

        guard let db = store.db else { throw BuildError.databaseUnavailable }

        progressText = "Finding songs…"
        let items = MediaLibraryResolver.resolveItems(for: selectedSources)
        guard !items.isEmpty else { throw BuildError.emptyPool }

        var pool: [Track] = []
        for (index, item) in items.enumerated() {
            progressText = "Analyzing \(index + 1) of \(items.count)…"
            let track = try await upsertAndAnalyzeIfNeeded(item: item, db: db)
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

        progressText = "Saving…"
        return try persist(sequenced: sequenced, sources: selectedSources, mode: mode, db: db)
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
        // playlist built (or last refreshed) before "whole library" existed
        // as a concept has no `PlaylistSource` rows for it either way, so
        // there's nothing special to exclude here.
        let selectedSources = detail.sources.compactMap(selectedSource(from:))
        guard !selectedSources.isEmpty else { throw BuildError.noSupportedSources }

        progressText = "Finding songs…"
        let items = MediaLibraryResolver.resolveItems(for: selectedSources)
        guard !items.isEmpty else { throw BuildError.emptyPool }

        var pool: [Track] = []
        for (index, item) in items.enumerated() {
            progressText = "Analyzing \(index + 1) of \(items.count)…"
            let track = try await upsertAndAnalyzeIfNeeded(item: item, db: db)
            pool.append(track)
        }

        let currentDuration = detail.tracks.reduce(0) { $0 + $1.track.durationSec }
        let targetSeconds = currentDuration > 0 ? currentDuration : 30 * 60

        progressText = "Sequencing…"
        let sequenced = Sequencer.sequence(tracks: pool, targetSeconds: targetSeconds, mode: sequencingMode(for: playlist.mode))
        guard !sequenced.isEmpty else { throw BuildError.emptyPool }

        progressText = "Saving…"
        try replaceTracks(playlistID: playlistID, sequenced: sequenced, db: db)
    }

    /// Deletes the playlist's existing `playlist_tracks` rows (raw SQL,
    /// same "first non-primary-key query, lower risk as plain SQL" reasoning
    /// `PlaylistDetailLoader` already used) and inserts the newly sequenced
    /// ones — the playlist's own row (name/mode/sources/id) is untouched,
    /// only `updated_at` bumps.
    private func replaceTracks(playlistID: Int64, sequenced: [Track], db: DatabaseManager) throws {
        try db.dbQueue.write { conn in
            try conn.execute(sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?", arguments: [playlistID])

            for (index, track) in sequenced.enumerated() {
                let timing = CrossfadeTiming.timing(for: track)
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
        }
    }

    /// Reuses an already-analyzed `tracks` row if one exists; otherwise
    /// inserts/updates one, running `TrackAnalyzer` for tracks with usable
    /// raw audio access. The actual decode+analyze work is real CPU-bound
    /// work (seconds per track, per `RealAudioValidationTests`' own timing)
    /// so it runs off the main actor via `Task.detached`, keeping
    /// `progressText` updates responsive between tracks.
    private func upsertAndAnalyzeIfNeeded(item: MPMediaItem, db: DatabaseManager) async throws -> Track {
        let persistentID = Int64(bitPattern: item.persistentID)

        // GRDB resolves `dbQueue.read`/`.write` to their async overloads
        // inside this `async` function (vs. the sync overloads `persist`
        // uses below, since that function isn't `async`) -- both need an
        // explicit `await`, not just `try`.
        let existing: Track? = try await db.dbQueue.read { conn in
            try Track.fetchOne(conn, key: persistentID)
        }
        if let existing, existing.isAnalyzed {
            return existing
        }

        let resolvedURL = await resolveAudioAccess(for: item)
        let hasAccess = resolvedURL != nil
        var track = existing ?? Track(
            persistentID: persistentID,
            title: item.title ?? "Unknown",
            artist: item.artist ?? "Unknown",
            album: item.albumTitle ?? "Unknown",
            genre: item.genre ?? "Unknown",
            durationSec: item.playbackDuration,
            hasRawAudioAccess: hasAccess
        )
        track.hasRawAudioAccess = hasAccess

        if hasAccess, let url = resolvedURL {
            do {
                let features = try await Task.detached(priority: .userInitiated) {
                    try TrackAnalyzer.analyze(fileAt: url)
                }.value
                track.bpm = features.bpm
                track.musicalKey = features.camelotCode
                track.energy = features.energy
                track.brightness = features.brightness
                track.playableStartSec = features.playableStartSec
                track.playableDurationSec = features.playableDurationSec
                track.analyzedAt = Date()
            } catch {
                // Leave unanalyzed -- Sequencer's own isAnalyzed filter
                // silently excludes it later, the same "set aside, don't
                // block" behavior as DRM-Exclusion UX, just triggered by a
                // decode failure instead of a DRM check.
            }
        }

        // `track` is captured as an immutable `let` copy here rather than
        // the closure capturing the outer `var` directly -- GRDB's async
        // `write` runs its closure in a concurrent context, and capturing a
        // mutable var across that boundary is a Swift 6 language-mode
        // error (already flagged as a warning under Swift 5), not just a
        // style preference.
        let finalTrack = track
        try await db.dbQueue.write { conn in
            try finalTrack.save(conn)
        }
        return finalTrack
    }

    /// **Added 2026-08-17, revised the same day.** Andy owns every track on
    /// his phone outright (no Apple Music subscription at all, told
    /// directly, more than once) — yet the DRM-exclusion message kept
    /// telling him real songs were "streamed through your Apple Music
    /// subscription" (10 of 11, then 12 of 16, then still the same message
    /// on a fresh 16-song test after the first attempt at this fix). The
    /// original code trusted a single, un-retried `item.assetURL != nil`
    /// read as proof of real FairPlay DRM — genuinely unsafe, since
    /// `assetURL` is documented as unreliable for a plain local, owned file
    /// (e.g. a transient `nil` right when a bulk `MPMediaQuery` result is
    /// read). The retries below fix that part.
    ///
    /// **The first attempt at this fix also tried to use `item.isCloudItem`
    /// as a second signal** — the idea being that only a track iOS itself
    /// flags as a "cloud item" would be treated as real DRM, with a
    /// stubborn local nil reported as a harmless analysis failure instead.
    /// Andy's own real-device evidence disproved that: the exclusion
    /// message was still showing the identical "streamed through your
    /// Apple Music subscription" wording after that fix shipped, meaning
    /// `isCloudItem` is *also* true for tracks he genuinely owns and has
    /// fully downloaded — a well-documented Apple quirk where a purchased
    /// or catalog-matched track can carry that flag despite being real,
    /// local, playable audio. There is no reliable API available to a
    /// third-party app that can actually distinguish "real, FairPlay-locked
    /// subscription stream" from "a local file iOS happens to flag this
    /// way" — so this app no longer tries to guess. `hasRawAudioAccess`
    /// is back to meaning exactly one thing: "did a real, playable URL
    /// resolve, after retrying." The *reason* it didn't is no longer
    /// claimed anywhere in the UI — see `DRMExclusionSummary.message`'s own
    /// doc comment for the resulting copy change.
    private func resolveAudioAccess(for item: MPMediaItem) async -> URL? {
        if let url = item.assetURL {
            return url
        }
        if let refetched = requeryItem(persistentID: item.persistentID), let url = refetched.assetURL {
            return url
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let refetched = requeryItem(persistentID: item.persistentID), let url = refetched.assetURL {
            return url
        }
        return nil
    }

    private func requeryItem(persistentID: MPMediaEntityPersistentID) -> MPMediaItem? {
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: persistentID, forProperty: MPMediaItemPropertyPersistentID))
        return query.items?.first
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
    private func persist(sequenced: [Track], sources: [SelectedSource], mode: PlaylistMode, db: DatabaseManager) throws -> Playlist {
        // PlaylistNaming only reads `.sourceLabel` off each element, so a
        // playlistID of 0 here is fine -- these never get persisted, just
        // used to compute the auto-generated name before the real
        // `PlaylistSource` rows (with a real playlistID) are inserted below.
        let namingSources = sources.map {
            PlaylistSource(playlistID: 0, sourceType: $0.type, sourceValue: $0.label, sourceLabel: $0.label)
        }
        let name = PlaylistNaming.title(for: namingSources)

        return try db.dbQueue.write { conn in
            var playlist = Playlist(name: name, mode: mode)
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
                let timing = CrossfadeTiming.timing(for: track)
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
