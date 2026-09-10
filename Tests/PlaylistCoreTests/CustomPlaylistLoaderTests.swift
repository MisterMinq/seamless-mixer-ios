import XCTest
@testable import PlaylistCore

/// Covers the new `CustomPlaylist`/`CustomPlaylistTrack` data layer (Batch 2
/// of the confirmed "Add to Playlist" design, 2026-09-07) — mirrors
/// `DatabaseManagerTests`' own "round-trip through the real schema" style.
final class CustomPlaylistLoaderTests: XCTestCase {

    func testMigrationCreatesBothNewTables() throws {
        let db = try DatabaseManager(path: nil)
        let exist = try db.dbQueue.read { try $0.tableExists("custom_playlists") && $0.tableExists("custom_playlist_tracks") }
        XCTAssertTrue(exist)
    }

    func testCreateRenameDelete() throws {
        let db = try DatabaseManager(path: nil)
        let created = try db.createCustomPlaylist(name: "Birthday Warm-Up")
        XCTAssertNotNil(created.id)
        XCTAssertNil(created.originApplePlaylistPersistentID)

        try db.renameCustomPlaylist(customPlaylistID: created.id!, to: "Birthday Set")
        let all = try db.loadCustomPlaylists()
        XCTAssertEqual(all.first?.name, "Birthday Set")

        try db.deleteCustomPlaylist(customPlaylistID: created.id!)
        XCTAssertTrue(try db.loadCustomPlaylists().isEmpty)
    }

    /// A `CustomPlaylist`'s own `originApplePlaylistPersistentID` bit-casts
    /// a real `MPMediaEntityPersistentID` (UInt64) into a signed `Int64`
    /// column — this project has hit real bugs before from exactly this
    /// class of large, high-bit-set value (see `MediaLibraryResolver`'s own
    /// doc comments on why persistentID predicates were replaced with
    /// local `Set` filtering). This deliberately uses a value with the high
    /// bit set (well past `Int64.max`) to prove the round-trip survives
    /// that, not just a small, coincidentally-safe test number.
    func testOriginPersistentIDRoundTripsHighBitValue() throws {
        let db = try DatabaseManager(path: nil)
        let bigID: UInt64 = 0xFFFF_FFFF_0000_0001 // > Int64.max, high bit set
        let created = try db.createCustomPlaylist(name: "Copied Playlist", originApplePlaylistPersistentID: bigID)
        XCTAssertEqual(created.originApplePlaylistPersistentID, bigID)

        let refetched = try db.customPlaylist(originApplePlaylistPersistentID: bigID)
        XCTAssertEqual(refetched?.id, created.id)

        let all = try db.loadCustomPlaylists()
        XCTAssertEqual(all.first?.originApplePlaylistPersistentID, bigID)
    }

    func testAddTrackAppendsAndSkipsDuplicates() throws {
        let db = try DatabaseManager(path: nil)
        try seedTrack(db, id: 1)
        try seedTrack(db, id: 2)
        let playlist = try db.createCustomPlaylist(name: "Test")

        try db.addTrack(trackPersistentID: 1, toCustomPlaylistID: playlist.id!)
        try db.addTrack(trackPersistentID: 2, toCustomPlaylistID: playlist.id!)
        // Adding the same song again should be a no-op, not a duplicate row.
        try db.addTrack(trackPersistentID: 1, toCustomPlaylistID: playlist.id!)

        let detail = try db.loadCustomPlaylistDetail(customPlaylistID: playlist.id!)
        XCTAssertEqual(detail?.tracks.count, 2)
        XCTAssertEqual(detail?.tracks.map(\.track.persistentID), [1, 2])
        XCTAssertEqual(detail?.tracks.map(\.position), [0, 1])
    }

    /// The real regression this test guards against: the first draft of
    /// `addTrack` computed the next position via a raw `MAX(position)` SQL
    /// scalar, which returns a NULL row (and traps GRDB's non-optional
    /// scalar decode) the very first time a track is added to a brand-new,
    /// empty playlist — caught and fixed before ever pushing, not by a
    /// real failure. This is the exact scenario that would have crashed.
    func testAddFirstTrackToEmptyPlaylistDoesNotCrash() throws {
        let db = try DatabaseManager(path: nil)
        try seedTrack(db, id: 1)
        let playlist = try db.createCustomPlaylist(name: "Fresh")

        try db.addTrack(trackPersistentID: 1, toCustomPlaylistID: playlist.id!)

        let detail = try db.loadCustomPlaylistDetail(customPlaylistID: playlist.id!)
        XCTAssertEqual(detail?.tracks.first?.position, 0)
    }

