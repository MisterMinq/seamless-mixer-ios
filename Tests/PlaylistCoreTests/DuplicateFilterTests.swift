import XCTest
@testable import PlaylistCore

/// Regression coverage for `DuplicateFilter` — added 2026-09-05 after Andy
/// found the same song playing 4 times in a row in a whole-library mix. See
/// that type's own doc comment for the root cause (genuine duplicate library
/// entries score as "perfect neighbors" to the sequencer) and why title +
/// artist + duration is the match signal.
final class DuplicateFilterTests: XCTestCase {

    private static var nextID: Int64 = 1

    private func makeTrack(title: String, artist: String, durationSec: Double) -> Track {
        defer { Self.nextID += 1 }
        return Track(persistentID: Self.nextID, title: title, artist: artist, album: "", genre: "", durationSec: durationSec)
    }

    func testEmptyPoolProducesNoDuplicates() {
        let summary = DuplicateFilter.summarize(pool: [])
        XCTAssertEqual(summary.uniqueTracks, [])
        XCTAssertEqual(summary.duplicateCount, 0)
        XCTAssertTrue(summary.duplicateGroups.isEmpty)
    }

    func testNoDuplicatesInAnEntirelyDistinctPool() {
        let pool = [
            makeTrack(title: "Song A", artist: "Artist 1", durationSec: 200),
            makeTrack(title: "Song B", artist: "Artist 2", durationSec: 210),
            makeTrack(title: "Song C", artist: "Artist 1", durationSec: 220)
        ]
        let summary = DuplicateFilter.summarize(pool: pool)
        XCTAssertEqual(summary.uniqueTracks.count, 3)
        XCTAssertEqual(summary.duplicateCount, 0)
        XCTAssertTrue(summary.duplicateGroups.isEmpty)
    }

    func testExactDuplicateSameTitleArtistAndDurationIsCollapsed() {
        let original = makeTrack(title: "Is This Love", artist: "Bob Marley", durationSec: 237.0)
        let duplicate = makeTrack(title: "Is This Love", artist: "Bob Marley", durationSec: 237.4)
        let summary = DuplicateFilter.summarize(pool: [original, duplicate])
        XCTAssertEqual(summary.uniqueTracks.count, 1)
        XCTAssertEqual(summary.duplicateCount, 1)
        XCTAssertEqual(summary.duplicateGroups.count, 1)
        XCTAssertEqual(summary.duplicateGroups[0].count, 2)
    }

    /// Case/whitespace shouldn't matter -- the same library import re-synced
    /// from a different source could easily differ only in casing.
    func testMatchIsCaseAndWhitespaceInsensitive() {
        let original = makeTrack(title: "Is This Love", artist: "Bob Marley", durationSec: 237.0)
        let duplicate = makeTrack(title: "  is this love  ", artist: "BOB MARLEY", durationSec: 236.5)
        let summary = DuplicateFilter.summarize(pool: [original, duplicate])
        XCTAssertEqual(summary.uniqueTracks.count, 1)
        XCTAssertEqual(summary.duplicateCount, 1)
    }

    /// Same title+artist but a real, different recording (e.g. a live
    /// version) -- duration is far enough apart that this must NOT be
    /// treated as a duplicate.
    func testSameTitleAndArtistButVeryDifferentDurationIsNotADuplicate() {
        let studio = makeTrack(title: "Is This Love", artist: "Bob Marley", durationSec: 237.0)
        let live = makeTrack(title: "Is This Love", artist: "Bob Marley", durationSec: 412.0)
        let summary = DuplicateFilter.summarize(pool: [studio, live])
        XCTAssertEqual(summary.uniqueTracks.count, 2)
        XCTAssertEqual(summary.duplicateCount, 0)
        XCTAssertTrue(summary.duplicateGroups.isEmpty)
    }

    /// Two different artists covering the same title -- title alone matches,
    /// artist doesn't, must never be treated as a duplicate regardless of
    /// how close the durations happen to be. Directly answers Andy's own
    /// question: "I am not talking about covers by other artists."
    func testSameTitleDifferentArtistIsNeverADuplicate() {
        let coverA = makeTrack(title: "Hallelujah", artist: "Jeff Buckley", durationSec: 234.0)
        let coverB = makeTrack(title: "Hallelujah", artist: "Rufus Wainwright", durationSec: 234.2)
        let summary = DuplicateFilter.summarize(pool: [coverA, coverB])
        XCTAssertEqual(summary.uniqueTracks.count, 2)
        XCTAssertEqual(summary.duplicateCount, 0)
    }

    /// Exactly Andy's real report: the same song appearing 4 times.
    func testFourCopiesOfTheSameSongCollapseToOne() {
        let pool = (0..<4).map { i in
            makeTrack(title: "Games", artist: "Jazmin Ghent", durationSec: 200.0 + Double(i) * 0.3)
        }
        let summary = DuplicateFilter.summarize(pool: pool)
        XCTAssertEqual(summary.uniqueTracks.count, 1)
        XCTAssertEqual(summary.duplicateCount, 3)
        XCTAssertEqual(summary.duplicateGroups.count, 1)
        XCTAssertEqual(summary.duplicateGroups[0].count, 4)
    }

    /// A chain of tracks each within tolerance of its immediate neighbor,
    /// but the first and last are more than the tolerance apart -- single-
    /// linkage clustering should still group all of them together, since
    /// that's still the same underlying "these are all copies of one song"
    /// case as far as sequencing back-to-back duplicates goes.
    func testTransitiveClusteringGroupsAChainWithinTolerance() {
        let pool = [
            makeTrack(title: "Song", artist: "Artist", durationSec: 200.0),
            makeTrack(title: "Song", artist: "Artist", durationSec: 201.5),
            makeTrack(title: "Song", artist: "Artist", durationSec: 203.0)
        ]
        let summary = DuplicateFilter.summarize(pool: pool, durationToleranceSec: 2.0)
        XCTAssertEqual(summary.uniqueTracks.count, 1)
        XCTAssertEqual(summary.duplicateGroups[0].count, 3)
    }

    func testPreservesOriginalPoolOrderInUniqueTracks() {
        let a = makeTrack(title: "A", artist: "X", durationSec: 100)
        let b = makeTrack(title: "B", artist: "X", durationSec: 100)
        let c = makeTrack(title: "C", artist: "X", durationSec: 100)
        let summary = DuplicateFilter.summarize(pool: [a, b, c])
        XCTAssertEqual(summary.uniqueTracks.map(\.persistentID), [a.persistentID, b.persistentID, c.persistentID])
    }

    func testCustomToleranceIsRespected() {
        let a = makeTrack(title: "Song", artist: "Artist", durationSec: 200.0)
        let b = makeTrack(title: "Song", artist: "Artist", durationSec: 200.4)
        // Well within the default 2.0s tolerance, but not within a much
        // stricter custom one.
        let summary = DuplicateFilter.summarize(pool: [a, b], durationToleranceSec: 0.1)
        XCTAssertEqual(summary.uniqueTracks.count, 2)
        XCTAssertEqual(summary.duplicateCount, 0)
    }
}
