import MediaPlayer
import UIKit

/// Resolves real album artwork for one or more tracks by their own
/// `persistentID`, via a single full-library `MPMediaQuery.songs()` pass
/// plus local, per-*album* image caching — not a per-track predicate-based
/// lookup, and not a per-track render.
///
/// **Two deliberate choices here, both reusing already-proven-safe
/// patterns from elsewhere in this app rather than new ones:**
/// - No `MPMediaPropertyPredicate` on `MPMediaItemPropertyPersistentID`.
///   That pattern is a real, documented MediaPlayer-framework
///   unreliability for large `UInt64` persistentID values (see
///   `MixBuilder.requeryItem`'s own doc comment for the full history —
///   fixed in three other places this same investigation surfaced).
///   `NowPlayingView.loadArtwork` still used this exact unreliable
///   pattern for single-track artwork lookups — a real, latent bug found
///   while building this, not guessed at — and now uses `ArtworkResolver`
///   instead.
/// - Artwork is cached per *album*, not per song — a song's artwork is
///   its album's cover, shared by every other song on that album, the
///   same insight `SongPickerView.loadSongs()` already validated: the
///   real number of distinct images ever rendered is bounded by album
///   count, not song count.
///
/// `@MainActor`-isolated, added 2026-09-29 alongside the cross-call cache
/// below — every existing caller (`PlaylistStore`, `PlaylistDetailViewModel`,
/// `NowPlayingView`, `AddToPlaylistView`, `PlaylistPickerView`) already runs
/// on the main actor, and a static mutable cache needs real isolation now
/// that it survives across calls — same reasoning `RemoteArtworkLookup`
/// already uses for its own static caches.
@MainActor
enum ArtworkResolver {
    /// A *cross-call*, in-memory cache — survives for the app's whole run,
    /// not just one `loadArtwork` invocation. Every screen that resolves
    /// artwork in this app draws from a heavily-overlapping set of albums
    /// (the same mixes' tracks get looked up repeatedly across My Mixes'
    /// collage, Playlist Detail's rows, and Now Playing), so this means the
    /// real decode cost for a given album is only ever paid once per
    /// session, from any screen — later requests are a dictionary lookup.
    private static var albumArtworkCache: [MPMediaEntityPersistentID: UIImage] = [:]

    /// **Added 2026-09-29, second pass — the in-memory cache above wasn't
    /// the real fix on its own, disproven by a real, deliberately clean
    /// test.** Andy force-quit the app and relaunched *without* playing
    /// anything first (specifically to rule out the "artwork appears once
    /// you play a mix" pattern giving a false positive) — artwork was still
    /// missing. A force-quit wipes the in-memory cache completely, so every
    /// single cold launch was still paying the full decode cost from
    /// scratch, forever, with nothing ever surviving between app runs —
    /// the in-memory cache genuinely helps *within* one running session
    /// (browsing several screens, or a pull-to-refresh), but a fresh launch
    /// is a fresh process with nothing cached yet, no matter how many past
    /// launches already did this same work.
    ///
    /// This is a real, persistent, cross-*launch* disk cache — the same
    /// proven pattern `RemoteArtworkLookup` already uses for its own online-
    /// fallback artwork, applied here to local artwork too. Once an album's
    /// cover is decoded once, on any device, ever, it's written to
    /// `Caches/AlbumArtwork/` (keyed by the album's own `persistentID`, a
    /// stable Apple-assigned identifier, not anything this app invents) and
    /// never decoded from the original embedded metadata again — a plain
    /// disk read replaces the real, slow decode on every subsequent launch.
    ///
    /// **Decoded and cached at one fixed `canonicalSize`, not whatever size
    /// a given caller happened to request** — confirmed directly (not
    /// assumed) that every artwork display site in this app renders via
    /// `.resizable()`, so one larger-than-any-current-need master image
    /// downscales cleanly for every caller; the largest ask today is Now
    /// Playing's 260×260 tile. This means an album is only ever ONE file on
    /// disk, regardless of how many different-sized tiles request it —
    /// `size:` stays part of this function's signature for every existing
    /// caller, it's just no longer what decides the decode/cache size.
    private static let canonicalSize = CGSize(width: 300, height: 300)

