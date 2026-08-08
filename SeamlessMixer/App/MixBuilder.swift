import Foundation
import MediaPlayer
import PlaylistCore

/// Turns a Source Selection Hub's current selection into a real, saved
/// playlist — the "Build Mix" action, and the first place the whole stack
/// runs together for real: `MPMediaQuery` item resolution -> `TrackAnalyzer`
/// (for anything not already analyzed) -> `Sequencer` -> persistence via
/// `DatabaseManager`.
///
/// **Deliberately scoped to per-source (genre) selections only, not "whole
/// library."** Andy's real library likely runs to hundreds/thousands of
/// tracks (the Source Selection design notes reference "hundreds of
/// artists" alone). Inline-analyzing that much real audio synchronously the
/// first time this code path ever runs would repeat the exact mistake this
/// project already learned to avoid — Rule 6's sandbox RAM ceiling, and the
/// deliberately-8-track-not-whole-library real-audio validation set. "Whole
/// library" needs the proper background-scan UX (First-Run Library
/// Analysis) first; this is a smaller, safer first cut that proves the
/// pipeline works before that bigger piece gets built.
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
        case databaseUnavailable

        var errorDescription: String? {
            switch self {
            case .noSupportedSources:
                return "\"Use your whole library\" isn't wired up yet — pick one or more genres for now."
            case .emptyPool:
                return "None of the selected songs could be used for a seamless mix."
            case .databaseUnavailable:
                return "Couldn't open the library database."
            }
        }
    }

    @Published private(set) var isBuilding = false
    @Published private(set) var progressText = ""
    @Published var buildError: String?

    /// - Returns: true on success (caller should navigate away/dismiss).
    @discardableResult
    func build(selectedSources: [SelectedSource], mode: PlaylistMode, targetSeconds: Double, store: PlaylistStore) async -> Bool {
        guard !isBuilding else { return false }
        isBuilding = true
        buildError = nil
        defer { isBuilding = false; progressText = "" }

        do {
            try await performBuild(selectedSources: selectedSources, mode: mode, targetSeconds: targetSeconds, store: store)
            store.refresh()
            return true
        } catch {
            buildError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private func performBuild(selectedSources: [SelectedSource], mode: PlaylistMode, targetSeconds: Double, store: PlaylistStore) async throws {
        // Only genre sources are resolvable right now -- Artists/Albums/
        // Playlists don't have real pickers yet (see SourceSelectionHubView),
        // so `selectedSources` should never actually contain those types in
        // practice, but filtering defensively here rather than assuming.
        let genreSources = selectedSources.filter { $0.type == .genre }
        guard !genreSources.isEmpty else { throw BuildError.noSupportedSources }

        guard let db = store.db else { throw BuildError.databaseUnavailable }

        progressText = "Finding songs…"
        let items = resolveMediaItems(for: genreSources)
        guard !items.isEmpty else { throw BuildError.emptyPool }

        var pool: [Track] = []
        for (index, item) in items.enumerated() {
            progressText = "Analyzing \(index + 1) of \(items.count)…"
            let track = try await upsertAndAnalyzeIfNeeded(item: item, db: db)
            pool.append(track)
        }

        progressText = "Sequencing…"
        let sequenced = Sequencer.sequence(tracks: pool, targetSeconds: targetSeconds, mode: mode)
        guard !sequenced.isEmpty else { throw BuildError.emptyPool }

        progressText = "Saving…"
        try persist(sequenced: sequenced, sources: genreSources, mode: mode, db: db)
    }

    /// Genre-only filtered `MPMediaQuery`, de-duplicated across sources (a
    /// song could in principle match more than one selected genre-ish
    /// grouping, though unlikely for genres specifically).
    private func resolveMediaItems(for sources: [SelectedSource]) -> [MPMediaItem] {
        var items: [MPMediaItem] = []
        var seenIDs = Set<MPMediaEntityPersistentID>()
        for source in sources {
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: source.label, forProperty: MPMediaItemPropertyGenre))
            for item in query.items ?? [] where seenIDs.insert(item.persistentID).inserted {
                items.append(item)
            }
        }
        return items
    }

    /// Reuses an already-analyzed `tracks` row if one exists; otherwise
    /// inserts/updates one, running `TrackAnalyzer` for tracks with usable
    /// raw audio access. The actual decode+analyze work is real CPU-bound
    /// work (seconds per track, per `RealAudioValidationTests`' own timing)
    /// so it runs off the main actor via `Task.detached`, keeping
    /// `progressText` updates responsive between tracks.
    private func upsertAndAnalyzeIfNeeded(item: MPMediaItem, db: DatabaseManager) async throws -> Track {
        let persistentID = Int64(bitPattern: item.persistentID)

        let existing: Track? = try db.dbQueue.read { conn in
            try Track.fetchOne(conn, key: persistentID)
        }
        if let existing, existing.isAnalyzed {
            return existing
        }

        let hasAccess = item.assetURL != nil
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

        if hasAccess, let url = item.assetURL {
            do {
                let features = try await Task.detached(priority: .userInitiated) {
                    try TrackAnalyzer.analyze(fileAt: url)
                }.value
                track.bpm = features.bpm
                track.musicalKey = features.camelotCode
                track.energy = features.energy
                track.brightness = features.brightness
                track.analyzedAt = Date()
            } catch {
                // Leave unanalyzed -- Sequencer's own isAnalyzed filter
                // silently excludes it later, the same "set aside, don't
                // block" behavior as DRM-Exclusion UX, just triggered by a
                // decode failure instead of a DRM check.
            }
        }

        try db.dbQueue.write { conn in
            try track.save(conn)
        }
        return track
    }

    /// - Note: crossfade/tempo-nudge values below are schema-valid
    ///   placeholders, not real transition points -- the AVAudioEngine
    ///   mixing engine that would compute those doesn't exist yet (still a
    ///   first-pass design, per CLAUDE.md's "Mixing Engine" section).
    ///   Revisit once that's built; a saved playlist is still a legitimate,
    ///   correctly-sequenced recipe without it, it just can't be *played*
    ///   with real crossfades yet.
    private func persist(sequenced: [Track], sources: [SelectedSource], mode: PlaylistMode, db: DatabaseManager) throws {
        // PlaylistNaming only reads `.sourceLabel` off each element, so a
        // playlistID of 0 here is fine -- these never get persisted, just
        // used to compute the auto-generated name before the real
        // `PlaylistSource` rows (with a real playlistID) are inserted below.
        let namingSources = sources.map {
            PlaylistSource(playlistID: 0, sourceType: $0.type, sourceValue: $0.label, sourceLabel: $0.label)
        }
        let name = PlaylistNaming.title(for: namingSources)

        try db.dbQueue.write { conn in
            var playlist = Playlist(name: name, mode: mode)
            try playlist.insert(conn)
            guard let playlistID = playlist.id else { return }

            for source in sources {
                var playlistSource = PlaylistSource(
                    playlistID: playlistID, sourceType: source.type,
                    sourceValue: source.label, sourceLabel: source.label
                )
                try playlistSource.insert(conn)
            }

            for (index, track) in sequenced.enumerated() {
                var playlistTrack = PlaylistTrack(
                    playlistID: playlistID,
                    trackPersistentID: track.persistentID,
                    position: index,
                    crossfadeStartOffsetSec: max(0, track.durationSec - 5),
                    tempoNudgePct: 0
                )
                try playlistTrack.insert(conn)
            }
        }
    }
}
