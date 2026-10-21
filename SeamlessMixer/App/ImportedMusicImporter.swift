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

    private func importOne(_ url: URL, db: DatabaseManager) async -> Outcome {
        // Files picked through `.fileImporter` live outside the app's sandbox;
        // reading them needs this scope open for the whole function.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard ImportedTrackIdentity.isSupported(fileExtension: url.pathExtension) else {
            return .failed("unsupported file type")
        }

        let trackID: Int64
        do {
            trackID = try await Task.detached(priority: .userInitiated) {
                try ImportedTrackIdentity.trackID(forFileAt: url)
            }.value
        } catch {
            return .failed("couldn't be read")
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

        var track = existing ?? Track(
            persistentID: trackID,
            title: tags.title ?? ImportedTrackIdentity.fallbackTitle(fromOriginalFileName: url.lastPathComponent),
            artist: tags.artist ?? "Unknown",
            album: tags.album ?? "Unknown",
            genre: tags.genre ?? "Unknown",
            durationSec: duration
        )
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
