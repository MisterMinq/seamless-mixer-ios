import Foundation
import GRDB

/// A flattened join of one `PlaylistTrack` row (order, transition fields)
/// and its `Track` (title/artist/duration) — Playlist Detail only needs
/// display fields from both, not the full underlying records separately.
public struct PlaylistTrackDetail: Identifiable, Equatable {
    public let id: Int64
    public let position: Int
    public let track: Track
    /// Where in this track (in seconds from the start) the crossfade into
    /// the *next* track should begin — meaningless for the last track in a
    /// playlist, since there's nothing after it to blend into. Carried
    /// through here so `PlaybackEngine` can actually time the crossfade
    /// against the confirmed "Mixing Engine — AVAudioEngine Design" instead
    /// of only knowing which tracks to play, not when to start blending
    /// them.
    public let crossfadeStartOffsetSec: Double
    /// How long the blend into the next track lasts, in seconds — see
    /// `PlaylistTrack.crossfadeDurationSec`'s doc comment.
    public let crossfadeDurationSec: Double

    public init(id: Int64, position: Int, track: Track, crossfadeStartOffsetSec: Double, crossfadeDurationSec: Double) {
        self.id = id
        self.position = position
        self.track = track
        self.crossfadeStartOffsetSec = crossfadeStartOffsetSec
        self.crossfadeDurationSec = crossfadeDurationSec
    }
}

extension DatabaseManager {
    /// Loads everything Playlist Detail needs to render: the sources that
    /// built this playlist (for the subtitle/footer text, per
    /// `PlaylistNaming`) and its tracks in order (for the track list).
    ///
    /// Deliberately raw SQL (`fetchAll(_:sql:arguments:)`) rather than
    /// GRDB's `Columns`/`filter`/`order` query-interface operators — this is
    /// the first query in the codebase to filter/order by anything beyond a
    /// primary key (`fetchOne(_:key:)`), and every prior GRDB surprise in
    /// this project (the `Columns`-visibility fix, the `belongsTo` column-
    /// naming issues) came from exactly this kind of API-shape assumption.
    /// Raw SQL against the exact column names already spelled out in
    /// `DatabaseManager`'s migration is the lower-risk choice here.
    public func loadPlaylistDetail(playlistID: Int64) throws -> (sources: [PlaylistSource], tracks: [PlaylistTrackDetail]) {
        try dbQueue.read { conn in
            let sources = try PlaylistSource.fetchAll(
                conn, sql: "SELECT * FROM playlist_sources WHERE playlist_id = ?", arguments: [playlistID]
            )

            let playlistTracks = try PlaylistTrack.fetchAll(
                conn, sql: "SELECT * FROM playlist_tracks WHERE playlist_id = ? ORDER BY position", arguments: [playlistID]
            )

            let details: [PlaylistTrackDetail] = try playlistTracks.compactMap { playlistTrack in
                guard let track = try Track.fetchOne(conn, key: playlistTrack.trackPersistentID) else {
                    // A track referenced by a saved playlist that's since
                    // disappeared from `tracks` (shouldn't happen given the
                    // FK's `.restrict` delete rule, but a join is a safer
                    // place to be defensive than to force-unwrap).
                    return nil
                }
                return PlaylistTrackDetail(
                    id: playlistTrack.id ?? playlistTrack.trackPersistentID, position: playlistTrack.position,
                    track: track, crossfadeStartOffsetSec: playlistTrack.crossfadeStartOffsetSec,
                    crossfadeDurationSec: playlistTrack.crossfadeDurationSec
                )
            }

            return (sources, details)
        }
    }

    /// Removes one track from an existing playlist and renumbers the
    /// remaining tracks' `position` values to stay contiguous (0...n-1) —
    /// the Tier 3 editability fix for the gap flagged in CLAUDE.md's Rule 8
    /// ("no manual add/remove-track affordance"). Unlike `refresh` (which
    /// rebuilds the whole track list from the playlist's stored sources),
    /// this only touches the one row the user picked, leaving the rest of
    /// the sequence untouched.
    ///
    /// Keyed off `playlist_tracks.id` (the row's own primary key) rather
    /// than `track_persistent_id` — more precise, and avoids ambiguity if a
    /// future change ever allowed a track to appear more than once.
    /// `playlistID` is included in the `DELETE` as a defense-in-depth check,
    /// not because it's strictly needed to disambiguate `id`.
    ///
    /// Same raw-SQL rationale as `loadPlaylistDetail` above: this deletes
    /// and re-orders by something other than a plain primary-key lookup, so
    /// it stays consistent with the project's established "raw SQL for
    /// anything beyond `fetchOne(key:)`" precedent rather than reaching for
    /// GRDB's query-interface operators for the first time here too.
    public func removeTrack(playlistTrackID: Int64, fromPlaylistID playlistID: Int64) throws {
        try dbQueue.write { conn in
            try conn.execute(
                sql: "DELETE FROM playlist_tracks WHERE id = ? AND playlist_id = ?",
                arguments: [playlistTrackID, playlistID]
            )

            let remaining = try PlaylistTrack.fetchAll(
                conn, sql: "SELECT * FROM playlist_tracks WHERE playlist_id = ? ORDER BY position", arguments: [playlistID]
            )
            for (index, var track) in remaining.enumerated() where track.position != index {
                track.position = index
                try track.update(conn)
            }
        }
    }

    /// Persists a manual drag-to-reorder on Playlist Detail — the other half
    /// of the Tier 3 editability gap `removeTrack` above started closing
    /// ("no manual reorder... affordance", CLAUDE.md's Rule 8). The caller
    /// (`PlaylistDetailViewModel.moveTracks`) already reordered its own
    /// local row array for an instant, optimistic UI update; this just
    /// writes that same order's `position` values back to disk.
    ///
    /// `orderedPlaylistTrackIDs` is the full set of `playlist_tracks.id`
    /// values for this playlist, in the caller's desired final order —
    /// each row's `position` is set to its index in that array. Rows whose
    /// `id` doesn't match anything in the playlist (shouldn't happen; the
    /// caller always derives this list from what it just loaded) are
    /// silently skipped rather than throwing, matching `removeTrack`'s
    /// "defensive, not fatal" posture for a mismatch that should be
    /// structurally impossible in practice.
    public func reorderTracks(playlistID: Int64, orderedPlaylistTrackIDs: [Int64]) throws {
        try dbQueue.write { conn in
            for (index, playlistTrackID) in orderedPlaylistTrackIDs.enumerated() {
                guard var track = try PlaylistTrack.fetchOne(
                    conn, sql: "SELECT * FROM playlist_tracks WHERE id = ? AND playlist_id = ?",
                    arguments: [playlistTrackID, playlistID]
                ) else { continue }
                if track.position != index {
                    track.position = index
                    try track.update(conn)
                }
            }
        }
    }
}
