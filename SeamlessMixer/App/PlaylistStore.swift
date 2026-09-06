import Combine
import Foundation
import PlaylistCore
import UIKit

/// Thin, observable wrapper around `DatabaseManager` for SwiftUI views —
/// the first real (non-test) caller of the data layer. Opens the app's
/// actual on-device database in Application Support, not an in-memory one;
/// `DatabaseManager(path: nil)` stays reserved for previews/tests per its
/// own doc comment.
@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var loadError: String?

    /// **Added 2026-08-20** — up to 4 distinct-album collage images per
    /// playlist (per Andy's direct request to reuse Playlist Detail's new
    /// collage as My Mixes' own row thumbnails), keyed by `Playlist.id`.
    /// Loaded in one batch across *every* playlist, not one query per row
    /// — `ArtworkResolver.loadArtwork` does a full-library `MPMediaQuery`
    /// scan internally, and doing that once per row on this, the app's
    /// root screen, would scale badly with playlist count. Missing from
    /// this dictionary (not yet loaded, or a playlist with no resolvable
    /// artwork) is treated as "no collage" by callers, same as an empty
    /// array.
    @Published private(set) var collagesByPlaylistID: [Int64: [UIImage]] = [:]

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
        loadCollages()
    }

    /// See `collagesByPlaylistID`'s own doc comment for why this batches
    /// across every playlist in one pass. Best-effort: a failure here
    /// leaves collages showing as the flat placeholder (via the empty-array
    /// fallback already built into `CollageArtworkView`'s callers) rather
    /// than surfacing a `loadError` — a missing thumbnail isn't worth
    /// blocking the whole screen's data over, unlike a failure to load the
    /// playlists themselves.
    private func loadCollages() {
        guard let db else { return }
        do {
            var trackIDsByPlaylist: [Int64: [Int64]] = [:]
            var allTrackIDs: [Int64] = []
            for playlist in playlists {
                guard let id = playlist.id else { continue }
                let detail = try db.loadPlaylistDetail(playlistID: id)
                let ids = detail.tracks.map(\.track.persistentID)
                trackIDsByPlaylist[id] = ids
                allTrackIDs.append(contentsOf: ids)
            }

            // One combined resolution pass across every playlist's tracks
            // -- not one `ArtworkResolver` call per playlist -- so this
            // does a single full-library `MPMediaQuery` scan regardless of
            // how many mixes exist.
            let artworkByTrack = ArtworkResolver.loadArtwork(
                forTrackPersistentIDs: allTrackIDs, size: CGSize(width: 110, height: 110)
            )

            var result: [Int64: [UIImage]] = [:]
            for (playlistID, trackIDs) in trackIDsByPlaylist {
                let artworkInOrder = trackIDs.map { artworkByTrack[$0] }
                result[playlistID] = ArtworkResolver.distinctAlbumImages(from: artworkInOrder, limit: 4)
            }
            collagesByPlaylistID = result
        } catch {
            // Best-effort, per this function's own doc comment -- leave
            // whatever collages were already loaded (or none) rather than
            // clearing them out on a transient failure.
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

    /// Track-level favorite — added 2026-09-06, per Andy's direct request:
    /// a way to mark an individual song encountered inside a mix (the
    /// motivating case is a Whole Library mix surfacing something he's
    /// never consciously listened to before) as a favorite, separate from
    /// the existing playlist-level `setFavorite` above. Looked up and
    /// updated directly on the track's own `tracks` row rather than through
    /// any one playlist — a song's favorite status isn't scoped to which
    /// mix it happened to play in. Same "no `refresh()`" reasoning as
    /// `removeTrack`/`reorderTracks`: this doesn't change anything
    /// `MyMixesView`'s rows display.
    func setTrackFavorite(trackPersistentID: Int64, isFavorite: Bool) {
        guard let db else { return }
        do {
            try db.dbQueue.write { conn in
                guard var track = try Track.fetchOne(conn, key: trackPersistentID) else { return }
                track.isFavorite = isFavorite
                try track.update(conn)
            }
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
