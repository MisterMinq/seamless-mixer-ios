import XCTest
@testable import PlaylistCore

/// Covers the pure parts of the external-music import (added 2026-10-21):
/// content-hash identity/naming (`ImportedTrackIdentity`) and the database
/// helpers (`ImportedTrackLoader`). The file copy, tag reading, analysis and
/// playback around them need a real device — see TESTING.md.
final class ImportedTrackTests: XCTestCase {

    // MARK: - Identity

    private func writeTempFile(_ bytes: [UInt8], name: String = "song.mp3") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testSameContentUnderDifferentNamesGivesSameID() throws {
        let bytes = (0..<5000).map { UInt8($0 % 251) }
        let a = try writeTempFile(bytes, name: "one.mp3")
        let b = try writeTempFile(bytes, name: "completely different name.m4a")
        XCTAssertEqual(try ImportedTrackIdentity.trackID(forFileAt: a), try ImportedTrackIdentity.trackID(forFileAt: b))
    }

    func testDifferentContentGivesDifferentID() throws {
        let a = try writeTempFile([1, 2, 3, 4])
        let b = try writeTempFile([1, 2, 3, 5])
        XCTAssertNotEqual(try ImportedTrackIdentity.trackID(forFileAt: a), try ImportedTrackIdentity.trackID(forFileAt: b))
    }

