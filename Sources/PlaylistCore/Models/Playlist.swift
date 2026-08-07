import Foundation
import GRDB

/// One of the four sequencing modes from Phase 1, carried through unchanged
/// per Rule 4 ("don't relitigate"). Raw values match the exact strings already
/// used in CLAUDE.md's schema and `--mode` flag in `playlist_mixer.py`.
public enum PlaylistMode: String, Codable, CaseIterable, DatabaseValueConvertible {
    case energyUp = "energy_up"
    case energyWave = "energy_wave"
    case acousticToFusion = "acoustic_to_fusion"
    case stay = "stay"

    /// Segmented-control label per the Source Selection screen design.
    public var displayName: String {
        switch self {
        case .energyUp: return "Energy up"
        case .energyWave: return "Energy wave"
        case .acousticToFusion: return "Acoustic → fusion"
        case .stay: return "Stay"
        }
    }
}

/// The "recipe" from ADR-4 — a saved seamless playlist. Track order and
/// transition points live in `PlaylistTrack`, not here; this row is just
/// identity, name, and mode.
public struct Playlist: Codable, Equatable, Identifiable {
    public var id: Int64?
    /// Auto-generated at creation per the naming logic in CLAUDE.md
    /// ("Auto-naming logic" under the SQLite schema section) — always
    /// user-renamable afterward via the "..." menu's Rename action.
    public var name: String
    public var mode: PlaylistMode
    public var isFavorite: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        name: String,
        mode: PlaylistMode,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Playlist: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlists"

    enum Columns: String, ColumnExpression {
        case id
        case name
        case mode
        case isFavorite = "is_favorite"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        name = row[Columns.name]
        mode = row[Columns.mode]
        isFavorite = row[Columns.isFavorite]
        createdAt = row[Columns.createdAt]
        updatedAt = row[Columns.updatedAt]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.name] = name
        container[Columns.mode] = mode
        container[Columns.isFavorite] = isFavorite
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
