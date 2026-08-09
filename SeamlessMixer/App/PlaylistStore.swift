import Combine
import Foundation
import PlaylistCore

/// Thin, observable wrapper around `DatabaseManager` for SwiftUI views —
/// the first real (non-test) caller of the data layer. Opens the app's
/// actual on-device database in Application Support, not an in-memory one;
/// `DatabaseManager(path: nil)` stays reserved for previews/tests per its
/// own doc comment.
@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var loadError: String?

    /// Internal (not private) so `MixBuilder` — the "Build Mix" pipeline —
    /// can read/write tracks and playlists directly rather than every
    /// operation needing its own method here. Still not exposed outside the
    /// app target (this isn't `public`; `PlaylistStore` itself isn't part
    /// of `PlaylistCore`).
    let db: DatabaseManager?

    init() {
        do {
            let url = try Self.databaseURL()
            db = try DatabaseManager(path: url.path)
        } catch {
            db = nil
            loadError = "Couldn't open the library database: \(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() {
        guard let db else { return }
        do {
            // Sorted in Swift, not via `Playlist.Columns.createdAt` in a
            // GRDB `.order(...)` clause — either works now that `Columns`
            // is public, but for a personal-library-sized playlist list
            // there's no real cost to keep the query itself trivial and do
            // the ordering here.
            playlists = try db.dbQueue.read { conn in
                try Playlist.fetchAll(conn)
            }.sorted { $0.createdAt > $1.createdAt }
        } catch {
            loadError = "Couldn't load playlists: \(error.localizedDescription)"
        }
    }

    /// Wires up the Favorite star (previously a no-op button in both
    /// `PlaylistDetailView` and `MyMixesView`'s design, per the Tier 1 quick
    /// win in `documentation/Editability_UX_Gap_Analysis.docx`). Re-fetches
    /// the row fresh inside the write rather than trusting a possibly-stale
    /// `Playlist` value passed in from a view.
    func setFavorite(playlistID: Int64, isFavorite: Bool) {
        guard let db else { return }
        do {
            try db.dbQueue.write { conn in
                guard var playlist = try Playlist.fetchOne(conn, key: playlistID) else { return }
                playlist.isFavorite = isFavorite
                playlist.updatedAt = Date()
                try playlist.update(conn)
            }
            refresh()
        } catch {
            loadError = "Couldn't update favorite: \(error.localizedDescription)"
        }
    }

    /// Tier 2 quick win, per `documentation/Editability_UX_Gap_Analysis.docx`
    /// — the confirmed overflow-sheet "Rename" action. Empty/whitespace-only
    /// names are ignored rather than silently saved, since the auto-name is
    /// always a reasonable fallback and an accidental blank save would be
    /// hard to recover from without this same sheet.
    func rename(playlistID: Int64, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let db, !trimmed.isEmpty else { return }
        do {
            try db.dbQueue.write { conn in
                guard var playlist = try Playlist.fetchOne(conn, key: playlistID) else { return }
                playlist.name = trimmed
                playlist.updatedAt = Date()
                try playlist.update(conn)
            }
            refresh()
        } catch {
            loadError = "Couldn't rename mix: \(error.localizedDescription)"
        }
    }

    /// Tier 2 quick win — the confirmed overflow-sheet "Delete" action.
    /// `playlist_sources`/`playlist_tracks` rows are declared with
    /// `ON DELETE CASCADE` against `playlists.id` in the migration, so
    /// deleting the playlist row here is expected to clean those up too
    /// without a separate delete per table -- not independently re-verified
    /// against a real device yet, same category of gap as everything else
    /// MediaPlayer/database-touching in this app so far.
    func delete(playlistID: Int64) {
        guard let db else { return }
        do {
            try db.dbQueue.write { conn in
                if let playlist = try Playlist.fetchOne(conn, key: playlistID) {
                    try playlist.delete(conn)
                }
            }
            refresh()
        } catch {
            loadError = "Couldn't delete mix: \(error.localizedDescription)"
        }
    }

    /// Tier 3 editability fix, per `documentation/Editability_UX_Gap_Analysis.docx`
    /// — removes a single track from a saved playlist's `playlist_tracks`
    /// (`DatabaseManager.removeTrack` also renumbers the remaining
    /// positions so there's no gap). Deliberately doesn't call `refresh()`:
    /// unlike Favorite/Rename/Delete, removing a track doesn't change
    /// anything `store.playlists`/`MyMixesView`'s rows display (no song
    /// count shown there yet) — only `PlaylistDetailViewModel`'s own track
    /// list needs to know, and it reloads itself right after calling this.
    func removeTrack(playlistTrackID: Int64, fromPlaylistID playlistID: Int64) {
        guard let db else { return }
        do {
            try db.removeTrack(playlistTrackID: playlistTrackID, fromPlaylistID: playlistID)
        } catch {
            loadError = "Couldn't remove track: \(error.localizedDescription)"
        }
    }

    /// The other half of the Tier 3 editability fix — persists a manual
    /// drag-to-reorder. Same "no `refresh()`" reasoning as `removeTrack`:
    /// reordering doesn't change anything `MyMixesView`'s rows display,
    /// only `PlaylistDetailViewModel`'s own (already locally-updated) row
    /// order matters here, and this call is fire-and-forget from its
    /// perspective — the UI already reflects the new order optimistically
    /// before this even runs.
    func reorderTracks(playlistID: Int64, orderedPlaylistTrackIDs: [Int64]) {
        guard let db else { return }
        do {
            try db.reorderTracks(playlistID: playlistID, orderedPlaylistTrackIDs: orderedPlaylistTrackIDs)
        } catch {
            loadError = "Couldn't save the new track order: \(error.localizedDescription)"
        }
    }

    private static func databaseURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return appSupport.appendingPathComponent("SeamlessMixer.sqlite")
    }
}
