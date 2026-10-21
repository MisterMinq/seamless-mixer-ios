import Foundation
import GRDB

/// Database helpers for songs imported from outside the Music library
/// (added 2026-10-21, see `Track.importedFileName`). Raw SQL throughout, the
/// same convention as `PlaylistDetailLoader`/`CustomPlaylistLoader` for
/// anything beyond `fetchOne(key:)`.
extension DatabaseManager {

    /// Every imported song, alphabetical by title.
    public func loadImportedTracks() throws -> [Track] {
        try dbQueue.read { conn in
            try Track.fetchAll(conn, sql: "SELECT * FROM tracks WHERE imported_file_name IS NOT NULL ORDER BY title COLLATE NOCASE")
        }
    }

    /// The imported tracks among `ids` (an id that is not an imported track,
    /// or does not exist, is simply absent from the result).
    public func importedTracks(withIDs ids: [Int64]) throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { conn in
            try Track.fetchAll(conn, keys: ids).filter { $0.importedFileName != nil }
        }
    }

    /// Ids of imported songs the user has marked favorite — so a Favourites
    /// pick can include imported favourites too (the Music-library side of
    /// that source is resolved through `MediaPlayer`, which cannot see them).
    public func importedFavoriteTrackIDs() throws -> [Int64] {
        try dbQueue.read { conn in
            try Int64.fetchAll(conn, sql: "SELECT persistent_id FROM tracks WHERE is_favorite = 1 AND imported_file_name IS NOT NULL")
        }
    }

    /// How many saved mixes currently contain this track — shown in the
    /// "remove this imported song?" confirmation.
    public func mixCount(usingTrackID trackID: Int64) throws -> Int {
        try dbQueue.read { conn in
            try Int.fetchOne(
                conn, sql: "SELECT COUNT(DISTINCT playlist_id) FROM playlist_tracks WHERE track_persistent_id = ?",
                arguments: [trackID]
            ) ?? 0
        }
    }

    /// Removes an imported song from the app's database. `playlist_tracks`
    /// and `custom_playlist_tracks` reference `tracks` with `ON DELETE
    /// RESTRICT`, so the track cannot simply be deleted while a mix or native
    /// playlist still lists it: this first removes it from every one of them
    /// (renumbering each affected list so positions stay contiguous), drops
    /// any saved Build-Mix source pointing at it, then deletes the row — all
    /// in one transaction, so a failure leaves everything as it was.
    ///
    /// - Returns: the name of the stored file the caller should now delete
    ///   (`nil` if the id was not an imported track, in which case nothing is
    ///   touched).
    @discardableResult
    public func deleteImportedTrack(trackID: Int64) throws -> String? {
        try dbQueue.write { conn in
            guard let track = try Track.fetchOne(conn, key: trackID), let fileName = track.importedFileName else {
                return nil
            }

            for (listTable, ownerColumn) in [("playlist_tracks", "playlist_id"), ("custom_playlist_tracks", "custom_playlist_id")] {
                let owners = try Int64.fetchAll(
                    conn, sql: "SELECT DISTINCT \(ownerColumn) FROM \(listTable) WHERE track_persistent_id = ?",
                    arguments: [trackID]
                )
                try conn.execute(sql: "DELETE FROM \(listTable) WHERE track_persistent_id = ?", arguments: [trackID])
                for owner in owners {
                    let remaining = try Int64.fetchAll(
                        conn, sql: "SELECT id FROM \(listTable) WHERE \(ownerColumn) = ? ORDER BY position",
                        arguments: [owner]
                    )
                    for (index, rowID) in remaining.enumerated() {
                        try conn.execute(sql: "UPDATE \(listTable) SET position = ? WHERE id = ?", arguments: [index, rowID])
                    }
                }
            }

            try conn.execute(
                sql: "DELETE FROM playlist_sources WHERE source_type = ? AND source_value = ?",
                arguments: [SourceType.importedSong.rawValue, String(UInt64(bitPattern: trackID))]
            )
            try conn.execute(sql: "DELETE FROM tracks WHERE persistent_id = ?", arguments: [trackID])
            return fileName
        }
    }
}
