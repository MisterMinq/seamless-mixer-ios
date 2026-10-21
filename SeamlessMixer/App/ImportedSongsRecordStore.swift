import Foundation
import PlaylistCore

/// The app's local copy of the imported-songs record, used for exactly one
/// thing: remembering songs that a backup says were imported once but are not
/// in the app right now (typically right after a delete + reinstall + restore),
/// so the Imported songs screen can list them under "Missing" and offer a
/// one-tap "Re-import from folder…". Added 2026-10-21 (CLAUDE.md 0.26.31).
///
/// This file is *not* the backup — it lives inside the app's sandbox and is
/// wiped with the app like everything else. The backup is the JSON file the
/// user saves outside the app via Settings → "Back up my mixes"; this store is
/// only where a restored backup's imported-song records land.
///
/// Stored in `Application Support/ImportedSongsRecord.json`, deliberately a
/// separate file from the `ImportedMusic/` folder of audio copies.
enum ImportedSongsRecordStore {

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ImportedSongsRecord.json")
    }

    static func load() -> [ImportedSongRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ImportedSongRecord].self, from: data)) ?? []
    }

    static func save(_ records: [ImportedSongRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Adds `incoming` to what's stored (union by song id, incoming wins).
    static func merge(_ incoming: [ImportedSongRecord]) {
        guard !incoming.isEmpty else { return }
        save(ImportedSongRecord.merged(existing: load(), incoming: incoming))
    }

    /// Forgets one song (the user removed it on purpose, or chose to stop
    /// waiting for it) so it stops showing up under "Missing".
    static func remove(trackID: Int64) {
        save(load().filter { $0.trackID != trackID })
    }

    /// The records for songs that aren't in the app right now.
    static func missing(db: DatabaseManager?) -> [ImportedSongRecord] {
        let stored = load()
        guard !stored.isEmpty else { return [] }
        let present: Set<Int64>
        if let db, let tracks = try? db.loadImportedTracks() {
            present = Set(tracks.map(\.persistentID))
        } else {
            present = []
        }
        return ImportedSongRecord.missing(from: stored, presentTrackIDs: present)
    }

    /// Records describing every imported song currently in the app (with the
    /// size of its stored copy), merged with whatever is still waiting in the
    /// store — so a backup made after a restore but *before* the songs were
    /// re-imported doesn't lose the ones still missing.
    static func recordsForBackup(db: DatabaseManager) -> [ImportedSongRecord] {
        let current: [ImportedSongRecord] = ((try? db.loadImportedTracks()) ?? []).map { track in
            var size: Int64?
            if let url = ImportedMusicStore.url(forTrackID: track.persistentID) {
                size = fileSize(at: url)
            }
            return ImportedSongRecord(track: track, fileSizeBytes: size)
        }
        return ImportedSongRecord.merged(existing: load(), incoming: current)
    }

    /// Size in bytes, or `nil` if it can't be read.
    static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return nil }
        return number.int64Value
    }
}
