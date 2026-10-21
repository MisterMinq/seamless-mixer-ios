import Foundation
import AVFoundation
import PlaylistCore

/// Imports songs from outside the Music library (Files, iCloud Drive,
/// AirDrop...) into the app — added 2026-10-21 (CLAUDE.md 0.26.6/0.26.25).
///
/// For each picked file: hash its contents (the track id — see
/// `ImportedTrackIdentity`), copy it into the app's own storage
/// (`ImportedMusicStore`), read its tags, run the *same* `TrackAnalyzer` pass
/// every library song gets (bpm/key/energy/brightness/trim points), and save a
/// normal `tracks` row marked with `importedFileName`. From then on the song is
/// indistinguishable from an analysed library song to `Sequencer`/
/// `CrossfadeTiming` — the analysis happens here, at import, rather than in a
/// background scan, because an import is a handful of files the user just
/// picked, not a library of thousands.
///
/// Importing the same file twice (even renamed) is detected by its content
/// hash and skipped; a file that can't be decoded is removed again and
/// reported, never left half-imported.
@MainActor
final class ImportedMusicImporter: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var progressText = ""
    /// Set when an import finishes; the picker shows it in an alert.
    @Published var summaryMessage: String?

    private enum Outcome {
        case imported
        case alreadyImported
        case failed(String)
    }

    func importFiles(_ urls: [URL], store: PlaylistStore) async {
        guard !isImporting, !urls.isEmpty else { return }
        guard let db = store.db else {
            summaryMessage = "Couldn't open the library database."
            return
        }
        isImporting = true
        defer { isImporting = false; progressText = "" }

        var importedCount = 0
        var alreadyCount = 0
        var failures: [String] = []

        for (index, url) in urls.enumerated() {
            progressText = "Importing \(index + 1) of \(urls.count)…"
            switch await importOne(url, db: db) {
            case .imported: importedCount += 1
            case .alreadyImported: alreadyCount += 1
            case .failed(let reason): failures.append("\(url.lastPathComponent) — \(reason)")
            }
        }

        var lines: [String] = []
        if importedCount > 0 { lines.append("Imported \(importedCount) song\(importedCount == 1 ? "" : "s").") }
        if alreadyCount > 0 { lines.append("\(alreadyCount) already imported, skipped.") }
        if !failures.isEmpty {
            lines.append("Couldn't import \(failures.count):")
            lines.append(contentsOf: failures.prefix(8))
            if failures.count > 8 { lines.append("…and \(failures.count - 8) more.") }
        }
        summaryMessage = lines.joined(separator: "\n")
        store.refresh()
    }

    /// **Re-import from folder, added 2026-10-21 (imported-songs backup
    /// record).** After a delete + reinstall + restore, `missing` lists the
    /// songs the backup says were imported once. Walks the chosen folder(s)
    /// (recursively), and for each audio file computes the same content hash
    /// an import would, importing only those whose hash is one of the missing
    /// songs — everything else in the folder is ignored, so pointing at a big
    /// music folder is fine. Before hashing (which reads the whole file), a
    /// file whose size matches none of the missing songs is skipped unread.
    /// A re-imported song takes its title/artist/etc. from the record (what
    /// the user saw before), and gets its favourite flag back.
    func reimportMissing(fromFolders folders: [URL], missing: [ImportedSongRecord], store: PlaylistStore) async {
        guard !isImporting, !folders.isEmpty, !missing.isEmpty else { return }
        guard let db = store.db else {
            summaryMessage = "Couldn't open the library database."
            return
        }
        isImporting = true
        defer { isImporting = false; progressText = "" }

        let wanted = Dictionary(missing.map { ($0.trackID, $0) }, uniquingKeysWith: { first, _ in first })
        let sizes = ImportedSongRecord.candidateSizes(for: missing)
        var restoredIDs = Set<Int64>()
        var failures: [String] = []
        var filesChecked = 0

        for folder in folders {
            // Files inside a picked folder are readable only while the
            // folder's own security scope is open.
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

            progressText = "Looking through “\(folder.lastPathComponent)”…"
            let candidates: [URL] = await Task.detached(priority: .userInitiated) {
                ImportedMusicImporter.audioFiles(in: folder, matchingSizes: sizes)
            }.value

            for (index, url) in candidates.enumerated() {
                if restoredIDs.count == wanted.count { break }
                progressText = "Checking \(index + 1) of \(candidates.count) in “\(folder.lastPathComponent)”…"
                filesChecked += 1
                guard let id = try? await Task.detached(priority: .userInitiated, operation: {
                    try ImportedTrackIdentity.trackID(forFileAt: url)
                }).value else { continue }
                guard let record = wanted[id], !restoredIDs.contains(id) else { continue }

                switch await importOne(url, db: db, record: record) {
                case .imported, .alreadyImported:
                    restoredIDs.insert(id)
                case .failed(let reason):
                    failures.append("\(record.title) — \(reason)")
                }
            }
            if restoredIDs.count == wanted.count { break }
        }

        var lines: [String] = []
        lines.append("Restored \(restoredIDs.count) of \(wanted.count) missing song\(wanted.count == 1 ? "" : "s").")
        let stillMissing = wanted.count - restoredIDs.count
        if stillMissing > 0 {
            lines.append("\(stillMissing) not found in the folder you chose (checked \(filesChecked) audio file\(filesChecked == 1 ? "" : "s")). Try another folder, or a song may be in iCloud Drive and not downloaded yet.")
        }
        if !failures.isEmpty {
            lines.append("Couldn't import:")
            lines.append(contentsOf: failures.prefix(8))
        }
        if restoredIDs.count > 0 {
            lines.append("Any mixes that were waiting for these songs can now be rebuilt: Settings → Restore mixes from backup.")
        }
        summaryMessage = lines.joined(separator: "\n")
        store.refresh()
    }

    /// Every supported audio file under `folder` (recursively, hidden files
    /// skipped), optionally narrowed to files whose size is in `sizes`.
    /// Synchronous and `nonisolated` so it can run off the main actor.
    nonisolated private static func audioFiles(in folder: URL, matchingSizes sizes: Set<Int64>?) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard ImportedTrackIdentity.isSupported(fileExtension: url.pathExtension) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            if let sizes {
                guard let size = values.fileSize, sizes.contains(Int64(size)) else { continue }
            }
            result.append(url)
        }
        return result
    }

    /// - Parameter record: set only when re-importing a song the backup
    ///   recorded; its description is used instead of the file's own tags.
    private func importOne(_ url: URL, db: DatabaseManager, record: ImportedSongRecord? = nil) async -> Outcome {
        // Files picked through `.fileImporter` live outside the app's sandbox;
        // reading them needs this scope open for the whole function.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard ImportedTrackIdentity.isSupported(fileExtension: url.pathExtension) else {
            return .failed("unsupported file type")
        }

        let trackID: Int64
        if let record {
            trackID = record.trackID
        } else {
            do {
                trackID = try await Task.detached(priority: .userInitiated) {
                    try ImportedTrackIdentity.trackID(forFileAt: url)
                }.value
            } catch {
                return .failed("couldn't be read")
            }
        }

        let existing: Track? = try? await db.dbQueue.read { conn in
            try Track.fetchOne(conn, key: trackID)
        }
        if let existing {
            guard existing.importedFileName != nil else {
                // Astronomically unlikely id clash with a Music-library track.
                return .failed("couldn't be given a unique id")
            }
            if existing.isAnalyzed, ImportedMusicStore.url(forTrackID: trackID) != nil {
                return .alreadyImported
            }
        }

        let storedName: String
        do {
            storedName = try await Task.detached(priority: .userInitiated) {
                try ImportedMusicStore.copyIn(from: url, trackID: trackID)
            }.value
        } catch {
            return .failed("couldn't be copied into the app")
        }
        let storedURL = ImportedMusicStore.directory.appendingPathComponent(storedName)

        let features: AnalysisFeatures
        do {
            features = try await Task.detached(priority: .userInitiated) {
                try TrackAnalyzer.analyze(fileAt: storedURL)
            }.value
        } catch TrackAnalyzer.AnalysisError.tooShort {
            ImportedMusicStore.removeFile(named: storedName)
            return .failed("too short (under 3 seconds)")
        } catch {
            ImportedMusicStore.removeFile(named: storedName)
            return .failed("couldn't be decoded")
        }

        let tags = await Self.readTags(from: storedURL)
        var duration = (try? TrackAnalyzer.duration(ofFileAt: storedURL)) ?? 0
        if !duration.isFinite || duration <= 0 {
            duration = features.playableDurationSec
        }

        var track: Track
        if let existing {
            track = existing
        } else if let record {
            // Re-importing a song the backup recorded: keep exactly what the
            // user saw before (and its favourite flag), not whatever the
            // file's tags happen to say.
            track = Track(
                persistentID: trackID, title: record.title, artist: record.artist, album: record.album,
                genre: record.genre, durationSec: duration, isFavorite: record.isFavorite
            )
        } else {
            track = Track(
                persistentID: trackID,
                title: tags.title ?? ImportedTrackIdentity.fallbackTitle(fromOriginalFileName: url.lastPathComponent),
                artist: tags.artist ?? "Unknown",
                album: tags.album ?? "Unknown",
                genre: tags.genre ?? "Unknown",
                durationSec: duration
            )
        }
        track.durationSec = duration
        track.hasRawAudioAccess = true
        track.importedFileName = storedName
        track.bpm = features.bpm
        track.musicalKey = features.camelotCode
        track.energy = features.energy
        track.brightness = features.brightness
        track.playableStartSec = features.playableStartSec
        track.playableDurationSec = features.playableDurationSec
        track.analyzedAt = Date()

        let finalTrack = track
        do {
            try await db.dbQueue.write { conn in
                try finalTrack.save(conn)
            }
        } catch {
            ImportedMusicStore.removeFile(named: storedName)
            return .failed("couldn't be saved")
        }
        // A record's own re-import isn't a *new* import as far as the backup
        // reminder goes — the backup already knows about this song.
        if record == nil {
            AppSettings.lastImportDate = Date()
        }
        return .imported
    }

    private struct Tags {
        var title: String?
        var artist: String?
        var album: String?
        var genre: String?
    }

    /// Reads the file's own title/artist/album/genre tags (ID3 for MP3, iTunes
    /// atoms for M4A, etc. — AVFoundation's "common" identifiers cover them).
    /// Any missing or empty tag stays `nil` and the caller falls back to the
    /// file name / "Unknown".
    private static func readTags(from url: URL) async -> Tags {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return Tags() }

        func value(_ identifier: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first else { return nil }
            guard let text = try? await item.load(.stringValue) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return Tags(
            title: await value(.commonIdentifierTitle),
            artist: await value(.commonIdentifierArtist),
            album: await value(.commonIdentifierAlbumName),
            genre: await value(.commonIdentifierType)
        )
    }
}
