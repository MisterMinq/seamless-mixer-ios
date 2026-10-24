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
    /// **Added 2026-10-21 (imported-songs backup record).** Optional so a
    /// backup file written before this existed still decodes; see
    /// `ImportedSongRecord` for what this is for.
    var importedSongs: [ImportedSongRecord]?
    /// **Added 2026-10-22.** The Music-library songs marked as favourites
    /// (imported-song favourites ride in `importedSongs`). Optional so older
    /// backup files still decode.
    var favoriteSongs: [FavoriteSongRecord]?
}

/// What a backup file contains once read back — the mix recipes plus the
/// imported-songs record (empty for a file made before imported songs existed)
/// and the favourite songs (empty for a file made before 2026-10-22).
struct LoadedBackup {
    var mixes: [MixRecipe]
    var importedSongs: [ImportedSongRecord]
    var favoriteSongs: [FavoriteSongRecord] = []
}

/// Mix recipes that a restore held back because they use imported songs that
/// aren't in the app yet — remembered here so the app can build them **by
/// itself** the moment those songs are re-imported, instead of the user having
/// to run the restore a second time (2026-10-24, CLAUDE.md 0.26.40, Andy's
/// request: "an automated mechanism"). Like `ImportedSongsRecordStore`, this
/// lives inside the app's sandbox, so it is wiped with the app; the real backup
/// is still the file saved outside, and restoring it again refills this list.
///
/// A recipe is added when a restore finds it waiting, and removed once the mix
/// exists, the same-named mix is already there, or none of its sources can be
/// found any more (`MixBackup.restore(recipes:...)` keeps this in step).
enum PendingMixStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PendingMixRecipes.json")
    }

    static func load() -> [MixRecipe] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([MixRecipe].self, from: data)) ?? []
    }

    private static func save(_ recipes: [MixRecipe]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if recipes.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        } else if let data = try? JSONEncoder().encode(recipes) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Adds (or refreshes) a waiting recipe; one per mix name.
    static func add(_ recipe: MixRecipe) {
        save(load().filter { $0.name != recipe.name } + [recipe])
    }

    static func remove(name: String) {
        let all = load()
        guard all.contains(where: { $0.name == name }) else { return }
        save(all.filter { $0.name != name })
    }

    /// Gives up on every waiting mix (the user chose to stop waiting).
    static func clear() {
        save([])
    }
}

enum MixBackup {
    enum BackupError: Error, LocalizedError {
        case noMixesToExport
        case writeFailed
        case readFailed
        case emptyFile

