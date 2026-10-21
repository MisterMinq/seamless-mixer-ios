import Foundation
import CryptoKit

/// Pure identity/naming logic for songs imported from outside the Music
/// library (Files, iCloud Drive, AirDrop...). Added 2026-10-21.
///
/// **Why a content hash.** Every other track in this app is keyed by Apple's
/// `MPMediaItem.persistentID`; an imported file has no such ID. The ID here is
/// the first 8 bytes of the SHA-256 of the file's *contents*, so:
/// - importing the very same file twice (even under a different name, or after
///   a delete/reinstall) yields the same ID, i.e. one track, not two;
/// - a saved mix "recipe" that names an imported song keeps working after the
///   file is re-imported, because the ID comes back identical;
/// - a changed file (different audio) gets a different ID.
/// A 64-bit prefix can in principle collide with an Apple persistentID, but
/// those are themselves effectively random 64-bit values, so the chance is
/// negligible at personal-library scale; `Track.importedFileName` (not the ID)
/// is what actually marks a row as imported.
///
/// Kept in `PlaylistCore` (no `MediaPlayer`/`AVFoundation`) so it is unit
/// tested in CI like `CrossfadeTiming` and `DuplicateFilter`.
public enum ImportedTrackIdentity {

    /// File extensions the importer accepts. These are the formats
    /// `AVAudioFile` (used by `TrackAnalyzer`) and `AVAudioPlayerNode`
    /// (used by playback) both read natively on iOS.
    public static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc", "flac", "caf"
    ]

    public static func isSupported(fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }

    /// Streams the file in 1 MB chunks (an album-length WAV can be hundreds of
    /// MB; never read it whole into memory just to hash it).
    public static func trackID(forFileAt url: URL) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return trackID(fromDigestBytes: Array(hasher.finalize()))
    }

    /// First 8 bytes of a digest, big-endian, bit-cast to `Int64`. Separate
    /// from the file-reading overload so the byte handling is testable with
    /// known values.
    public static func trackID(fromDigestBytes bytes: [UInt8]) -> Int64 {
        var value: UInt64 = 0
        for byte in bytes.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return Int64(bitPattern: value)
    }

    /// The name the app's own copy is stored under: the ID as 16 lowercase hex
    /// digits plus the original extension, e.g. `00a1b2c3d4e5f607.mp3`. Using
    /// the ID (not the original name) means two files with the same name never
    /// clash, and playback can find the file from the ID alone.
    public static func fileName(forTrackID trackID: Int64, fileExtension: String) -> String {
        "\(fileStem(forTrackID: trackID)).\(fileExtension.lowercased())"
    }

    /// The id as exactly 16 lowercase hex digits — the part of the stored
    /// file name that identifies the track, whatever its extension.
    public static func fileStem(forTrackID trackID: Int64) -> String {
        let hex = String(UInt64(bitPattern: trackID), radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    /// Inverse of `fileName(forTrackID:fileExtension:)`; nil if the name does
    /// not start with 16 hex digits.
    public static func trackID(fromFileName fileName: String) -> Int64? {
        let stem = (fileName as NSString).deletingPathExtension
        guard stem.count == 16, let value = UInt64(stem, radix: 16) else { return nil }
        return Int64(bitPattern: value)
    }

    /// Title to use when a file carries no title tag: the original file name
    /// without its extension.
    public static func fallbackTitle(fromOriginalFileName name: String) -> String {
        let stem = (name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "Unknown" : stem
    }
}
