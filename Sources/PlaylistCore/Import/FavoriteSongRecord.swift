import Foundation
import GRDB

/// One favourite Music-library song, as written into the backup file.
/// Added 2026-10-22 (CLAUDE.md 0.26.35) after Andy deleted the app to test
/// imports and lost the ~7 songs he had marked as favourites: the favourite
/// flag lives only in the app's own database (`tracks.is_favorite`), and the
/// backup carried mix recipes and imported-song records but nothing for a
/// Music-library favourite. The choice Andy made — which songs — is the thing
/// worth keeping, even though the songs themselves are still in his library.
///
/// (Favourite *imported* songs are not covered here: their flag already rides
/// along in `ImportedSongRecord.isFavorite`.)
///
/// `trackID` is Apple's persistent id for the song, which stays the same on the
/// same phone and library. Title and artist are kept as a fallback so a favourite
/// can still be found if the library was re-synced and the ids changed.
public struct FavoriteSongRecord: Codable, Equatable, Hashable, Identifiable {
    public var trackID: Int64
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    public var durationSec: Double

    public var id: Int64 { trackID }

    public init(trackID: Int64, title: String, artist: String, album: String, genre: String, durationSec: Double) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.durationSec = durationSec
    }

    public init(track: Track) {
        self.init(
            trackID: track.persistentID, title: track.title, artist: track.artist,
            album: track.album, genre: track.genre, durationSec: track.durationSec
        )
    }

    /// Just enough about one song in the current library to match a record to it.
    public struct LibrarySong: Equatable {
        public var id: Int64
        public var title: String
        public var artist: String

        public init(id: Int64, title: String, artist: String) {
            self.id = id
            self.title = title
            self.artist = artist
        }
    }

    public struct Match: Equatable {
        public var record: FavoriteSongRecord
        /// The id of the song in the *current* library (equals `record.trackID`
        /// when the id still exists).
        public var libraryID: Int64
    }

    public struct Resolution: Equatable {
        public var matches: [Match]
        public var unmatched: [FavoriteSongRecord]
    }

    /// Finds each recorded favourite in the current library. The id is tried
    /// first; failing that, title + artist (ignoring case and extra spaces) is
    /// used, but only when exactly one library song has that title and artist —
    /// two candidates means a guess, and a wrong favourite is worse than a
    /// missing one.
    public static func resolve(_ records: [FavoriteSongRecord], in library: [LibrarySong]) -> Resolution {
        let ids = Set(library.map(\.id))
        var byName: [String: [Int64]] = [:]
        for song in library {
            byName[nameKey(title: song.title, artist: song.artist), default: []].append(song.id)
        }

        var matches: [Match] = []
        var unmatched: [FavoriteSongRecord] = []
        var used = Set<Int64>()
        for record in records {
            if ids.contains(record.trackID) {
                if used.insert(record.trackID).inserted { matches.append(Match(record: record, libraryID: record.trackID)) }
                continue
            }
            if let candidates = byName[nameKey(title: record.title, artist: record.artist)], candidates.count == 1 {
                let libraryID = candidates[0]
                if used.insert(libraryID).inserted { matches.append(Match(record: record, libraryID: libraryID)) }
                continue
            }
            unmatched.append(record)
        }
        return Resolution(matches: matches, unmatched: unmatched)
    }

    static func nameKey(title: String, artist: String) -> String {
        func clean(_ s: String) -> String {
            s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return clean(title) + "|" + clean(artist)
    }
}

extension DatabaseManager {

    /// Every favourite song from the Music library (not imported songs), by title.
    public func loadLibraryFavoriteTracks() throws -> [Track] {
        try dbQueue.read { conn in
            try Track.fetchAll(
                conn,
                sql: "SELECT * FROM tracks WHERE is_favorite = 1 AND imported_file_name IS NULL ORDER BY title COLLATE NOCASE"
            )
        }
    }

    /// Marks the matched songs as favourites again after a restore. A song the
    /// app has no row for yet (a fresh install knows nothing until it scans or
    /// builds) gets a bare, unanalysed row first — the same thing
    /// `upsertTrackMetadataIfNeeded` does — which never overwrites a row that
    /// already has analysis data. Only ever turns the flag on.
    ///
    /// - Returns: how many songs were marked.
    @discardableResult
    public func applyLibraryFavorites(_ matches: [FavoriteSongRecord.Match]) throws -> Int {
        guard !matches.isEmpty else { return 0 }
        return try dbQueue.write { conn in
            for match in matches {
                let record = match.record
                let bare = Track(
                    persistentID: match.libraryID, title: record.title, artist: record.artist,
                    album: record.album, genre: record.genre, durationSec: record.durationSec
                )
                try bare.insert(conn, onConflict: .ignore)
                try conn.execute(sql: "UPDATE tracks SET is_favorite = 1 WHERE persistent_id = ?", arguments: [match.libraryID])
            }
            return matches.count
        }
    }
}
