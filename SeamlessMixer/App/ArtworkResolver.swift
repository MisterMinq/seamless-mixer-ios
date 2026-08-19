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
enum ArtworkResolver {
    /// Resolves artwork for every track ID given, in one full-library pass.
    /// A track no longer in the library (deleted since this playlist was
    /// built) is simply absent from the result, not an error.
    static func loadArtwork(forTrackPersistentIDs trackIDs: [Int64], size: CGSize) -> [Int64: UIImage] {
        guard !trackIDs.isEmpty else { return [:] }
        let wanted = Set(trackIDs.map { UInt64(bitPattern: $0) })
        let allSongs = MPMediaQuery.songs().items ?? []

        var artworkByAlbum: [MPMediaEntityPersistentID: UIImage] = [:]
        var result: [Int64: UIImage] = [:]

        for item in allSongs where wanted.contains(item.persistentID) {
            let albumID = item.albumPersistentID
            let image: UIImage?
            if albumID != 0, let cached = artworkByAlbum[albumID] {
                image = cached
            } else if let rendered = item.artwork?.image(at: size) {
                if albumID != 0 { artworkByAlbum[albumID] = rendered }
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
