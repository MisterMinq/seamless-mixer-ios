import Foundation
import PlaylistCore

/// A portable "recipe" for rebuilding one Seamless Mix from scratch —
/// deliberately **not** the actual track list, crossfade timings, or
/// artwork, all of which get recomputed fresh on rebuild (exactly what
/// "Refresh" already does for an existing mix, per `MixBuilder
/// .performRefresh`) — just enough to re-run Build Mix: which sources it
/// combined, what mode, and how much extra crossfade.
///
/// **Built per Andy's direct request, 2026-09-28.** Deleting and
/// reinstalling the app wipes the local database entirely, and until now
/// there was no way to get a hand-picked mix back except remembering
/// exactly what was selected and rebuilding it by hand through Source
/// Selection — "the rigorous method of trying to recollect what I chose."
/// `makeFile` writes every current mix's recipe to one JSON file, handed to
/// the system share sheet so the user picks where it lives (Files, iCloud
/// Drive, email, AirDrop) — always outside this app's own sandbox, so it
/// survives a delete + reinstall. `restore` reads that file back and
/// rebuilds each mix automatically through the exact same `MixBuilder.build`
/// pipeline a normal Build Mix already uses.
///
/// **Scope, per Andy's own confirmation: Seamless Mixes only.** The
/// separate native "Add to Playlist" lists (`custom_playlists` — real song
/// lists, not recipes) aren't covered by this — a genuinely different
/// export shape (the actual song list, not a rebuildable recipe) that
/// would need its own pass if wanted later.
struct MixRecipe: Codable {
    var name: String
    var mode: String
    var extraCrossfadeSec: Double
    var sources: [SourceRecipe]

    struct SourceRecipe: Codable {
        var sourceType: String
        var sourceValue: String
        var sourceLabel: String
        var isExclusion: Bool
    }
}

private struct MixBackupFile: Codable {
    var exportedAt: Date
    var mixes: [MixRecipe]
}

enum MixBackup {
    enum BackupError: Error, LocalizedError {
        case noMixesToExport
        case writeFailed
        case readFailed
        case emptyFile

        var errorDescription: String? {
            switch self {
            case .noMixesToExport: return "There are no Seamless Mixes to back up yet."
            case .writeFailed: return "Couldn't write the backup file."
            case .readFailed: return "Couldn't read that backup file — make sure it's a Seamless DJ mix backup."
            case .emptyFile: return "That backup file doesn't contain any mixes."
            }
        }
    }

    /// Results of a restore pass, so the caller can show the user exactly
    /// what happened — a mix that couldn't be rebuilt (e.g. a source that
    /// no longer resolves to anything in the current library) is reported,
    /// not silently dropped, and doesn't stop the rest of the restore.
    struct RestoreSummary {
        var succeeded: [String]
        var failed: [(name: String, reason: String)]

