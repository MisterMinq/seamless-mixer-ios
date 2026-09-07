import Foundation
import GRDB

/// A user-curated, unsequenced list of songs — added 2026-09-07 per Andy's
/// direct design confirmation (see CLAUDE.md's "Add to Playlist" entries).
/// Deliberately a completely separate type/table from `Playlist`, not a
/// variant of it: `Playlist`/`playlists` already means one specific thing
/// throughout this app — a **Seamless Mix**, the output of a Build Mix,
/// shown only on My Mixes. This type means something structurally
/// different — a raw, hand-built collection of songs added to one at a
/// time (from "Add to Playlist," from copying an existing Apple Music
/// playlist to edit it, or created empty) that only ever shows up as a
/// *source* in the Source Selection Hub, never on My Mixes. Nothing here
/// is sequenced or has real crossfade/tempo data — that only happens once
/// a `CustomPlaylist` is actually picked as a source for a real Build Mix,
/// same as any other source type.
///
/// Andy's own words on why the existing `playlists` table wasn't reused
/// for this: "A seamless mix playlist is shown on the My Mixes Screen, NOT
/// in the SelectionHub screen" — confirmed as two genuinely different
/// concepts sharing an unfortunate English word, not one thing wearing two
/// hats.
public struct CustomPlaylist: Codable, Equatable, Identifiable {
    public var id: Int64?
    public var name: String
    /// **Added for Batch 2 (2026-09-07)** — set only when this row was
    /// created via the confirmed "copy-on-edit" flow (opening a real Apple
    /// Music playlist to edit it makes an independent native copy, since
    /// there's no write API to the original — see CLAUDE.md's "Add to
    /// Playlist" design). `nil` for a `CustomPlaylist` created fresh via
    /// "New Playlist," which has no Apple Music origin at all. This is what
    /// lets the merged Playlists picker replace the plain Apple Music row
    /// with this native, "SM"-badged copy under the same name (per the
    /// confirmed design: "that row *replaces* the plain Apple Music row...
    /// rather than coexisting as a duplicate") instead of showing both.
    public var originApplePlaylistPersistentID: UInt64?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil, name: String, originApplePlaylistPersistentID: UInt64? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.originApplePlaylistPersistentID = originApplePlaylistPersistentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension CustomPlaylist: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "custom_playlists"

    public enum Columns: String, ColumnExpression {
        case id
        case name
        case originApplePlaylistPersistentID = "origin_apple_playlist_persistent_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        name = row[Columns.name]
        // Stored as Int64 (SQLite has no native UInt64) — see the migration's
        // own comment on this column for the bit-pattern round-trip.
        // Deliberately read into an `Int64?` local first, not a non-optional
        // `Int64` — this column is NULL for the common case (a plain "New
        // Playlist," or before this column existed at all), and GRDB's
        // non-optional subscript overload fatal-errors on a NULL value
        // rather than returning nil.
        let rawOrigin: Int64? = row[Columns.originApplePlaylistPersistentID]
        originApplePlaylistPersistentID = rawOrigin.map { UInt64(bitPattern: $0) }
        createdAt = row[Columns.createdAt]
        updatedAt = row[Columns.updatedAt]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.name] = name
        container[Columns.originApplePlaylistPersistentID] = originApplePlaylistPersistentID.map { Int64(bitPattern: $0) }
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
