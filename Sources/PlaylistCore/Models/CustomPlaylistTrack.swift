import Foundation
import GRDB

/// The ordered song list within one `CustomPlaylist` — join table between
/// `custom_playlists` and `tracks`, added for Batch 2 (2026-09-07). Mirrors
/// `PlaylistTrack`'s shape but deliberately carries none of its crossfade/
/// tempo-nudge fields: a `CustomPlaylist` is raw, unsequenced material — per
/// `CustomPlaylist`'s own doc comment, nothing about it is sequenced until
/// it's actually picked as a source for a real Build Mix, at which point a
/// brand-new `Playlist`/`PlaylistTrack` row (with real crossfade timing) is
/// what gets created, not this one.
public struct CustomPlaylistTrack: Codable, Equatable, Identifiable {
    public var id: Int64?
    public var customPlaylistID: Int64
    public var trackPersistentID: Int64
    /// 0-based order within the list — same convention as
    /// `PlaylistTrack.position`, but here it's just "the order songs were
    /// added in" (or manually reordered), not a sequencing decision.
    public var position: Int

    public init(id: Int64? = nil, customPlaylistID: Int64, trackPersistentID: Int64, position: Int) {
        self.id = id
        self.customPlaylistID = customPlaylistID
        self.trackPersistentID = trackPersistentID
        self.position = position
    }
}

extension CustomPlaylistTrack: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "custom_playlist_tracks"

    public enum Columns: String, ColumnExpression {
        case id
        case customPlaylistID = "custom_playlist_id"
        case trackPersistentID = "track_persistent_id"
        case position
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        customPlaylistID = row[Columns.customPlaylistID]
        trackPersistentID = row[Columns.trackPersistentID]
        position = row[Columns.position]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.customPlaylistID] = customPlaylistID
        container[Columns.trackPersistentID] = trackPersistentID
        container[Columns.position] = position
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
