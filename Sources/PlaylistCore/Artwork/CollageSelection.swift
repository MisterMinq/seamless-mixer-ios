import Foundation

/// One candidate track for a collage, in playlist order — just enough
/// identity to decide selection (which album it belongs to), deliberately
/// carrying no `MediaPlayer`/`UIKit` type so this stays pure, testable logic
/// (see `CollageSelectionTests.swift`). `albumID` is the track's real
/// `MPMediaEntityPersistentID` (a `UInt64`, not re-typed here to avoid
/// importing MediaPlayer); `0` is treated as "no album grouping" — every
/// such candidate counts as its own, always-distinct "album," matching how
/// `ArtworkResolver`'s own caching already treats a zero album ID.
public struct CollageCandidate: Equatable {
    public let trackID: Int64
    public let albumID: UInt64

    public init(trackID: Int64, albumID: UInt64) {
        self.trackID = trackID
        self.albumID = albumID
    }
}

/// Picks up to `limit` distinct-album images for a playlist's collage,
/// without resolving (decoding) more tracks than it actually needs to.
///
/// Extracted 2026-10-01 out of `ArtworkResolver.loadCollages` (app target),
/// the same way `CrossfadeTiming`/`DRMExclusionSummary` were pulled out of
/// `MixBuilder` — the actual image decode is real I/O (`MPMediaQuery`,
/// `UIImage`) that can't run in `swift test` without a real device, but the
/// *decision* of which tracks are even worth trying is plain logic over
/// track/album identity, and had been sitting untested inside that
/// MediaPlayer-dependent code purely because nothing had ever pulled it out.
///
/// This exists because of a real, confirmed bug (CLAUDE.md Version History
/// 0.26.8/0.26.9): a first attempt at bounding collage-resolution cost
/// truncated each playlist to a fixed prefix of tracks, which silently
/// broke real mixes whose first few sequenced tracks happened not to
/// resolve. The actual fix was never "look at fewer tracks" — it's "stop
/// looking once you have enough," in playlist order, so a hundreds-of-songs
/// mix costs the same as a four-song one regardless of which specific
/// tracks happen to resolve.
public enum CollageSelection {
    /// Walks `candidates` in order. `resolve` is only ever called for a
    /// candidate whose album hasn't already contributed an image to this
    /// result — an already-seen album is skipped with no resolve attempt at
    /// all, which is the actual cost saving this type exists for. Stops the
    /// moment `limit` images have been collected.
    ///
    /// A candidate whose `resolve` call returns `nil` does **not**
    /// permanently block its album: a later candidate sharing that same
    /// album ID can still be tried. This matters for a real case — two
    /// library entries of the same album where only one file actually has
    /// embedded artwork — not a hypothetical.
    ///
    /// Generic over `Image` (rather than concretely `UIImage`) so this type
    /// never needs to import `UIKit`/`MediaPlayer` at all; the app target
    /// supplies the real `(Int64) -> UIImage?` resolver, tests supply a
    /// cheap stand-in.
    ///
    /// Generic over `Candidates: Sequence` rather than concretely
    /// `[CollageCandidate]` — added 2026-10-02, alongside a real, confirmed
    /// regression fix in `ArtworkResolver.loadCollage` (its own doc comment
    /// has the full story): a caller building its candidates via
    /// `.lazy.compactMap` needs that laziness preserved all the way through
    /// this function's own early-exit loop, not force-materialized into an
    /// array the moment it's passed in here. A plain `[CollageCandidate]`
    /// (as every existing test already passes) still works unchanged, since
    /// `Array` conforms to `Sequence`.
    public static func select<Candidates: Sequence, Image>(
        from candidates: Candidates,
        limit: Int,
        resolve: (Int64) -> Image?
    ) -> [Image] where Candidates.Element == CollageCandidate {
        guard limit > 0 else { return [] }
        var images: [Image] = []
        var seenAlbums = Set<UInt64>()
        for candidate in candidates {
            if images.count >= limit { break }
            if candidate.albumID != 0 && !seenAlbums.insert(candidate.albumID).inserted {
                continue
            }
            if let image = resolve(candidate.trackID) {
                images.append(image)
            } else if candidate.albumID != 0 {
                seenAlbums.remove(candidate.albumID)
            }
        }
        return images
    }
}
