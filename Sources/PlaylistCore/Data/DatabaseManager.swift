import Foundation
import GRDB

/// Owns the app's single SQLite database (GRDB `DatabaseQueue`) and the
/// migrations that create it. Mirrors CLAUDE.md's "Data Model — SQLite
/// Schema" section exactly — if a column or index changes here, update that
/// section too (Rule 2's iOS-codebase extension).
///
/// Compiles clean and `DatabaseManagerTests` passes (migration creates all
/// four tables, track round-trip, playlist-with-sources-and-tracks) as of
/// the 2026-08-07 Codemagic build — see CLAUDE.md Version History 0.13.6.
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
                // Not belongsTo(...) — its auto-generated FK column name
                // doesn't come out as the snake_case "playlist_id" this
                // schema (and the explicit index right below) expect. Same
                // issue as track_persistent_id below; fixed the same way.
                t.column("playlist_id", .integer)
                    .notNull()
                    .references("playlists", onDelete: .cascade)
                t.column("source_type", .text).notNull()
                t.column("source_value", .text).notNull()
                t.column("source_label", .text).notNull()
            }
            try db.create(index: "idx_playlist_sources_playlist_id", on: "playlist_sources", columns: ["playlist_id"])

            try db.create(table: "playlist_tracks") { t in
                t.autoIncrementedPrimaryKey("id")
                // Same fix as playlist_sources above — belongsTo(...)'s
                // auto-generated column name doesn't come out as "playlist_id".
                t.column("playlist_id", .integer)
                    .notNull()
                    .references("playlists", onDelete: .cascade)
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

        // Added 2026-08-13, after Andy's first real-device listening pass
        // surfaced that the mixing engine's crossfades were badly timed and
        // sometimes landed mid-fade-out — root cause was `crossfadeStartOffsetSec`
        // being a flat, unvalidated placeholder (`duration - 5s`) and the
        // engine playing raw files with no silence/fade-tail trimming, unlike
        // Phase 1's Python pipeline. See CLAUDE.md's Version History for the
        // full fix.
        migrator.registerMigration("v2_trim_and_crossfade_duration") { db in
            try db.alter(table: "tracks") { t in
                // Both nullable: nil means "not yet (re-)analyzed under this
                // schema" — `Track.isAnalyzed` treats a nil here as
                // needing analysis, so existing rows get backfilled the next
                // time they're pulled into a Build Mix/Refresh pool, rather
                // than silently keeping stale placeholder crossfade timing.
                t.add(column: "playable_start_sec", .double)
                t.add(column: "playable_duration_sec", .double)
            }
            try db.alter(table: "playlist_tracks") { t in
                // NOT NULL with a default so this backfills cleanly for any
                // playlist_tracks rows that already exist — those rows keep
                // their old (now-known-wrong) crossfade_start_offset_sec
                // until their playlist is next Refreshed, at which point
                // MixBuilder recomputes both real values together.
                t.add(column: "crossfade_duration_sec", .double).notNull().defaults(to: 4.0)
            }
        }

        // Added 2026-08-19, per Andy's direct request ("can the crossfade be
        // extended... a time setting how long this can be") — see
        // `Playlist.extraCrossfadeSec`'s own doc comment for the full
        // reasoning. NOT NULL with a 0 default so every existing playlist
        // keeps its exact current crossfade behavior until the user
        // explicitly picks something else via a fresh Build Mix or Refresh.
        migrator.registerMigration("v3_extra_crossfade_sec") { db in
            try db.alter(table: "playlists") { t in
                t.add(column: "extra_crossfade_sec", .double).notNull().defaults(to: 0)
            }
        }

        // Added 2026-09-06, per Andy's direct request — a track-level
        // favorite (see `Track.isFavorite`'s own doc comment), separate from
        // the existing playlist-level `playlists.is_favorite`. NOT NULL with
        // a `false` default so every existing track row backfills as "not
        // favorited" rather than nil/unknown.
        migrator.registerMigration("v4_track_favorite") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "is_favorite", .boolean).notNull().defaults(to: false)
            }
        }

        return migrator
    }
}
