import Foundation
import GRDB

/// A flattened join of one `CustomPlaylistTrack` row and its `Track` —
/// the `CustomPlaylist` equivalent of `PlaylistTrackDetail`, but with no
/// crossfade/tempo fields to carry (see `CustomPlaylistTrack`'s own doc
/// comment for why).
public struct CustomPlaylistTrackDetail: Identifiable, Equatable {
    public let id: Int64
    public let position: Int
    public let track: Track

    public init(id: Int64, position: Int, track: Track) {
        self.id = id
        self.position = position
        self.track = track
    }
}

extension DatabaseManager {
    /// Every saved `CustomPlaylist`, newest-edited first — feeds the
    /// merged/badged Playlists picker (Batch 2) and, later, the New
    /// Playlist flow's "which playlist did you just create" lookups.
    public func loadCustomPlaylists() throws -> [CustomPlaylist] {
        try dbQueue.read { conn in
            try CustomPlaylist.fetchAll(conn, sql: "SELECT * FROM custom_playlists ORDER BY updated_at DESC")
        }
    }

    /// The one `CustomPlaylist` (if any) already copied from a given real
    /// Apple Music playlist — checked before copy-on-edit runs a second
    /// time on the same source playlist, so re-opening it to edit doesn't
    /// silently create a second, diverging copy under the same name.
    public func customPlaylist(originApplePlaylistPersistentID: UInt64) throws -> CustomPlaylist? {
        try dbQueue.read { conn in
            try CustomPlaylist.fetchOne(
                conn, sql: "SELECT * FROM custom_playlists WHERE origin_apple_playlist_persistent_id = ?",
                arguments: [Int64(bitPattern: originApplePlaylistPersistentID)]
            )
        }
    }

    /// Loads one `CustomPlaylist`'s own row plus its songs in order — same
    /// raw-SQL rationale as `loadPlaylistDetail` (this project's established
    /// "raw SQL for anything beyond `fetchOne(key:)`" convention).
    public func loadCustomPlaylistDetail(customPlaylistID: Int64) throws -> (playlist: CustomPlaylist, tracks: [CustomPlaylistTrackDetail])? {
        try dbQueue.read { conn in
            guard let playlist = try CustomPlaylist.fetchOne(conn, key: customPlaylistID) else { return nil }

            let rows = try CustomPlaylistTrack.fetchAll(
                conn, sql: "SELECT * FROM custom_playlist_tracks WHERE custom_playlist_id = ? ORDER BY position",
                arguments: [customPlaylistID]
            )
            let details: [CustomPlaylistTrackDetail] = try rows.compactMap { row in
                guard let track = try Track.fetchOne(conn, key: row.trackPersistentID) else { return nil }
                return CustomPlaylistTrackDetail(id: row.id ?? row.trackPersistentID, position: row.position, track: track)
            }
            return (playlist, details)
        }
    }

    /// Creates an empty (or, via copy-on-edit, about-to-be-filled)
    /// `CustomPlaylist` row. `originApplePlaylistPersistentID` is `nil` for
    /// a plain "New Playlist" creation.
    @discardableResult
    public func createCustomPlaylist(name: String, originApplePlaylistPersistentID: UInt64? = nil) throws -> CustomPlaylist {
        try dbQueue.write { conn in
            var playlist = CustomPlaylist(name: name, originApplePlaylistPersistentID: originApplePlaylistPersistentID)
            try playlist.insert(conn)
            return playlist
        }
    }

    public func renameCustomPlaylist(customPlaylistID: Int64, to newName: String) throws {
        try dbQueue.write { conn in
            guard var playlist = try CustomPlaylist.fetchOne(conn, key: customPlaylistID) else { return }
            playlist.name = newName
            playlist.updatedAt = Date()
            try playlist.update(conn)
        }
    }

    /// `custom_playlist_tracks` rows are declared `ON DELETE CASCADE`
    /// against `custom_playlists.id`, so deleting the playlist row cleans
    /// up its tracks automatically — same pattern `PlaylistStore.delete`
    /// already relies on for `Playlist`.
    public func deleteCustomPlaylist(customPlaylistID: Int64) throws {
        try dbQueue.write { conn in
            if let playlist = try CustomPlaylist.fetchOne(conn, key: customPlaylistID) {
                try playlist.delete(conn)
            }
        }
    }

