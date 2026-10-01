import XCTest
@testable import PlaylistCore

/// Coverage for `CollageSelection.select` — the dedup/early-exit decision
/// extracted out of `ArtworkResolver.loadCollages` (app target) 2026-10-01,
/// after a first attempt at bounding collage-resolution cost (a fixed
/// 16-track prefix) turned out to silently break real mixes. These tests
/// pin down the two properties that attempt got wrong: the search must
/// cover the whole list (not a truncated prefix), and it must stop as soon
/// as it has enough, not resolve everything and filter afterward.
final class CollageSelectionTests: XCTestCase {

    func testEmptyCandidatesReturnsEmpty() {
        let images = CollageSelection.select(from: [], limit: 4) { _ in "img" }
        XCTAssertTrue(images.isEmpty)
    }

    func testNonPositiveLimitReturnsEmptyWithoutCallingResolve() {
        var calls = 0
        let candidates = [CollageCandidate(trackID: 1, albumID: 10)]
        let images = CollageSelection.select(from: candidates, limit: 0) { _ in
            calls += 1
            return "img"
        }
        XCTAssertTrue(images.isEmpty)
        XCTAssertEqual(calls, 0)
    }

    func testReturnsFewerThanLimitWhenNotEnoughDistinctAlbumsExist() {
        let candidates = [
            CollageCandidate(trackID: 1, albumID: 10),
            CollageCandidate(trackID: 2, albumID: 20),
        ]
        let images = CollageSelection.select(from: candidates, limit: 4) { "img\($0)" }
        XCTAssertEqual(images, ["img1", "img2"])
    }

    /// The actual point of this type: given a long list, it must stop the
    /// moment it has `limit` images, not walk (and resolve) the whole list.
    /// A real playlist can have hundreds of tracks; this must cost the same
    /// as a four-track one.
    func testStopsResolvingAfterLimitIsReached() {
        var resolvedIDs: [Int64] = []
        let candidates = (1...500).map { CollageCandidate(trackID: Int64($0), albumID: UInt64($0)) }
        let images = CollageSelection.select(from: candidates, limit: 4) { trackID in
            resolvedIDs.append(trackID)
            return "img\(trackID)"
        }
        XCTAssertEqual(images, ["img1", "img2", "img3", "img4"])
        XCTAssertEqual(resolvedIDs, [1, 2, 3, 4], "must not resolve a single track beyond what's needed")
    }

    /// The regression this type exists to prevent: the whole list must be
    /// reachable, not just a fixed-size prefix — a mix whose first several
    /// tracks don't resolve must still find its 4 images further down.
    func testFindsImagesPastWhereAFixedPrefixWouldHaveStopped() {
        // First 20 candidates all fail to resolve (simulating the exact
        // bug: tracks that happened to sit early in a sequenced mix).
        let failing = (1...20).map { CollageCandidate(trackID: Int64($0), albumID: UInt64($0)) }
        let succeeding = (21...24).map { CollageCandidate(trackID: Int64($0), albumID: UInt64($0)) }
        let images = CollageSelection.select(from: failing + succeeding, limit: 4) { trackID in
            trackID > 20 ? "img\(trackID)" : nil
        }
        XCTAssertEqual(images, ["img21", "img22", "img23", "img24"])
    }

    func testDuplicateAlbumIsSkippedWithoutCallingResolveAgain() {
        var resolvedIDs: [Int64] = []
        let candidates = [
            CollageCandidate(trackID: 1, albumID: 10),
            CollageCandidate(trackID: 2, albumID: 10), // same album as track 1
            CollageCandidate(trackID: 3, albumID: 20),
        ]
        let images = CollageSelection.select(from: candidates, limit: 4) { trackID in
            resolvedIDs.append(trackID)
            return "img\(trackID)"
        }
        XCTAssertEqual(images, ["img1", "img3"])
        XCTAssertEqual(resolvedIDs, [1, 3], "track 2 shares an already-counted album and must never be resolved")
    }

    /// Zero album ID means "no album grouping" (e.g. a single with no
    /// album metadata) -- every such candidate must count as its own,
    /// always-distinct slot, matching how the real resolver treats it.
    func testZeroAlbumIDNeverCountsAsADuplicate() {
        let candidates = [
            CollageCandidate(trackID: 1, albumID: 0),
            CollageCandidate(trackID: 2, albumID: 0),
            CollageCandidate(trackID: 3, albumID: 0),
        ]
        let images = CollageSelection.select(from: candidates, limit: 2) { "img\($0)" }
        XCTAssertEqual(images, ["img1", "img2"])
    }

    /// A failed resolve must not permanently block its album -- a later
    /// candidate from the same album (e.g. a second library copy that
    /// actually has embedded artwork) must still get a real attempt.
    func testFailedResolveDoesNotPermanentlyBlockItsAlbum() {
        var resolvedIDs: [Int64] = []
        let candidates = [
            CollageCandidate(trackID: 1, albumID: 10), // fails
            CollageCandidate(trackID: 2, albumID: 10), // same album, succeeds
        ]
        let images = CollageSelection.select(from: candidates, limit: 4) { trackID in
            resolvedIDs.append(trackID)
            return trackID == 1 ? nil : "img\(trackID)"
        }
        XCTAssertEqual(images, ["img2"])
        XCTAssertEqual(resolvedIDs, [1, 2], "track 2 must still be tried after track 1's failure")
    }

    func testOrderIsPreservedAsGiven() {
        let candidates = [
            CollageCandidate(trackID: 5, albumID: 50),
            CollageCandidate(trackID: 3, albumID: 30),
            CollageCandidate(trackID: 1, albumID: 10),
        ]
        let images = CollageSelection.select(from: candidates, limit: 4) { "img\($0)" }
        XCTAssertEqual(images, ["img5", "img3", "img1"], "selection order must follow the given (playlist) order, not be resorted")
    }
}
