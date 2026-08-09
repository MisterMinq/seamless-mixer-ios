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

    private static func databaseURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return appSupport.appendingPathComponent("SeamlessMixer.sqlite")
    }
}
