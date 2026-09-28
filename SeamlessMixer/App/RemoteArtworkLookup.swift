import Foundation
import UIKit

/// Best-effort online fallback for album artwork this app can't find
/// on-device — Apple's own free, unauthenticated iTunes Search API
/// (`itunes.apple.com/search`), used only when `ArtworkResolver` already
/// tried the local library and came up empty.
///
/// **This is the app's first-ever network call.** Every other piece of
/// Seamless DJ works entirely offline by design (see CLAUDE.md's Phase 2
/// architecture decisions — no server component, on-device live mixing).
/// Deliberately scoped as narrowly as possible in exchange for crossing
/// that line: one small, isolated lookup, sending only an artist + album
/// name string (never anything personal, never the user's email or any
/// identifying data), used purely to decorate this app's own display
/// (Playlist Detail thumbnails, My Mixes collage). It never writes
/// anything back to the user's real Apple Music library — there's no API
/// to do that anyway (`MediaPlayer` is read-only to third-party apps),
/// and this app was never trying to.
///
/// **Not every album will be found, by design, not by bug.** Some real,
/// deep-catalog, independent, or self-released music simply isn't indexed
/// anywhere online — confirmed directly during this project's own earlier
/// key-detection validation work, where several tracks in the user's
/// library had no public metadata anywhere searched. A miss here is
/// treated the same as "no artwork available" (the existing flat
/// placeholder), not an error.
///
/// **Caching, both directions.** A found image is written to disk (so it
/// never needs re-downloading once found) and kept in memory for the rest
/// of the app's current run (so it isn't even re-read from disk on every
/// screen visit within one session). A confirmed *miss* is remembered too
/// — in `UserDefaults`, since it's just a small set of key strings — so a
/// genuinely-unindexed album isn't re-queried over the network every
/// single time it's displayed.
///
/// **Revised 2026-09-28, per Andy's direct request: network access is now
/// confined to `LibraryScanner`'s scan, not triggered by ordinary
/// browsing.** The first version of this file let any screen that
/// displayed artwork (`PlaylistDetailViewModel`, `PlaylistStore`) call the
/// full `image(artist:album:)` directly, meaning the very first time a
/// mix with a missing-artwork track was opened, that screen would kick off
/// a live network request right then. Andy's own words: "can the missing
/// artwork feature be built in such a way that it does not make constant
/// search for artwork online but maybe just once while it is scanning the
/// library." Two entry points now, deliberately separated:
/// - `image(artist:album:)` — the real, network-allowed lookup. **Only
///   ever called from `LibraryScanner.scan`.**
/// - `cachedImage(artist:album:)` — a synchronous, network-free read of
///   whatever a prior scan already found (or already confirmed missing).
///   Used by every display-only screen. A miss here just means "not
///   scanned yet, or genuinely not found" — the screen falls back to its
///   usual flat placeholder, and the *next* library scan is what actually
///   resolves it, not opening this screen again.
///
/// `@MainActor`-isolated rather than actor-agnostic: every caller so far
/// (`LibraryScanner`, `PlaylistDetailViewModel`, `PlaylistStore`) already
/// runs on the main actor, and this keeps the static in-memory cache/
/// known-misses set from needing its own separate synchronization — the
/// same reasoning `TrackAnalysisCoordinator` already uses. `await`ing a
/// network call from a `@MainActor` function suspends without blocking the
/// main thread; the actual request runs on `URLSession`'s own background
/// machinery.
///
/// **Known, deliberate non-goal for this first pass**: no explicit rate
/// limiting beyond the two caches above. Apple's search endpoint has an
/// informal, undocumented rate limit, but at personal-library scale —
/// where most tracks already have local artwork and only the genuine
/// gaps ever reach this fallback at all, and it now only ever runs during
/// an already-understood "this may take a while" scan, not in a tight
/// loop a user could trigger repeatedly — this hasn't been a concern in
/// practice. Revisit only if a real "too many requests" response ever
/// shows up.
@MainActor
enum RemoteArtworkLookup {
    private static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("RemoteArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let knownMissesDefaultsKey = "RemoteArtworkLookup.knownMisses"
    private static var knownMisses: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: knownMissesDefaultsKey) ?? []
    )

    private static var memoryCache: [String: UIImage] = [:]

    /// Looks up a fallback cover for one album, hitting the network if
    /// nothing's cached yet. **Only called from `LibraryScanner.scan`** —
    /// see this type's own doc comment for why every other caller uses
    /// `cachedImage` instead. Returns `nil` on any miss — no network, no
    /// match found, a bad/undecodable response — all treated identically
    /// as "nothing available," matching `ArtworkResolver`'s own "missing is
    /// normal, not an error" posture.
    static func image(artist: String, album: String) async -> UIImage? {
        let key = cacheKey(artist: artist, album: album)

        if let cached = memoryCache[key] {
            return cached
        }
        if knownMisses.contains(key) {
            return nil
        }
        if let onDisk = loadFromDisk(key: key) {
            memoryCache[key] = onDisk
            return onDisk
        }

        guard let artworkURL = await fetchArtworkURL(artist: artist, album: album),
              let image = await downloadImage(from: artworkURL)
        else {
            recordMiss(key: key)
            return nil
        }

        memoryCache[key] = image
        saveToDisk(key: key, image: image)
        return image
    }

    /// **Added 2026-09-28** — a synchronous, network-free read of whatever
    /// `image(artist:album:)` already resolved (or already confirmed
    /// missing) during a prior library scan. Used by every screen that
    /// just displays artwork, so browsing mixes never triggers a live
    /// lookup — see this type's own doc comment.
    static func cachedImage(artist: String, album: String) -> UIImage? {
        let key = cacheKey(artist: artist, album: album)
        if let cached = memoryCache[key] {
            return cached
        }
        guard !knownMisses.contains(key) else { return nil }
        guard let onDisk = loadFromDisk(key: key) else { return nil }
        memoryCache[key] = onDisk
        return onDisk
    }

    // MARK: - iTunes Search API

    private struct SearchResponse: Decodable {
        let results: [SearchResult]
    }

    private struct SearchResult: Decodable {
        let artworkUrl100: String?
    }

    private static func fetchArtworkURL(artist: String, album: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(album)"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components?.url else { return nil }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let rawURLString = decoded.results.first?.artworkUrl100
        else { return nil }

        // iTunes's own artwork URLs embed a fixed thumbnail size
        // ("100x100bb") directly in the path -- swapping it for a larger
        // one is a well-known, widely-documented trick (not an
        // undocumented hack that could silently break), since Apple's own
        // CDN happily serves any size for the same underlying asset.
        let largerURLString = rawURLString.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        return URL(string: largerURLString) ?? URL(string: rawURLString)
    }

    private static func downloadImage(from url: URL) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Caching

    private static func cacheKey(artist: String, album: String) -> String {
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedArtist)|\(normalizedAlbum)"
    }

    private static func fileURL(for key: String) -> URL {
        let safeName = String(key.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return cacheDirectory.appendingPathComponent(safeName + ".jpg")
    }

    private static func loadFromDisk(key: String) -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL(for: key)) else { return nil }
        return UIImage(data: data)
    }

    private static func saveToDisk(key: String, image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: fileURL(for: key))
    }

    private static func recordMiss(key: String) {
        knownMisses.insert(key)
        UserDefaults.standard.set(Array(knownMisses), forKey: knownMissesDefaultsKey)
    }
}