        var summaryText: String {
            var lines = ["Restored \(succeeded.count) of \(succeeded.count + failed.count) mixes."]
            for failure in failed {
                lines.append("• \(failure.name): \(failure.reason)")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Builds the backup JSON from every current Seamless Mix and writes it
    /// to a temp file, ready to hand to the system share sheet. **Only the
    /// recipe is written** — track order/crossfade timings are never part
    /// of this file, since they're always recomputed fresh on rebuild.
    @MainActor
    static func makeFile(store: PlaylistStore) throws -> URL {
        guard let db = store.db else { throw BackupError.writeFailed }
        guard !store.playlists.isEmpty else { throw BackupError.noMixesToExport }

        var recipes: [MixRecipe] = []
        for playlist in store.playlists {
            guard let id = playlist.id else { continue }
            guard let detail = try? db.loadPlaylistDetail(playlistID: id) else { continue }
            guard !detail.sources.isEmpty else { continue }

            let sources = detail.sources.map { source in
                MixRecipe.SourceRecipe(
                    sourceType: source.sourceType.rawValue,
                    sourceValue: source.sourceValue,
                    sourceLabel: source.sourceLabel,
                    isExclusion: source.isExclusion
                )
            }
            recipes.append(MixRecipe(
                name: playlist.name, mode: playlist.mode.rawValue,
                extraCrossfadeSec: playlist.extraCrossfadeSec, sources: sources
            ))
        }
        guard !recipes.isEmpty else { throw BackupError.noMixesToExport }

        let file = MixBackupFile(exportedAt: Date(), mixes: recipes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { throw BackupError.writeFailed }

        let dateStamp = fileNameDateFormatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SeamlessDJ-Mixes-\(dateStamp).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw BackupError.writeFailed
        }
        return url
    }

    /// Reads a previously-exported backup file back into its recipes,
    /// without touching the database — `restore(recipes:...)` below is
    /// what actually rebuilds anything. Wraps the read in the security-
    /// scoped-resource dance `.fileImporter` results require (the URL
    /// points outside this app's own sandbox).
    static func loadRecipes(from url: URL) throws -> [MixRecipe] {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw BackupError.readFailed }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(MixBackupFile.self, from: data) else { throw BackupError.readFailed }
        guard !file.mixes.isEmpty else { throw BackupError.emptyFile }
        return file.mixes
    }

    /// Rebuilds every recipe as a brand-new Seamless Mix, through the exact
    /// same `MixBuilder.build` pipeline a normal Build Mix already uses —
    /// resolves each recipe's sources against the *current* library,
    /// analyzes anything not already analyzed, sequences, and saves.
    ///
    /// **`keepAll: true`, deliberately** — a mix's original target-duration
    /// setting was never persisted anywhere (`MixBuilder.performRefresh`'s
    /// own doc comment already flags this same gap for Refresh), so there's
    /// no original length to restore. Including everything the sources
    /// resolve to, rather than silently guessing and trimming to some
    /// invented length, is the honest choice here.
    ///
    /// **Restoring always creates new mixes, never replaces/merges with
    /// existing ones** — importing the same backup twice produces two
    /// copies, the same way tapping Build Mix twice with identical sources
    /// would. Acceptable for the primary use case (restoring into an empty,
    /// freshly-reinstalled library), not de-duplicated in this first pass.
    ///
    /// After each successful build, renames the result to the recipe's
    /// original `name` — `MixBuilder.persist` would otherwise regenerate an
    /// auto-name from the sources, which may not match a mix the user had
    /// since renamed by hand.
    @MainActor
    static func restore(recipes: [MixRecipe], store: PlaylistStore, mixBuilder: MixBuilder) async -> RestoreSummary {
        var succeeded: [String] = []
        var failed: [(name: String, reason: String)] = []

        for recipe in recipes {
            let playlistSources = recipe.sources.map { s in
                PlaylistSource(
                    playlistID: 0, sourceType: SourceType(rawValue: s.sourceType) ?? .genre,
                    sourceValue: s.sourceValue, sourceLabel: s.sourceLabel, isExclusion: s.isExclusion
                )
            }
            let allSelectedSources = playlistSources.compactMap(mixBuilder.selectedSource(from:))
            guard !allSelectedSources.isEmpty else {
                failed.append((recipe.name, "None of this mix's sources could be found in your library anymore."))
                continue
            }

            let mode = PlaylistMode(rawValue: recipe.mode) ?? .energyWave
            let isWholeLibrary = allSelectedSources.contains { $0.type == .wholeLibrary }
            let sourcesToPass = isWholeLibrary ? allSelectedSources.filter(\.isExclusion) : allSelectedSources

            let playlist = await mixBuilder.build(
                selectedSources: sourcesToPass, mode: mode, targetSeconds: 30 * 60,
                keepAll: true, extraCrossfadeSec: recipe.extraCrossfadeSec,
                useWholeLibrary: isWholeLibrary, store: store
            )

            if let playlist, let id = playlist.id {
                store.rename(playlistID: id, to: recipe.name)
                succeeded.append(recipe.name)
            } else {
                failed.append((recipe.name, mixBuilder.buildError ?? "Couldn't be rebuilt."))
            }
        }

        return RestoreSummary(succeeded: succeeded, failed: failed)
    }

    private static let fileNameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}
