import Foundation
import GRDB

/// The ordered sequence within one recipe — join table between `playlists`
/// and `tracks`. Crossfade/tempo values are computed once when the recipe is
/// built (per the mixing engine design) and persisted here, not recalculated
/// on every playback.
public struct PlaylistTrack: Codable, Equatable, Identifiable {
    public var id: Int64?
    public var playlistID: Int64
    public var trackPersistentID: Int64
    /// 0-based order within the set.
    public var position: Int
    /// Where in this track the crossfade into the next one begins.
    public var crossfadeStartOffsetSec: Double
    /// Tempo nudge applied to the incoming track, as a fraction (e.g. 0.04 = 4%),
    /// capped at ±6% per the mixing engine design.
    public var tempoNudgePct: Double

    public init(
        id: Int64? = nil,
        playlistID: Int64,
        trackPersistentID: Int64,
        position: Int,
        crossfadeStartOffsetSec: Double,
        tempoNudgePct: Double
    ) {
        self.id = id
        self.playlistID = playlistID
        self.trackPersistentID = trackPersistentID
        self.position = position
        self.crossfadeStartOffsetSec = crossfadeStartOffsetSec
        self.tempoNudgePct = tempoNudgePct
    }
}

extension PlaylistTrack: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlist_tracks"

    enum Columns: String, ColumnExpression {
        case id
        case playlistID = "playlist_id"
        case trackPersistentID = "track_persistent_id"
        case position
        case crossfadeStartOffsetSec = "crossfade_start_offset_sec"
        case tempoNudgePct = "tempo_nudge_pct"
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        playlistID = row[Columns.playlistID]
        trackPersistentID = row[Columns.trackPersistentID]
        position = row[Columns.position]
        crossfadeStartOffsetSec = row[Columns.crossfadeStartOffsetSec]
        tempoNudgePct = row[Columns.tempoNudgePct]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.playlistID] = playlistID
        container[Columns.trackPersistentID] = trackPersistentID
        container[Columns.position] = position
        container[Columns.crossfadeStartOffsetSec] = crossfadeStartOffsetSec
        container[Columns.tempoNudgePct] = tempoNudgePct
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