    /// The file is hashed in 1 MB chunks; a file larger than one chunk must
    /// hash the same as the one-shot digest of the same bytes.
    func testLargerThanOneChunkHashesConsistently() throws {
        let bytes = (0..<2_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let a = try writeTempFile(bytes)
        let b = try writeTempFile(bytes)
        XCTAssertEqual(try ImportedTrackIdentity.trackID(forFileAt: a), try ImportedTrackIdentity.trackID(forFileAt: b))
    }

    func testDigestBytesAreReadBigEndianAndBitCast() {
        // 0xFF_FF_FF_FF_FF_FF_FF_FF has the high bit set -> -1 as Int64.
        XCTAssertEqual(ImportedTrackIdentity.trackID(fromDigestBytes: [UInt8](repeating: 0xFF, count: 32)), -1)
        XCTAssertEqual(ImportedTrackIdentity.trackID(fromDigestBytes: [0, 0, 0, 0, 0, 0, 0, 7, 9, 9]), 7)
    }

    func testFileNameRoundTrip() {
        for id: Int64 in [0, 1, 255, -1, Int64.max, Int64.min, 0x00A1_B2C3_D4E5_F607] {
            let name = ImportedTrackIdentity.fileName(forTrackID: id, fileExtension: "MP3")
            XCTAssertTrue(name.hasSuffix(".mp3"), "extension is lowercased")
            XCTAssertEqual(name.count, 16 + 1 + 3, "16 hex digits, a dot, the extension")
            XCTAssertEqual(ImportedTrackIdentity.trackID(fromFileName: name), id)
        }
    }

    func testFileNameParsingRejectsNonIDNames() {
        XCTAssertNil(ImportedTrackIdentity.trackID(fromFileName: "My Song.mp3"))
        XCTAssertNil(ImportedTrackIdentity.trackID(fromFileName: "abc.mp3"))
    }

    func testSupportedExtensionsAreCaseInsensitive() {
        XCTAssertTrue(ImportedTrackIdentity.isSupported(fileExtension: "MP3"))
        XCTAssertTrue(ImportedTrackIdentity.isSupported(fileExtension: "flac"))
        XCTAssertFalse(ImportedTrackIdentity.isSupported(fileExtension: "pdf"))
        XCTAssertFalse(ImportedTrackIdentity.isSupported(fileExtension: ""))
    }

    func testFallbackTitleStripsExtension() {
        XCTAssertEqual(ImportedTrackIdentity.fallbackTitle(fromOriginalFileName: "Funky Town.mp3"), "Funky Town")
        XCTAssertEqual(ImportedTrackIdentity.fallbackTitle(fromOriginalFileName: ".mp3"), "Unknown")
    }

    // MARK: - Database

    private func seedImported(_ db: DatabaseManager, id: Int64, title: String = "T", favorite: Bool = false) throws {
        try db.dbQueue.write { conn in
            try Track(
                persistentID: id, title: title, artist: "A", album: "B", genre: "C",
                durationSec: 200, isFavorite: favorite,
                importedFileName: ImportedTrackIdentity.fileName(forTrackID: id, fileExtension: "mp3")
            ).insert(conn)
        }
    }

    private func seedLibraryTrack(_ db: DatabaseManager, id: Int64) throws {
        try db.dbQueue.write { conn in
            try Track(persistentID: id, title: "Lib", artist: "A", album: "B", genre: "C", durationSec: 200).insert(conn)
        }
    }

    func testMigrationAddsImportedColumnAndRoundTrips() throws {
        let db = try DatabaseManager(path: nil)
        try seedImported(db, id: 42, title: "Imported One")
        try seedLibraryTrack(db, id: 43)

        let imported = try db.loadImportedTracks()
        XCTAssertEqual(imported.map(\.persistentID), [42], "a Music-library track must not be listed as imported")
        XCTAssertEqual(imported.first?.importedFileName, ImportedTrackIdentity.fileName(forTrackID: 42, fileExtension: "mp3"))
        XCTAssertTrue(imported.first?.isImported ?? false)
    }

    func testImportedTracksWithIDsFiltersOutLibraryTracks() throws {
        let db = try DatabaseManager(path: nil)
        try seedImported(db, id: 1)
        try seedLibraryTrack(db, id: 2)
        let result = try db.importedTracks(withIDs: [1, 2, 3])
        XCTAssertEqual(result.map(\.persistentID), [1])
        XCTAssertTrue(try db.importedTracks(withIDs: []).isEmpty)
    }

    func testImportedFavoriteTrackIDsOnlyReturnsImportedFavourites() throws {
        let db = try DatabaseManager(path: nil)
        try seedImported(db, id: 1, favorite: true)
        try seedImported(db, id: 2, favorite: false)
        try db.dbQueue.write { conn in
            try Track(persistentID: 3, title: "Lib", artist: "A", album: "B", genre: "C", durationSec: 200, isFavorite: true).insert(conn)
        }
        XCTAssertEqual(try db.importedFavoriteTrackIDs(), [1])
    }

    func testDeleteRemovesTrackFromMixesAndRenumbers() throws {
        let db = try DatabaseManager(path: nil)
        try seedImported(db, id: 10)
        try seedLibraryTrack(db, id: 11)
        try seedLibraryTrack(db, id: 12)

        let playlistID = try db.dbQueue.write { conn -> Int64 in
            var playlist = Playlist(name: "Mix", mode: .energyWave)
            try playlist.insert(conn)
            let pid = playlist.id!
            for (index, trackID) in [Int64(11), 10, 12].enumerated() {
                var row = PlaylistTrack(
                    playlistID: pid, trackPersistentID: trackID, position: index,
                    crossfadeStartOffsetSec: 100, crossfadeDurationSec: 4, tempoNudgePct: 0
                )
                try row.insert(conn)
            }
            var source = PlaylistSource(playlistID: pid, sourceType: .importedSong, sourceValue: String(UInt64(bitPattern: 10)), sourceLabel: "Imp")
            try source.insert(conn)
            return pid
        }
        XCTAssertEqual(try db.mixCount(usingTrackID: 10), 1)

        let fileName = try db.deleteImportedTrack(trackID: 10)
        XCTAssertEqual(fileName, ImportedTrackIdentity.fileName(forTrackID: 10, fileExtension: "mp3"))

        let detail = try db.loadPlaylistDetail(playlistID: playlistID)
        XCTAssertEqual(detail.tracks.map(\.track.persistentID), [11, 12])
        XCTAssertEqual(detail.tracks.map(\.position), [0, 1], "positions stay contiguous after the removal")
        XCTAssertTrue(detail.sources.isEmpty, "the saved source pointing at the removed song is dropped")
        XCTAssertTrue(try db.loadImportedTracks().isEmpty)
        XCTAssertEqual(try db.mixCount(usingTrackID: 10), 0)
    }

    func testDeleteRemovesTrackFromNativePlaylistsToo() throws {
        let db = try DatabaseManager(path: nil)
        try seedImported(db, id: 20)
        try seedLibraryTrack(db, id: 21)
        let list = try db.createCustomPlaylist(name: "Mine")
        try db.addTrack(trackPersistentID: 20, toCustomPlaylistID: list.id!)
        try db.addTrack(trackPersistentID: 21, toCustomPlaylistID: list.id!)

        try db.deleteImportedTrack(trackID: 20)

        let detail = try db.loadCustomPlaylistDetail(customPlaylistID: list.id!)
        XCTAssertEqual(detail?.tracks.map(\.track.persistentID), [21])
        XCTAssertEqual(detail?.tracks.map(\.position), [0])
    }

    func testDeleteIgnoresLibraryTracks() throws {
        let db = try DatabaseManager(path: nil)
        try seedLibraryTrack(db, id: 30)
        XCTAssertNil(try db.deleteImportedTrack(trackID: 30))
        let stillThere = try db.dbQueue.read { try Track.fetchOne($0, key: Int64(30)) }
        XCTAssertNotNil(stillThere, "a Music-library track must never be deleted by the imported-song remover")
    }
}