    func testRemoveCustomPlaylistTrackRenumbersPositions() throws {
        let db = try DatabaseManager(path: nil)
        try seedTrack(db, id: 1)
        try seedTrack(db, id: 2)
        try seedTrack(db, id: 3)
        let playlist = try db.createCustomPlaylist(name: "Test")
        try db.addTrack(trackPersistentID: 1, toCustomPlaylistID: playlist.id!)
        try db.addTrack(trackPersistentID: 2, toCustomPlaylistID: playlist.id!)
        try db.addTrack(trackPersistentID: 3, toCustomPlaylistID: playlist.id!)

        let middleRowID = try db.loadCustomPlaylistDetail(customPlaylistID: playlist.id!)!.tracks[1].id
        try db.removeCustomPlaylistTrack(id: middleRowID, fromCustomPlaylistID: playlist.id!)

        let detail = try db.loadCustomPlaylistDetail(customPlaylistID: playlist.id!)
        XCTAssertEqual(detail?.tracks.map(\.track.persistentID), [1, 3])
        XCTAssertEqual(detail?.tracks.map(\.position), [0, 1])
    }

    func testCopyTracksBulkImportsInOrder() throws {
        let db = try DatabaseManager(path: nil)
        try seedTrack(db, id: 10)
        try seedTrack(db, id: 20)
        try seedTrack(db, id: 30)
        let playlist = try db.createCustomPlaylist(name: "Copied", originApplePlaylistPersistentID: 999)

        try db.copyTracks([10, 20, 30], intoCustomPlaylistID: playlist.id!)

        let detail = try db.loadCustomPlaylistDetail(customPlaylistID: playlist.id!)
        XCTAssertEqual(detail?.tracks.map(\.track.persistentID), [10, 20, 30])
    }

    /// `upsertTrackMetadataIfNeeded` must never clobber a track that's
    /// already been through real analysis — it's meant only to satisfy the
    /// FK for a song this app has never seen before, not to reset one it
    /// has.
    func testUpsertTrackMetadataDoesNotOverwriteAnalyzedTrack() throws {
        let db = try DatabaseManager(path: nil)
        try db.dbQueue.write { conn in
            var track = Track(
                persistentID: 42, title: "Real Title", artist: "Real Artist", album: "Real Album",
                genre: "Real Genre", bpm: 120, musicalKey: "8A", energy: 0.5, brightness: 2000,
                durationSec: 200, playableStartSec: 0, playableDurationSec: 200
            )
            try track.insert(conn)
        }

        try db.upsertTrackMetadataIfNeeded(persistentID: 42, title: "Bare Title", artist: "Bare Artist", album: "Bare Album", genre: "Bare Genre", durationSec: 999)

        let fetched = try db.dbQueue.read { try Track.fetchOne($0, key: Int64(42)) }
        XCTAssertEqual(fetched?.title, "Real Title") // untouched, not overwritten with the bare metadata
        XCTAssertTrue(fetched?.isAnalyzed ?? false)
    }

    func testLoadCustomPlaylistDetailReturnsNilForMissingPlaylist() throws {
        let db = try DatabaseManager(path: nil)
        XCTAssertNil(try db.loadCustomPlaylistDetail(customPlaylistID: 999))
    }

    /// "Duplicate action" (2026-09-10): an independent standalone copy —
    /// same songs in order, a new name, **no** Apple origin even if the
    /// source had one, and the source left completely untouched.
    func testDuplicateCustomPlaylistMakesIndependentStandaloneCopy() throws {
        let db = try DatabaseManager(path: nil)
        try seedTrack(db, id: 10)
        try seedTrack(db, id: 20)
        try seedTrack(db, id: 30)
        let source = try db.createCustomPlaylist(name: "PangaMix", originApplePlaylistPersistentID: 12345)
        try db.copyTracks([10, 20, 30], intoCustomPlaylistID: source.id!)

        let copy = try XCTUnwrap(try db.duplicateCustomPlaylist(customPlaylistID: source.id!, newName: "PangaMix copy"))
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.name, "PangaMix copy")
        XCTAssertNil(copy.originApplePlaylistPersistentID) // a fresh branch, not tied to the Apple playlist

        let copyDetail = try db.loadCustomPlaylistDetail(customPlaylistID: copy.id!)
        XCTAssertEqual(copyDetail?.tracks.map(\.track.persistentID), [10, 20, 30])

        // Source unchanged.
        let sourceDetail = try db.loadCustomPlaylistDetail(customPlaylistID: source.id!)
        XCTAssertEqual(sourceDetail?.playlist.name, "PangaMix")
        XCTAssertEqual(sourceDetail?.tracks.map(\.track.persistentID), [10, 20, 30])
    }

    func testDuplicateCustomPlaylistReturnsNilForMissingSource() throws {
        let db = try DatabaseManager(path: nil)
        XCTAssertNil(try db.duplicateCustomPlaylist(customPlaylistID: 999, newName: "x"))
    }

    private func seedTrack(_ db: DatabaseManager, id: Int64) throws {
        try db.dbQueue.write { conn in
            var track = Track(persistentID: id, title: "Track \(id)", artist: "Artist", album: "Album", genre: "Genre", durationSec: 200)
            try track.insert(conn)
        }
    }
}
