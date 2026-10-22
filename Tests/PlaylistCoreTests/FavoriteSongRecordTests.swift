import XCTest
@testable import PlaylistCore

/// Covers the favourites part of the backup (added 2026-10-22): finding each
/// recorded favourite again in the library, and re-marking it in the database.
/// Reading the real Music library and the backup file itself need a device —
/// see TESTING.md.
final class FavoriteSongRecordTests: XCTestCase {

    private func record(_ id: Int64, _ title: String, _ artist: String) -> FavoriteSongRecord {
        FavoriteSongRecord(trackID: id, title: title, artist: artist, album: "Album", genre: "Jazz", durationSec: 200)
    }

    private func song(_ id: Int64, _ title: String, _ artist: String) -> FavoriteSongRecord.LibrarySong {
        FavoriteSongRecord.LibrarySong(id: id, title: title, artist: artist)
    }

    func testSameIDIsMatchedDirectly() {
        let result = FavoriteSongRecord.resolve([record(5, "Games", "Jazmin Ghent")], in: [song(5, "Games", "Jazmin Ghent")])
        XCTAssertEqual(result.matches.map(\.libraryID), [5])
        XCTAssertTrue(result.unmatched.isEmpty)
    }

    func testChangedIDFallsBackToTitleAndArtistIgnoringCaseAndSpaces() {
        let result = FavoriteSongRecord.resolve(
            [record(5, "Galaxy", "Jeff Lorber Fusion")],
            in: [song(99, "  GALAXY ", "jeff  lorber fusion")]
        )
        XCTAssertEqual(result.matches.map(\.libraryID), [99])
        XCTAssertEqual(result.matches.first?.record.trackID, 5)
    }

    /// Two library songs with the same title and artist: a guess, so not matched.
    func testAmbiguousTitleAndArtistIsNotGuessed() {
        let result = FavoriteSongRecord.resolve(
            [record(5, "Is This Love", "Bob Marley")],
            in: [song(10, "Is This Love", "Bob Marley"), song(11, "Is This Love", "Bob Marley")]
        )
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.unmatched.map(\.trackID), [5])
    }

    func testSongNoLongerInLibraryIsReportedUnmatched() {
        let result = FavoriteSongRecord.resolve([record(5, "Gone", "Nobody")], in: [song(1, "Other", "Someone")])
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.unmatched.map(\.title), ["Gone"])
    }

    func testTwoRecordsNeverMapToTheSameLibrarySong() {
        let result = FavoriteSongRecord.resolve(
            [record(5, "Same", "Artist"), record(6, "Same", "Artist")],
            in: [song(77, "Same", "Artist")]
        )
        XCTAssertEqual(result.matches.count, 1)
    }

    func testEmptyInputs() {
        XCTAssertTrue(FavoriteSongRecord.resolve([], in: [song(1, "A", "B")]).matches.isEmpty)
        let none = FavoriteSongRecord.resolve([record(1, "A", "B")], in: [])
        XCTAssertEqual(none.unmatched.count, 1)
    }

    // MARK: - Database

    func testLoadLibraryFavoritesExcludesImportedAndNonFavourites() throws {
        let db = try DatabaseManager(path: nil)
        try db.dbQueue.write { conn in
            try Track(persistentID: 1, title: "Fav", artist: "A", album: "B", genre: "C", durationSec: 200, isFavorite: true).insert(conn)
            try Track(persistentID: 2, title: "Not fav", artist: "A", album: "B", genre: "C", durationSec: 200).insert(conn)
            var imported = Track(persistentID: 3, title: "Imported fav", artist: "A", album: "B", genre: "C", durationSec: 200, isFavorite: true)
            imported.importedFileName = "x.mp3"
            try imported.insert(conn)
        }
        XCTAssertEqual(try db.loadLibraryFavoriteTracks().map(\.persistentID), [1])
    }

    /// The fresh-install case: the app has no row for the song, so one is made.
    func testApplyCreatesMissingRowAndMarksFavourite() throws {
        let db = try DatabaseManager(path: nil)
        let match = FavoriteSongRecord.Match(record: record(5, "Games", "Jazmin Ghent"), libraryID: 5)
        XCTAssertEqual(try db.applyLibraryFavorites([match]), 1)
        let tracks = try db.loadLibraryFavoriteTracks()
        XCTAssertEqual(tracks.map(\.persistentID), [5])
        XCTAssertEqual(tracks.first?.title, "Games")
    }

    /// A song already analysed keeps its analysis; only the flag changes.
    func testApplyKeepsExistingAnalysis() throws {
        let db = try DatabaseManager(path: nil)
        try db.dbQueue.write { conn in
            try Track(persistentID: 5, title: "Games", artist: "Jazmin Ghent", album: "B", genre: "C", bpm: 101.5, durationSec: 200).insert(conn)
        }
        let match = FavoriteSongRecord.Match(record: record(5, "Games", "Jazmin Ghent"), libraryID: 5)
        try db.applyLibraryFavorites([match])
        let track = try XCTUnwrap(try db.loadLibraryFavoriteTracks().first)
        XCTAssertEqual(track.bpm, 101.5)
        XCTAssertTrue(track.isFavorite)
    }

    func testRecordRoundTripsThroughJSON() throws {
        let original = [record(-9_000_000_000_000_000_000, "Big id", "Artist")]
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode([FavoriteSongRecord].self, from: data), original)
    }
}