        var errorDescription: String? {
            switch self {
            case .noMixesToExport: return "There are no Seamless Mixes or imported songs to back up yet."
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
        var skipped: [String]
        var failed: [(name: String, reason: String)]
        /// How many imported songs the backup recorded, and how many of those
        /// aren't in the app yet (**added 2026-10-21**).
        var recordedImportedSongs = 0
        var missingImportedSongs = 0
        /// Where the missing imported songs came from (`ImportSourceHint`
        /// notes, most songs first) — so the message can say which folder to
        /// pick. Empty when none of them has a note.
        var missingSourceFolders: [String] = []
        /// Favourite Music-library songs the backup listed, how many were
        /// marked again, and how many couldn't be found in the library.
        var recordedFavorites = 0
        var restoredFavorites = 0

        var summaryText: String {
            var lines: [String] = []
            let mixTotal = succeeded.count + skipped.count + failed.count
            if mixTotal > 0 {
                lines.append("Restored \(succeeded.count) of \(mixTotal) mixes.")
            }
            if recordedFavorites > 0 {
                var line = "Favourites: \(restoredFavorites) of \(recordedFavorites) song\(recordedFavorites == 1 ? "" : "s") marked again."
                if restoredFavorites < recordedFavorites {
                    line += " The rest weren't found in your library."
                }
                lines.append(line)
            }
            if !skipped.isEmpty {
                lines.append("\(skipped.count) already existed and were left as-is: \(skipped.joined(separator: ", "))")
            }
            for failure in failed {
                lines.append("• \(failure.name): \(failure.reason)")
            }
            if recordedImportedSongs > 0 {
                if missingImportedSongs > 0 {
                    var line = "\(recordedImportedSongs) imported song\(recordedImportedSongs == 1 ? "" : "s") recorded; \(missingImportedSongs) not in the app yet. On My Mixes tap Build Mix → Imported songs → \"Re-import from folder…\" and pick the folder you originally imported from"
                    if !missingSourceFolders.isEmpty {
                        line += " (\(missingSourceFolders.prefix(3).joined(separator: "; ")))"
                    }
                    line += ". Mixes that were waiting for these songs are rebuilt automatically once the songs are back."
                    lines.append(line)
                } else {
                    lines.append("All \(recordedImportedSongs) recorded imported song\(recordedImportedSongs == 1 ? " is" : "s are") in the app.")
                }
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

        // **Imported-songs record, added 2026-10-21** — see
        // `ImportedSongRecord`. Included even when there are no mixes yet.
        let importedRecords = ImportedSongsRecordStore.recordsForBackup(db: db)
        // **Favourites, added 2026-10-22** — which Music-library songs are
        // marked favourite is a choice only this app's database holds.
        let favoriteRecords = ((try? db.loadLibraryFavoriteTracks()) ?? []).map(FavoriteSongRecord.init(track:))
        guard !store.playlists.isEmpty || !importedRecords.isEmpty || !favoriteRecords.isEmpty else { throw BackupError.noMixesToExport }

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
        guard !recipes.isEmpty || !importedRecords.isEmpty || !favoriteRecords.isEmpty else { throw BackupError.noMixesToExport }

        let file = MixBackupFile(exportedAt: Date(), mixes: recipes, importedSongs: importedRecords, favoriteSongs: favoriteRecords)
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
        // Counts as "backed up" for the Settings reminder from the moment the
        // file exists (whether the user then saves it from the share sheet is
        // theirs to do — the app can't tell).
        AppSettings.lastBackupDate = Date()
        return url
    }

    /// Reads a previously-exported backup file back into its recipes,
    /// without touching the database — `restore(recipes:...)` below is
    /// what actually rebuilds anything. Wraps the read in the security-
    /// scoped-resource dance `.fileImporter` results require (the URL
    /// points outside this app's own sandbox).
    static func loadBackup(from url: URL) throws -> LoadedBackup {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw BackupError.readFailed }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(MixBackupFile.self, from: data) else { throw BackupError.readFailed }
        let importedSongs = file.importedSongs ?? []
        let favoriteSongs = file.favoriteSongs ?? []
        guard !file.mixes.isEmpty || !importedSongs.isEmpty || !favoriteSongs.isEmpty else { throw BackupError.emptyFile }
        return LoadedBackup(mixes: file.mixes, importedSongs: importedSongs, favoriteSongs: favoriteSongs)
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
    /// **Skips a recipe outright if a mix with that exact name already
    /// exists** (added 2026-09-29, after a real accidental double-restore
    /// produced two full copies of every mix — see the loop's own comment
    /// below) — restoring never replaces or updates an existing mix, only
    /// fills in ones that are genuinely missing. A name match is an
    /// imperfect signal (two truly different recipes could coincidentally
    /// share a name), but simple and predictable, and directly closes the
    /// gap that mattered in practice.
    ///
    /// After each successful build, renames the result to the recipe's
    /// original `name` — `MixBuilder.persist` would otherwise regenerate an
    /// auto-name from the sources, which may not match a mix the user had
    /// since renamed by hand.
    @MainActor
    static func restore(backup: LoadedBackup, store: PlaylistStore, mixBuilder: MixBuilder) async -> RestoreSummary {
        // **Imported songs first (2026-10-21)** — remember what the backup says
        // was imported, so the Imported songs screen can list whatever isn't in
        // the app yet, and so the mix loop below can tell which recipes depend
        // on songs that still need re-importing.
        ImportedSongsRecordStore.merge(backup.importedSongs)

        // **Favourites (2026-10-22)** — mark them again before the mixes are
        // rebuilt. Each is found in the current library by id, then by
        // title + artist; ones that can't be found are counted, not guessed.
        var restoredFavorites = 0
        if !backup.favoriteSongs.isEmpty, let db = store.db {
            let resolution = FavoriteSongRecord.resolve(backup.favoriteSongs, in: MediaLibraryResolver.librarySongs())
            restoredFavorites = (try? db.applyLibraryFavorites(resolution.matches)) ?? 0
        }

        var summary = await restore(recipes: backup.mixes, store: store, mixBuilder: mixBuilder)
        summary.recordedFavorites = backup.favoriteSongs.count
        summary.restoredFavorites = restoredFavorites
        summary.recordedImportedSongs = backup.importedSongs.count
        let missingFromBackup = ImportedSongsRecordStore.missing(db: store.db)
            .filter { record in backup.importedSongs.contains { $0.trackID == record.trackID } }
        summary.missingImportedSongs = missingFromBackup.count
        summary.missingSourceFolders = ImportedSongRecord.sourceFolderCounts(of: missingFromBackup).map(\.folder)
        return summary
    }

    /// Builds the mixes a restore held back, if the songs they were waiting
    /// for are in the app by now. Called after every import (2026-10-24); a
    /// recipe whose songs are still missing simply stays on the waiting list.
    /// `nil` when nothing is waiting.
    @MainActor
    static func rebuildWaitingMixes(store: PlaylistStore, mixBuilder: MixBuilder) async -> RestoreSummary? {
        let waiting = PendingMixStore.load()
        guard !waiting.isEmpty else { return nil }
        return await restore(recipes: waiting, store: store, mixBuilder: mixBuilder)
    }

    /// Plain-language lines about the result of `rebuildWaitingMixes`, for the
    /// import alert. Empty when there is nothing worth saying.
    static func waitingMixesReport(_ summary: RestoreSummary) -> [String] {
        var lines: [String] = []
        if !summary.succeeded.isEmpty {
            lines.append("Rebuilt \(summary.succeeded.count) mix\(summary.succeeded.count == 1 ? "" : "es") that were waiting for these songs: \(summary.succeeded.joined(separator: ", ")).")
        }
        for failure in summary.failed {
            lines.append("• \(failure.name): \(failure.reason)")
        }
        return lines
    }

    @MainActor
    static func restore(recipes: [MixRecipe], store: PlaylistStore, mixBuilder: MixBuilder) async -> RestoreSummary {
        var succeeded: [String] = []
        var skipped: [String] = []
        var failed: [(name: String, reason: String)] = []

        for recipe in recipes {
            // **Added 2026-09-29** — real, direct duplicate protection, not
            // just the "acceptable trade-off" this function's own doc
            // comment used to describe. A missing progress indicator on
            // the Restore button (fixed separately in `SettingsView`) led
            // to a real accidental double-restore, producing two full
            // copies of every mix — this closes the gap for real, not just
            // the UI trigger that made it easy to hit. Matches by exact
            // name against whatever's already in `store.playlists`, which
            // `MixBuilder.build` keeps current via its own `store.refresh()`
            // call after each successful build in this same loop, so this
            // also catches duplicate names *within* one restore pass.
            if store.playlists.contains(where: { $0.name == recipe.name }) {
                skipped.append(recipe.name)
                PendingMixStore.remove(name: recipe.name) // nothing left to wait for
                continue
            }

            // **Waiting-for-imported-songs check, added 2026-10-21.** A recipe
            // that names imported songs can't be rebuilt faithfully until
            // those songs are back in the app: building it now would quietly
            // produce a mix without them (and a recipe made only of them
            // would fail outright). Leave it unbuilt, say why, and let a
            // second restore — after "Re-import from folder…" — fill it in
            // (restore never touches a mix that already exists).
            let neededImportedIDs: [Int64] = recipe.sources.compactMap { s in
                guard s.sourceType == SourceType.importedSong.rawValue, let raw = UInt64(s.sourceValue) else { return nil }
                return Int64(bitPattern: raw)
            }
            if !neededImportedIDs.isEmpty, let db = store.db {
                let presentIDs = Set(((try? db.importedTracks(withIDs: neededImportedIDs)) ?? []).map(\.persistentID))
                let missingCount = neededImportedIDs.filter { !presentIDs.contains($0) }.count
                if missingCount > 0 {
                    // Remember it (2026-10-24) — it is built automatically as
                    // soon as those songs are re-imported.
                    PendingMixStore.add(recipe)
                    failed.append((recipe.name, "Waiting for \(missingCount) imported song\(missingCount == 1 ? "" : "s") that aren't in the app yet — it will be built automatically once you re-import them."))
                    continue
                }
            }

            let playlistSources = recipe.sources.map { s in
                PlaylistSource(
                    playlistID: 0, sourceType: SourceType(rawValue: s.sourceType) ?? .genre,
                    sourceValue: s.sourceValue, sourceLabel: s.sourceLabel, isExclusion: s.isExclusion
                )
            }
            let allSelectedSources = playlistSources.compactMap(mixBuilder.selectedSource(from:))
            guard !allSelectedSources.isEmpty else {
                PendingMixStore.remove(name: recipe.name) // can never be built
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
                PendingMixStore.remove(name: recipe.name)
                succeeded.append(recipe.name)
            } else {
                // A failed build keeps a waiting recipe waiting (it may have
                // been a passing problem); the reason is reported either way.
                failed.append((recipe.name, mixBuilder.buildError ?? "Couldn't be rebuilt."))
            }
        }

        return RestoreSummary(succeeded: succeeded, skipped: skipped, failed: failed)
    }

    private static let fileNameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}