    private static let diskCacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AlbumArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func diskCacheURL(albumID: MPMediaEntityPersistentID) -> URL {
        diskCacheDirectory.appendingPathComponent("\(albumID).jpg")
    }

    private static func loadFromDisk(albumID: MPMediaEntityPersistentID) -> UIImage? {
        guard let data = try? Data(contentsOf: diskCacheURL(albumID: albumID)) else { return nil }
        return UIImage(data: data)
    }

    private static func saveToDisk(albumID: MPMediaEntityPersistentID, image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: diskCacheURL(albumID: albumID))
    }

    /// Resolves artwork for every track ID given, in one full-library pass.
    /// A track no longer in the library (deleted since this playlist was
    /// built) is simply absent from the result, not an error.
    static func loadArtwork(forTrackPersistentIDs trackIDs: [Int64], size: CGSize) -> [Int64: UIImage] {
        guard !trackIDs.isEmpty else { return [:] }
        let wanted = Set(trackIDs.map { UInt64(bitPattern: $0) })
        let allSongs = MPMediaQuery.songs().items ?? []

        var result: [Int64: UIImage] = [:]

        for item in allSongs where wanted.contains(item.persistentID) {
            let albumID = item.albumPersistentID
            let image: UIImage?
            if albumID != 0, let cached = albumArtworkCache[albumID] {
                image = cached
            } else if albumID != 0, let onDisk = loadFromDisk(albumID: albumID) {
                albumArtworkCache[albumID] = onDisk
                image = onDisk
            } else if let rendered = item.artwork?.image(at: canonicalSize) {
                if albumID != 0 {
                    albumArtworkCache[albumID] = rendered
                    saveToDisk(albumID: albumID, image: rendered)
                }
                image = rendered
            } else {
                image = nil
            }
            if let image {
                result[Int64(bitPattern: item.persistentID)] = image
            }
        }
        return result
    }

    /// Convenience for a single track (Now Playing's current/next-track
    /// thumbnails) — still a full-library pass under the hood, but that's
    /// cheap at personal-library scale and avoids maintaining a second
    /// resolution mechanism.
    static func loadArtwork(forTrackPersistentID trackID: Int64, size: CGSize) -> UIImage? {
        loadArtwork(forTrackPersistentIDs: [trackID], size: size)[trackID]
    }

    /// **Added 2026-08-20**, for auto-generated collage artwork (Playlist
    /// Detail, My Mixes) — per Andy's direct request and the confirmed
    /// design's own "auto-generated collage artwork... Apple tiles 4 of
    /// its tracks' artwork into a grid" note.
    ///
    /// Picks up to `limit` images representing *distinct albums* from an
    /// ordered list (one entry per track, in playlist order) — using
    /// reference identity on the already-resolved `UIImage`s, not a
    /// separate album-ID lookup. This works because `loadArtwork` above
    /// already caches one `UIImage` per album internally and hands that
    /// *same instance* back to every track sharing it — two tracks with
    /// `ObjectIdentifier`-equal images are, by construction, on the same
    /// album, so no extra album-identity plumbing is needed here at all.
    /// `nil` entries (a track with no artwork, or not found) are simply
    /// skipped, not counted as "an album."
    static func distinctAlbumImages(from artworkInOrder: [UIImage?], limit: Int) -> [UIImage] {
        var seen = Set<ObjectIdentifier>()
        var result: [UIImage] = []
        for image in artworkInOrder {
            guard let image else { continue }
            guard seen.insert(ObjectIdentifier(image)).inserted else { continue }
            result.append(image)
            if result.count == limit { break }
        }
        return result
    }
}
