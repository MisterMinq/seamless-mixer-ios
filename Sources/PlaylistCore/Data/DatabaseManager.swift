import Foundation
import GRDB

/// Owns the app's single SQLite database (GRDB `DatabaseQueue`) and the
/// migrations that create it. Mirrors CLAUDE.md's "Data Model — SQLite
/// Schema" section exactly — if a column or index changes here, update that
/// section too (Rule 2's iOS-codebase extension).
///
/// NOT compiled or tested — no Xcode/Swift toolchain is available in the
/// environment this was written in. Build in Xcode and run
/// `PlaylistCoreTests` before relying on this.
public final class DatabaseManager {

    public let dbQueue: DatabaseQueue

    /// - Parameter path: pass a real file URL path for the app; pass `nil`
    ///   (in-memory) for previews and tests.
    public init(path: String?) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "tracks") { t in
                t.column("persistent_id", .integer).primaryKey()
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("album", .text).notNull()
                t.column("genre", .text).notNull()
                t.column("bpm", .double)
                t.column("musical_key", .text)
                t.column("energy", .double)
                t.column("brightness", .double)
                t.column("duration_sec", .double).notNull()
                t.column("has_raw_audio_access", .boolean).notNull().defaults(to: true)
                t.column("analyzed_at", .datetime)
            }
            // Exactly the fields Source Selection's category pickers filter by.
            try db.create(index: "idx_tracks_genre", on: "tracks", columns: ["genre"])
            try db.create(index: "idx_tracks_artist", on: "tracks", columns: ["artist"])

            try db.create(table: "playlists") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("mode", .text).notNull()
                // Added during implementation, 2026-08-07: the Favorite star
                // control (Now Playing / Playlist Detail / My Mixes top rows)
                // needs somewhere to persist — this was referenced in every
                // relevant screen spec but never added as a schema column.
                // Flagging here since CLAUDE.md's schema section predates it.
                t.column("is_favorite", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "playlist_sources") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("playlist", inTable: "playlists", onDelete: .cascade).notNull()
                t.column("source_type", .text).notNull()
                t.column("source_value", .text).notNull()
                t.column("source_label", .text).notNull()
            }
            try db.create(index: "idx_playlist_sources_playlist_id", on: "playlist_sources", columns: ["playlist_id"])

            try db.create(table: "playlist_tracks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("playlist", inTable: "playlists", onDelete: .cascade).notNull()
                // GRDB's belongsTo(...) always auto-names its FK column from
                // the table name (would give "track_id"), with no way to
                // override it — but this column must be named
                // "track_persistent_id" to match tracks.persistent_id (not
                // an autoincrement id). So this is spelled out explicitly
                // via .column(...).references(...) instead of belongsTo.
                t.column("track_persistent_id", .integer)
                    .notNull()
                    .indexed()
                    .references("tracks", column: "persistent_id", onDelete: .restrict)
                t.column("position", .integer).notNull()
                t.column("crossfade_start_offset_sec", .double).notNull()
                t.column("tempo_nudge_pct", .double).notNull()
            }
            // Fast ordered playback retrieval — per CLAUDE.md.
            try db.create(index: "idx_playlist_tracks_playlist_position", on: "playlist_tracks", columns: ["playlist_id", "position"])
        }

        return migrator
    }
}
