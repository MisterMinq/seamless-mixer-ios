import XCTest
@testable import PlaylistCore

/// `ImportSourceHint` (the readable "where it was imported from" note) and the
/// `sourceFolder` handling of `ImportedSongRecord` (CLAUDE.md 0.26.40).
final class ImportSourceHintTests: XCTestCase {

    // MARK: - ImportSourceHint.describe

    func testICloudDriveFolder() {
        let path = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Music/Jazz/So What.mp3"
        XCTAssertEqual(ImportSourceHint.describe(filePath: path), "iCloud Drive › Music › Jazz")
    }

    func testICloudDriveRoot() {
        let path = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/song.mp3"
        XCTAssertEqual(ImportSourceHint.describe(filePath: path), "iCloud Drive")
    }

    func testOnMyIPhoneFolder() {
        let path = "/private/var/mobile/Containers/Shared/AppGroup/ABC-123/File Provider Storage/Music/Funk/song.mp3"
        XCTAssertEqual(ImportSourceHint.describe(filePath: path), "On My iPhone › Music › Funk")
    }

    func testOnMyIPhoneRoot() {
        let path = "/private/var/mobile/Containers/Shared/AppGroup/ABC-123/File Provider Storage/song.mp3"
        XCTAssertEqual(ImportSourceHint.describe(filePath: path), "On My iPhone")
    }

    func testAnotherAppsICloudFolder() {
        let path = "/private/var/mobile/Library/Mobile Documents/iCloud~com~example~Recorder/Documents/Takes/a.m4a"
        XCTAssertEqual(ImportSourceHint.describe(filePath: path), "iCloud (Recorder) › Takes")
    }

    func testThirdPartyCloudProviders() {
        XCTAssertEqual(
            ImportSourceHint.describe(filePath: "/private/var/mobile/Library/CloudStorage/Dropbox-Personal/Music/a.mp3"),
            "Dropbox › Music"
        )
        XCTAssertEqual(
            ImportSourceHint.describe(filePath: "/private/var/mobile/Library/CloudStorage/GoogleDrive-me@example.com/a.mp3"),
            "GoogleDrive"
        )
    }

    func testUnknownLocationFallsBackToTheLastTwoFolders() {
        XCTAssertEqual(ImportSourceHint.describe(filePath: "/Users/andy/Music/Disco/a.mp3"), "Music › Disco")
        XCTAssertEqual(ImportSourceHint.describe(filePath: "/Disco/a.mp3"), "Disco")
    }

    func testDeepFoldersKeepOnlyTheLastThreeLevels() {
        let path = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/A/B/C/D/E/song.mp3"
        XCTAssertEqual(ImportSourceHint.describe(filePath: path), "iCloud Drive › C › D › E")
    }

    func testPathWithNoFolderGivesNothing() {
        XCTAssertNil(ImportSourceHint.describe(filePath: "song.mp3"))
        XCTAssertNil(ImportSourceHint.describe(filePath: "/song.mp3"))
        XCTAssertNil(ImportSourceHint.describe(filePath: ""))
    }

    // MARK: - ImportedSongRecord.sourceFolder

    private func record(_ id: Int64, folder: String? = nil, title: String = "T") -> ImportedSongRecord {
        ImportedSongRecord(
            trackID: id, title: title, artist: "A", album: "B", genre: "G", durationSec: 100,
            sourceFolder: folder
        )
    }

    func testMergeKeepsAKnownFolderWhenTheFresherRecordHasNone() {
        let existing = [record(1, folder: "On My iPhone › Music", title: "Old")]
        let incoming = [record(1, folder: nil, title: "New")]
        let merged = ImportedSongRecord.merged(existing: existing, incoming: incoming)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].title, "New", "incoming still wins for everything else")
        XCTAssertEqual(merged[0].sourceFolder, "On My iPhone › Music")
    }

    func testMergeLetsANewerFolderReplaceTheOldOne() {
        let existing = [record(1, folder: "Old folder")]
        let incoming = [record(1, folder: "New folder")]
        XCTAssertEqual(ImportedSongRecord.merged(existing: existing, incoming: incoming)[0].sourceFolder, "New folder")
    }

    func testMergeStillAddsNewSongsAndKeepsUntouchedOnes() {
        let merged = ImportedSongRecord.merged(
            existing: [record(1, folder: "X"), record(2)],
            incoming: [record(3, folder: "Y")]
        )
        XCTAssertEqual(merged.map(\.trackID), [1, 2, 3])
        XCTAssertEqual(merged[0].sourceFolder, "X")
        XCTAssertNil(merged[1].sourceFolder)
        XCTAssertEqual(merged[2].sourceFolder, "Y")
    }

    func testSourceFolderCountsGroupAndOrderThem() {
        let records = [
            record(1, folder: "B folder"), record(2, folder: "A folder"), record(3, folder: "B folder"),
            record(4, folder: "C folder"), record(5, folder: nil), record(6, folder: "")
        ]
        XCTAssertEqual(
            ImportedSongRecord.sourceFolderCounts(of: records),
            [
                ImportedSongRecord.SourceFolderCount(folder: "B folder", count: 2),
                ImportedSongRecord.SourceFolderCount(folder: "A folder", count: 1),
                ImportedSongRecord.SourceFolderCount(folder: "C folder", count: 1)
            ]
        )
        XCTAssertTrue(ImportedSongRecord.sourceFolderCounts(of: [record(1), record(2)]).isEmpty)
    }

    func testARecordWrittenBeforeSourceFoldersExistedStillDecodes() throws {
        let oldJSON = """
        {"trackID": 7, "title": "T", "artist": "A", "album": "B", "genre": "G",
         "durationSec": 120.0, "isFavorite": true, "fileSizeBytes": 4096}
        """
        let decoded = try JSONDecoder().decode(ImportedSongRecord.self, from: Data(oldJSON.utf8))
        XCTAssertEqual(decoded.trackID, 7)
        XCTAssertNil(decoded.sourceFolder)
    }

    func testSourceFolderSurvivesAJSONRoundTrip() throws {
        let original = record(9, folder: "iCloud Drive › Music")
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ImportedSongRecord.self, from: data), original)
    }
}
