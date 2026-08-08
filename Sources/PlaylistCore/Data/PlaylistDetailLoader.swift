import Foundation
import GRDB

/// A flattened join of one `PlaylistTrack` row (order, transition fields)
/// and its `Track` (title/artist/duration) — Playlist Detail only needs
/// display fields from both, not the full underlying records separately.
public struct PlaylistTrackDetail: Identifiable, Equatable {
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
                return PlaylistTrackDetail(id: playlistTrack.id ?? playlistTrack.trackPersistentID, position: playlistTrack.position, track: track)
            }

            return (sources, details)
        }
    }
}
