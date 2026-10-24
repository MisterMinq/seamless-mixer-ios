import Foundation

/// A small, portable description of one imported song — what goes into the
/// backup file (and into the app's "missing songs" list after a restore) so
/// that deleting and reinstalling the app doesn't mean re-picking every
/// imported song from memory. Added 2026-10-21 (CLAUDE.md 0.26.31), at
/// Andy's direct request: imported songs are hand-picked and effectively
/// random, so "redo the whole import from scratch" is not an acceptable
/// outcome of a reinstall.
///
/// The audio itself can't survive an app delete (iOS wipes the app's whole
/// sandbox, and an app can't silently write outside it) — the originals in
/// Files/iCloud Drive/the laptop remain the source. What this record makes
/// possible is cheap re-import: `trackID` is the content hash of the file
/// (`ImportedTrackIdentity`), so pointing the app at a folder and matching
/// files against the record restores the exact same songs with the exact same
/// ids — meaning saved mixes that name them light up again.
///
/// `fileSizeBytes` exists purely to make the folder re-import fast: hashing a
/// file means reading all of it, so before hashing, candidate files whose size
/// matches none of the missing songs are skipped without being read.
public struct ImportedSongRecord: Codable, Equatable, Hashable, Identifiable {
    public var trackID: Int64
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    public var durationSec: Double
    public var isFavorite: Bool
    /// Size of the stored copy in bytes (identical to the original file's
    /// size); `nil` if it couldn't be read when the record was made.
    public var fileSizeBytes: Int64?
    /// Where the song was imported from, as a readable note such as
    /// `On My iPhone › Music` (`ImportSourceHint`). `nil` for songs imported
    /// before this existed, or when the folder couldn't be worked out. Optional
    /// so a backup file written before 2026-10-24 still decodes. Added so that,
    /// after a restore, the app can tell the user which folder to pick.
    public var sourceFolder: String?

    public var id: Int64 { trackID }

    public init(
        trackID: Int64, title: String, artist: String, album: String, genre: String,
        durationSec: Double, isFavorite: Bool = false, fileSizeBytes: Int64? = nil,
        sourceFolder: String? = nil
    ) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.durationSec = durationSec
        self.isFavorite = isFavorite
        self.fileSizeBytes = fileSizeBytes
        self.sourceFolder = sourceFolder
    }

    public init(track: Track, fileSizeBytes: Int64?, sourceFolder: String? = nil) {
        self.init(
            trackID: track.persistentID, title: track.title, artist: track.artist, album: track.album,
            genre: track.genre, durationSec: track.durationSec, isFavorite: track.isFavorite,
            fileSizeBytes: fileSizeBytes, sourceFolder: sourceFolder
        )
    }

    /// One place songs came from, and how many of the given songs came from it.
    public struct SourceFolderCount: Equatable {
        public var folder: String
        public var count: Int
        public init(folder: String, count: Int) {
            self.folder = folder
            self.count = count
        }
    }

    /// The distinct source folders among `records`, most songs first (ties
    /// alphabetical). Songs with no known folder are left out; the result is
    /// empty when none of them has one.
    public static func sourceFolderCounts(of records: [ImportedSongRecord]) -> [SourceFolderCount] {
        var counts: [String: Int] = [:]
        for record in records {
            guard let folder = record.sourceFolder, !folder.isEmpty else { continue }
            counts[folder, default: 0] += 1
        }
        return counts
            .map { SourceFolderCount(folder: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.folder < $1.folder }
    }

    /// The records whose song is not currently in the app, alphabetical by
    /// title (then artist) so the "missing" list reads in a stable order.
    public static func missing(from records: [ImportedSongRecord], presentTrackIDs: Set<Int64>) -> [ImportedSongRecord] {
        records
            .filter { !presentTrackIDs.contains($0.trackID) }
            .sorted {
                let byTitle = $0.title.localizedCaseInsensitiveCompare($1.title)
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
            }
    }

    /// Union by `trackID`; where both sides have the same song, `incoming`
    /// wins (it is the fresher description) — except that a known
    /// `sourceFolder` is never lost: if `incoming` doesn't know where the song
    /// came from but `existing` does, the existing note is kept (a record
    /// rebuilt from the database knows nothing about the original folder).
    /// Order: `existing`'s order first, then genuinely new ids in `incoming`'s
    /// order.
    public static func merged(existing: [ImportedSongRecord], incoming: [ImportedSongRecord]) -> [ImportedSongRecord] {
        let incomingByID = Dictionary(incoming.map { ($0.trackID, $0) }, uniquingKeysWith: { _, last in last })
        var result: [ImportedSongRecord] = []
        var seen = Set<Int64>()
        for record in existing where seen.insert(record.trackID).inserted {
            guard var fresher = incomingByID[record.trackID] else {
                result.append(record)
                continue
            }
            if fresher.sourceFolder == nil { fresher.sourceFolder = record.sourceFolder }
            result.append(fresher)
        }
        for record in incoming where seen.insert(record.trackID).inserted {
            result.append(incomingByID[record.trackID] ?? record)
        }
        return result
    }

    /// The set of file sizes worth hashing during a folder re-import, or `nil`
    /// when no useful filter exists (any record without a known size means a
    /// file of any size might be the one — so nothing can be skipped safely).
    public static func candidateSizes(for records: [ImportedSongRecord]) -> Set<Int64>? {
        guard !records.isEmpty else { return nil }
        var sizes = Set<Int64>()
        for record in records {
            guard let size = record.fileSizeBytes else { return nil }
            sizes.insert(size)
        }
        return sizes
    }
}
