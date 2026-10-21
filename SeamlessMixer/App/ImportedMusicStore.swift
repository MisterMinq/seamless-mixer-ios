import Foundation
import PlaylistCore

/// Where the app keeps its own copies of songs imported from outside the
/// Music library (Files, iCloud Drive, AirDrop...). Added 2026-10-21.
///
/// Files live in `Application Support/ImportedMusic/`, named by
/// `ImportedTrackIdentity.fileName(forTrackID:fileExtension:)` (the content-
/// hash id plus the original extension). Because the name *is* the id,
/// playback can find a track's file from its id alone, with no database
/// lookup — `url(forTrackID:)` is what `PlaybackEngine.resolveFileURL` calls
/// before it falls back to the Music-library lookup.
///
/// The folder is flagged "exclude from backup": these are copies the user
/// still has the originals of, and an iCloud backup shouldn't silently grow by
/// the size of an imported collection. Consequence (accepted by Andy): after
/// deleting and reinstalling the app, or restoring to a new phone, imported
/// songs are gone from the app and need importing again — their ids come back
/// identical (content hash), so saved mixes light up again as soon as the same
/// files are re-imported.
enum ImportedMusicStore {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ImportedMusic", isDirectory: true)
    }

    /// Creates the folder if needed and flags it as excluded from backup.
    /// Safe to call repeatedly.
    @discardableResult
    static func ensureDirectory() throws -> URL {
        var dir = directory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// The stored copy for a track id, found by scanning the (small) folder
    /// for a file whose name starts with that id — the extension is whatever
    /// the original file had, so it can't be computed from the id alone.
    static func url(forTrackID trackID: Int64) -> URL? {
        let stem = ImportedTrackIdentity.fileStem(forTrackID: trackID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        guard let match = names.first(where: { $0.hasPrefix(stem + ".") }) else { return nil }
        return directory.appendingPathComponent(match)
    }

    /// Copies `source` into the folder under its id-based name. If a copy
    /// already exists (same content imported before) it is reused. Returns the
    /// stored file name.
    static func copyIn(from source: URL, trackID: Int64) throws -> String {
        let dir = try ensureDirectory()
        let name = ImportedTrackIdentity.fileName(forTrackID: trackID, fileExtension: source.pathExtension)
        let destination = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDestination = destination
        try? mutableDestination.setResourceValues(values)
        return name
    }

    static func removeFile(named name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}