    /// Ensures a `tracks` row exists for a song before it can be referenced
    /// by `custom_playlist_tracks` (that table's FK is `.restrict` against
    /// `tracks.persistent_id`, same as `playlist_tracks`'s). Deliberately a
    /// **bare metadata insert, not a real analysis** — added to a
    /// `CustomPlaylist` while listening (or copied from an Apple Music
    /// playlist) shouldn't force a synchronous BPM/key/energy analysis pass
    /// just to be added to a list; that cost is paid later, the same way it
    /// already is for every other source type, only once this
    /// `CustomPlaylist` is actually picked as a Build Mix source (see
    /// `TrackAnalysisCoordinator.upsertAndAnalyzeIfNeeded`, unaffected by
    /// this — it starts from whatever row already exists, bare or not, and
    /// fills in the rest). `onConflict: .ignore` makes this a true no-op
    /// when a row (bare or already-analyzed) already exists, so it never
    /// clobbers real analysis data with a bare re-insert.
    public func upsertTrackMetadataIfNeeded(persistentID: Int64, title: String, artist: String, album: String, genre: String, durationSec: Double) throws {
        try dbQueue.write { conn in
            let track = Track(persistentID: persistentID, title: title, artist: artist, album: album, genre: genre, durationSec: durationSec)
            try track.insert(conn, onConflict: .ignore)
        }
    }

    /// Adds one song to a `CustomPlaylist`, at the end — the "Add to
    /// Playlist" action. A song already present is left alone (position
    /// unchanged, no duplicate row) rather than appended a second time, so
    /// tapping "Add to Playlist" again on a song already in that list is a
    /// harmless no-op instead of clutter.
    ///
    /// - Precondition: a `tracks` row for `trackPersistentID` must already
    ///   exist — call `upsertTrackMetadataIfNeeded` first if the caller
    ///   can't otherwise guarantee one (see that function's own doc
    ///   comment).
    public func addTrack(trackPersistentID: Int64, toCustomPlaylistID customPlaylistID: Int64) throws {
        try dbQueue.write { conn in
            // Fetched as real `CustomPlaylistTrack` records (already-proven
            // record-based `fetchAll`, same as `removeTrack`/`reorderTracks`
            // elsewhere in this project), not a `MAX(position)` scalar
            // aggregate — deliberately avoiding that: `MAX()` over zero
            // existing rows returns a NULL row, and GRDB's non-optional
            // scalar `fetchOne` traps on decoding a NULL as `Int`. This one
            // query also doubles as the duplicate check below, so nothing
            // extra is needed for that either.
            let existing = try CustomPlaylistTrack.fetchAll(
                conn, sql: "SELECT * FROM custom_playlist_tracks WHERE custom_playlist_id = ? ORDER BY position",
                arguments: [customPlaylistID]
            )
            guard !existing.contains(where: { $0.trackPersistentID == trackPersistentID }) else { return }

            let nextPosition = (existing.last?.position ?? -1) + 1
            var row = CustomPlaylistTrack(customPlaylistID: customPlaylistID, trackPersistentID: trackPersistentID, position: nextPosition)
            try row.insert(conn)

            if var playlist = try CustomPlaylist.fetchOne(conn, key: customPlaylistID) {
                playlist.updatedAt = Date()
                try playlist.update(conn)
            }
        }
    }

    /// Bulk-imports a real Apple Music playlist's current song list into a
    /// just-created (expected-empty) `CustomPlaylist` — the actual "copy"
    /// half of copy-on-edit. Callers must have already ensured a `tracks`
    /// row exists for every id (via `upsertTrackMetadataIfNeeded`) — same
    /// FK precondition as `addTrack`.
    public func copyTracks(_ trackPersistentIDs: [Int64], intoCustomPlaylistID customPlaylistID: Int64) throws {
        try dbQueue.write { conn in
            for (index, trackPersistentID) in trackPersistentIDs.enumerated() {
                var row = CustomPlaylistTrack(customPlaylistID: customPlaylistID, trackPersistentID: trackPersistentID, position: index)
                try row.insert(conn)
            }
        }
    }

    /// Removes one song from a `CustomPlaylist`'s list and renumbers the
    /// rest to stay contiguous — the confirmed "Remove from this List"
    /// action on the not-yet-built-until-now custom-playlist songs screen.
    /// Same shape as `removeTrack` (for `playlist_tracks`) above.
    public func removeCustomPlaylistTrack(id: Int64, fromCustomPlaylistID customPlaylistID: Int64) throws {
        try dbQueue.write { conn in
            try conn.execute(
                sql: "DELETE FROM custom_playlist_tracks WHERE id = ? AND custom_playlist_id = ?",
                arguments: [id, customPlaylistID]
            )

            let remaining = try CustomPlaylistTrack.fetchAll(
                conn, sql: "SELECT * FROM custom_playlist_tracks WHERE custom_playlist_id = ? ORDER BY position",
                arguments: [customPlaylistID]
            )
            for (index, var row) in remaining.enumerated() where row.position != index {
                row.position = index
                try row.update(conn)
            }

            if var playlist = try CustomPlaylist.fetchOne(conn, key: customPlaylistID) {
                playlist.updatedAt = Date()
                try playlist.update(conn)
            }
        }
    }
}
