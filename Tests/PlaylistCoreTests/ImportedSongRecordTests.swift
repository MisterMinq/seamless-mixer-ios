import XCTest
@testable import PlaylistCore

/// Covers `ImportedSongRecord` (added 2026-10-21): the pure logic behind the
/// imported-songs backup record and the "missing songs" list.
final class ImportedSongRecordTests: XCTestCase {

    private func record(_ id: Int64, _ title: String, artist: String = "A", size: Int64? = 1000, fav: Bool = false) -> ImportedSongRecord {
        ImportedSongRecord(
            trackID: id, title: title, artist: artist, album: "Al", genre: "G",
            durationSec: 200, isFavorite: fav, fileSizeBytes: size
        )
    }

    func testMissingExcludesPresentAndSortsByTitle() {
        let records = [record(1, "zebra"), record(2, "Apple"), record(3, "mango")]
        let missing = ImportedSongRecord.missing(from: records, presentTrackIDs: [3])
        XCTAssertEqual(missing.map(\.trackID), [2, 1], "present song dropped; rest sorted case-insensitively by title")
    }

    func testMissingBreaksTitleTiesByArtist() {
        let records = [record(1, "Song", artist: "Zed"), record(2, "Song", artist: "Abe")]
        XCTAssertEqual(ImportedSongRecord.missing(from: records, presentTrackIDs: []).map(\.trackID), [2, 1])
    }

    func testMissingOfEmptyIsEmpty() {
        XCTAssertTrue(ImportedSongRecord.missing(from: [], presentTrackIDs: [1]).isEmpty)
    }

    func testMergedIsUnionWithIncomingWinning() {
        let existing = [record(1, "Old title"), record(2, "Only existing")]
        let incoming = [record(1, "New title", fav: true), record(3, "Only incoming")]
        let merged = ImportedSongRecord.merged(existing: existing, incoming: incoming)
        XCTAssertEqual(merged.map(\.trackID), [1, 2, 3])
        XCTAssertEqual(merged[0].title, "New title")
        XCTAssertTrue(merged[0].isFavorite)
    }

    func testMergedWithEmptySides() {
        let one = [record(1, "A")]
        XCTAssertEqual(ImportedSongRecord.merged(existing: [], incoming: one), one)
        XCTAssertEqual(ImportedSongRecord.merged(existing: one, incoming: []), one)
    }

    func testCandidateSizesUseKnownSizes() {
        let sizes = ImportedSongRecord.candidateSizes(for: [record(1, "A", size: 10), record(2, "B", size: 20), record(3, "C", size: 10)])
        XCTAssertEqual(sizes, [10, 20])
    }

    func testCandidateSizesIsNilWhenAnySizeUnknownOrNoRecords() {
        XCTAssertNil(ImportedSongRecord.candidateSizes(for: [record(1, "A", size: 10), record(2, "B", size: nil)]),
                     "one unknown size means nothing can be safely skipped")
        XCTAssertNil(ImportedSongRecord.candidateSizes(for: []))
    }

    /// The backup file is JSON; ids are content hashes that routinely use the
    /// full 64-bit range, so the round trip must survive extreme values.
    func testJSONRoundTripKeepsExtremeIDs() throws {
        let records = [record(Int64.min, "Min"), record(Int64.max, "Max"), record(-1, "Neg", size: nil)]
        let data = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode([ImportedSongRecord].self, from: data)
        XCTAssertEqual(decoded, records)
    }

    func testInitFromTrackCopiesDescriptiveFields() {
        let track = Track(
            persistentID: 7, title: "T", artist: "Ar", album: "Al", genre: "Ge", durationSec: 123,
            isFavorite: true, importedFileName: "x.mp3"
        )
        let rec = ImportedSongRecord(track: track, fileSizeBytes: 555)
        XCTAssertEqual(rec.trackID, 7)
        XCTAssertEqual(rec.title, "T")
        XCTAssertEqual(rec.durationSec, 123)
        XCTAssertTrue(rec.isFavorite)
        XCTAssertEqual(rec.fileSizeBytes, 555)
    }
}
