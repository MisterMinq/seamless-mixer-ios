import XCTest
@testable import PlaylistCore

/// Smoke test for the schema/migrations — round-trips one row through each
/// table and checks the relationships hold. Not a substitute for testing
/// against a real analyzed library; that has to happen in Xcode/Simulator,
/// which isn't available in the environment this was written in.
final class DatabaseManagerTests: XCTestCase {

    func testMigrationCreatesAllFourTables() throws {
        let db = try DatabaseManager(path: nil)
        let tableNames = try db.dbQueue.read { try $0.tableExists("tracks") && $0.tableExists("playlists") && $0.tableExists("playlist_sources") && $0.tableExists("playlist_tracks") }
        XCTAssertTrue(tableNames)
    }

    func testTrackRoundTrip() throws {
        let db = try DatabaseManager(path: nil)
        var track = Track(
            persistentID: 12345,
            title: "Waltz for Debby",
            artist: "Bill Evans Trio",
            album: "Waltz for Debby",
            genre: "Smooth jazz",
            durationSec: 340
        )
        try db.dbQueue.write { try track.insert($0) }

        let fetched = try db.dbQueue.read { try Track.fetchOne($0, key: 12345) }
        XCTAssertEqual(fetched?.title, "Waltz for Debby")
        XCTAssertFalse(fetched?.isAnalyzed ?? true) // no bpm/key/energy/brightness set yet
    }

    func testPlaylistWithSourcesAndTracks() throws {
        let db = try DatabaseManager(path: nil)

        try db.dbQueue.write { dbConn in
            var track = Track(persistentID: 1, title: "A", artist: "X", album: "Y", genre: "Smooth jazz", durationSec: 200)
            try track.insert(dbConn)

            var playlist = Playlist(name: "Smooth jazz Seamless Mix", mode: .energyWave)
            try playlist.insert(dbConn)

            var pSource = PlaylistSource(playlistID: playlist.id!, sourceType: .genre, sourceValue: "smooth-jazz", sourceLabel: "Smooth jazz")
            try pSource.insert(dbConn)

            var pTrack = PlaylistTrack(playlistID: playlist.id!, trackPersistentID: 1, position: 0, crossfadeStartOffsetSec: 180, tempoNudgePct: 0.03)
            try pTrack.insert(dbConn)
        }

        let (sourceCount, trackCount) = try db.dbQueue.read { dbConn -> (Int, Int) in
            let sources = try PlaylistSource.fetchCount(dbConn)
            let tracks = try PlaylistTrack.fetchCount(dbConn)
            return (sources, tracks)
        }
        XCTAssertEqual(sourceCount, 1)
        XCTAssertEqual(trackCount, 1)
    }
}
