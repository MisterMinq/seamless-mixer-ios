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

    /// Covers `loadPlaylistDetail` (added for Playlist Detail, CLAUDE.md
    /// Version History 0.16.0) — the first query in the codebase to
    /// filter/order beyond a primary-key lookup, written as raw SQL rather
    /// than GRDB's query-interface operators specifically because it was
    /// new, untested territory (see that function's own doc comment).
    /// Inserts tracks out of `position` order to confirm the query actually
    /// sorts by `position`, not insertion order — the one thing a naive
    /// "it returned some rows" check wouldn't catch.
    func testLoadPlaylistDetailReturnsSourcesAndOrderedTracks() throws {
        let db = try DatabaseManager(path: nil)

        let playlistID: Int64 = try db.dbQueue.write { dbConn in
            var trackA = Track(persistentID: 1, title: "A", artist: "X", album: "Y", genre: "Smooth jazz", durationSec: 200)
            try trackA.insert(dbConn)
            var trackB = Track(persistentID: 2, title: "B", artist: "Z", album: "W", genre: "Smooth jazz", durationSec: 180)
            try trackB.insert(dbConn)

            var playlist = Playlist(name: "Smooth jazz Seamless Mix", mode: .energyWave)
            try playlist.insert(dbConn)

            var source = PlaylistSource(playlistID: playlist.id!, sourceType: .genre, sourceValue: "smooth-jazz", sourceLabel: "Smooth jazz")
            try source.insert(dbConn)

            // Deliberately inserted out of position order.
            var second = PlaylistTrack(playlistID: playlist.id!, trackPersistentID: 2, position: 1, crossfadeStartOffsetSec: 175, tempoNudgePct: 0)
            try second.insert(dbConn)
            var first = PlaylistTrack(playlistID: playlist.id!, trackPersistentID: 1, position: 0, crossfadeStartOffsetSec: 195, tempoNudgePct: 0.02)
            try first.insert(dbConn)

            return playlist.id!
        }

        let detail = try db.loadPlaylistDetail(playlistID: playlistID)
        XCTAssertEqual(detail.sources.count, 1)
        XCTAssertEqual(detail.sources.first?.sourceLabel, "Smooth jazz")
        XCTAssertEqual(detail.tracks.map(\.track.title), ["A", "B"])
        XCTAssertEqual(detail.tracks.map(\.position), [0, 1])
    }

    /// Covers `removeTrack` (added for Playlist Detail's per-track "..."
    /// menu, CLAUDE.md Version History 0.16.7) — inserts 3 tracks at
    /// positions 0/1/2, removes the middle one, and confirms both halves of
    /// the contract: the row is actually gone, and the remaining two are
    /// renumbered to stay contiguous (0/1, not 0/2) rather than leaving a
    /// gap — the renumbering is the part a naive "row count decreased by
    /// one" check wouldn't catch.
    func testRemoveTrackDeletesAndRenumbersPositions() throws {
        let db = try DatabaseManager(path: nil)

        let playlistID: Int64 = try db.dbQueue.write { dbConn in
            for id: Int64 in [1, 2, 3] {
                var track = Track(persistentID: id, title: "Track \(id)", artist: "X", album: "Y", genre: "Smooth jazz", durationSec: 200)
                try track.insert(dbConn)
            }

            var playlist = Playlist(name: "Smooth jazz Seamless Mix", mode: .energyWave)
            try playlist.insert(dbConn)

            for (trackID, position) in [(1, 0), (2, 1), (3, 2)] {
                var playlistTrack = PlaylistTrack(playlistID: playlist.id!, trackPersistentID: Int64(trackID), position: position, crossfadeStartOffsetSec: 180, tempoNudgePct: 0)
                try playlistTrack.insert(dbConn)
            }

            return playlist.id!
        }

        let middleTrackID = try db.dbQueue.read { dbConn -> Int64 in
            let row = try PlaylistTrack.fetchOne(dbConn, sql: "SELECT * FROM playlist_tracks WHERE playlist_id = ? AND track_persistent_id = 2", arguments: [playlistID])
            return row!.id!
        }

        try db.removeTrack(playlistTrackID: middleTrackID, fromPlaylistID: playlistID)

        let remaining = try db.loadPlaylistDetail(playlistID: playlistID).tracks
        XCTAssertEqual(remaining.map(\.track.title), ["Track 1", "Track 3"])
        XCTAssertEqual(remaining.map(\.position), [0, 1])
    }
}
