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
    /// Where in this track the crossfade into the next one begins — measured
    /// from the track's *playable* start (after leading silence is skipped
    /// at playback time), not from raw frame 0. Computed from tempo, not a
    /// fixed value — see `MixBuilder.crossfadeDurationSec(forBPM:)`.
    public var crossfadeStartOffsetSec: Double
    /// How long the blend into the next track lasts, in seconds — tempo-derived
    /// per transition (`clip(60/bpm * 6 beats, 2s, 12s)`, a direct port of
    /// `playlist_mixer.py`'s `build_mix`), not the fixed 4.0s constant this
    /// project shipped with before real-device listening surfaced it as one
    /// of the crossfade engine's real bugs. Added alongside `playable_start_sec`/
    /// `playable_duration_sec` on `tracks` (see DatabaseManager's v2 migration).
    public var crossfadeDurationSec: Double
    /// Tempo nudge applied to the incoming track, as a fraction (e.g. 0.04 = 4%),
    /// capped at ±6% per the mixing engine design.
    public var tempoNudgePct: Double

    public init(
        id: Int64? = nil,
        playlistID: Int64,
        trackPersistentID: Int64,
        position: Int,
        crossfadeStartOffsetSec: Double,
        crossfadeDurationSec: Double,
        tempoNudgePct: Double
    ) {
        self.id = id
        self.playlistID = playlistID
        self.trackPersistentID = trackPersistentID
        self.position = position
        self.crossfadeStartOffsetSec = crossfadeStartOffsetSec
        self.crossfadeDurationSec = crossfadeDurationSec
        self.tempoNudgePct = tempoNudgePct
    }
}

extension PlaylistTrack: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlist_tracks"

    public enum Columns: String, ColumnExpression {
        case id
        case playlistID = "playlist_id"
        case trackPersistentID = "track_persistent_id"
        case position
        case crossfadeStartOffsetSec = "crossfade_start_offset_sec"
        case crossfadeDurationSec = "crossfade_duration_sec"
        case tempoNudgePct = "tempo_nudge_pct"
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        playlistID = row[Columns.playlistID]
        trackPersistentID = row[Columns.trackPersistentID]
        position = row[Columns.position]
        crossfadeStartOffsetSec = row[Columns.crossfadeStartOffsetSec]
        crossfadeDurationSec = row[Columns.crossfadeDurationSec]
        tempoNudgePct = row[Columns.tempoNudgePct]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.playlistID] = playlistID
        container[Columns.trackPersistentID] = trackPersistentID
        container[Columns.position] = position
        container[Columns.crossfadeStartOffsetSec] = crossfadeStartOffsetSec
        container[Columns.crossfadeDurationSec] = crossfadeDurationSec
        container[Columns.tempoNudgePct] = tempoNudgePct
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
