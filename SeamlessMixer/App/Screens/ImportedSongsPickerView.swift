import SwiftUI
import UniformTypeIdentifiers
import PlaylistCore

/// The "Imported songs" category picker — the sixth Source Selection row,
/// added 2026-10-21 for importing music from outside the Music library
/// (MP3/M4A/WAV/AIFF/FLAC from Files, iCloud Drive, AirDrop...).
///
/// This is both the place to *pick* imported songs for a mix (same checkbox
/// list as the Songs picker, selections flow into the Hub's chip row) and the
/// only place to *import* new ones and *remove* existing ones — per Rule 8,
/// anything you can add you can also take away: swipe a row to remove it,
/// with a confirmation that says how many saved mixes it will also disappear
/// from.
///
/// v1 shows a placeholder tile instead of cover art (embedded cover images
/// are a later add-on). Imported songs aren't part of the Music library, so
/// the Hub disables this row while "Use your whole library" is on.
struct ImportedSongsPickerView: View {
    @ObservedObject var viewModel: SourceSelectionViewModel
    let store: PlaylistStore

    @StateObject private var importer = ImportedMusicImporter()
    @State private var tracks: [Track] = []
    @State private var searchText = ""
    @State private var showImporter = false
    /// What the single `.fileImporter` below is currently for — individual
    /// audio files, or a folder to search for missing songs. One importer with
    /// a mode, not two `.fileImporter`s: stacking several on one view is a
    /// known SwiftUI gotcha (only one reliably presents).
    private enum ImportMode { case files, folder }
    @State private var importMode: ImportMode = .files
    /// Songs the backup record says were imported once but aren't in the app
    /// now (added 2026-10-21, imported-songs backup record).
    @State private var missing: [ImportedSongRecord] = []
    @State private var pendingRemoval: Track?
    @State private var pendingRemovalMixCount = 0
    @State private var errorMessage: String?

    private var filteredTracks: [Track] {
        guard !searchText.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) || $0.artist.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            InlineSearchField(text: $searchText, prompt: "Search imported songs")
            if tracks.isEmpty && missing.isEmpty {
                Spacer()
                VStack(spacing: DesignTokens.Spacing.md) {
                    Text("No imported songs yet.\nAdd MP3, M4A, WAV, AIFF or FLAC files from the Files app, iCloud Drive or AirDrop — they'll be mixed and blended just like songs from your Music library.")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .multilineTextAlignment(.center)
                    Button {
                        importMode = .files
                        showImporter = true
                    } label: {
                        Label("Import songs", systemImage: "square.and.arrow.down")
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, DesignTokens.Spacing.lg)
                            .frame(minHeight: DesignTokens.Size.buttonHeightStandard)
                            .background(DesignTokens.Color.primary)
                            .foregroundStyle(DesignTokens.Color.onPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium))
                    }
                    .buttonStyle(.plain)
                }
                .padding(DesignTokens.Spacing.lg)
                Spacer()
            } else {
                List {
                    if !missing.isEmpty {
                        missingSection
                    }
                    ForEach(filteredTracks) { track in
                        row(for: track)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    askToRemove(track)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                    Section {
                        Text("Swipe a song left to remove it from the app. Imported songs are copies kept inside the app; your original files are untouched.")
                            .font(.caption)
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                        if AppSettings.importedSongsNeedBackup(importedSongCount: tracks.count) {
                            Text("You've imported songs since your last backup. Settings → \u{201c}Back up my mixes\u{201d} saves a record of them outside the app, so after deleting and reinstalling you can bring them back with one folder pick instead of re-choosing each song.")
                                .font(.caption)
                                .foregroundStyle(DesignTokens.Color.warning)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(DesignTokens.Color.background)
        .navigationTitle("Imported songs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    importMode = .files
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(importer.isImporting)
                .accessibilityLabel("Import songs")
            }
        }
        .overlay {
            if importer.isImporting {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: DesignTokens.Spacing.sm) {
                        ProgressView()
                        Text(importer.progressText)
                            .font(.footnote)
                        Text("Keep the app open while songs are analysed.")
                            .font(.caption)
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                    }
                    .padding(DesignTokens.Spacing.lg)
                    .background(DesignTokens.Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium))
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: importMode == .folder ? [.folder] : [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    if importMode == .folder {
                        await importer.reimportMissing(fromFolders: urls, missing: missing, store: store)
                    } else {
                        await importer.importFiles(urls, store: store)
                    }
                    reload()
                }
            case .failure(let error):
                importer.summaryMessage = "Couldn't open the file picker: \(error.localizedDescription)"
            }
        }
        .alert("Import", isPresented: Binding(
            get: { importer.summaryMessage != nil },
            set: { if !$0 { importer.summaryMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importer.summaryMessage ?? "")
        }
        .confirmationDialog(
            pendingRemoval.map { "Remove “\($0.title)” from the app?" } ?? "Remove song?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let track = pendingRemoval { remove(track) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(pendingRemovalMixCount > 0
                 ? "It will also be taken out of \(pendingRemovalMixCount) saved mix\(pendingRemovalMixCount == 1 ? "" : "es") that use it. Your original file isn't touched."
                 : "Your original file isn't touched.")
        }
        .alert("Couldn't remove song", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: reload)
    }

    /// "Missing from this phone" — songs the restored backup says were
    /// imported once but aren't in the app. One button re-imports whichever of
    /// them it finds in a folder the user picks; a swipe forgets one the user
    /// no longer wants back (Rule 8).
    private var missingSection: some View {
        Section {
            Text("These songs were imported before your backup but aren't on this phone. Pick the folder you originally imported them from — Seamless DJ finds just these songs in it and re-imports them (everything else in the folder is ignored).")
                .font(.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
            Button {
                importMode = .folder
                showImporter = true
            } label: {
                Label("Re-import from folder…", systemImage: "folder")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.primaryText)
            }
            .disabled(importer.isImporting)
            ForEach(missing.prefix(40)) { record in
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(record.title)
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                        .lineLimit(1)
                    Text(record.artist)
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .lineLimit(1)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        ImportedSongsRecordStore.remove(trackID: record.trackID)
                        reload()
                    } label: {
                        Label("Forget", systemImage: "xmark.bin")
                    }
                }
            }
            if missing.count > 40 {
                Text("…and \(missing.count - 40) more")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
        } header: {
            Text("Missing from this phone (\(missing.count))")
        }
    }

    private func row(for track: Track) -> some View {
        let source = selectedSource(for: track)
        let selected = viewModel.isSelected(source)
        return Button {
            viewModel.toggle(source)
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? DesignTokens.Color.primary : DesignTokens.Color.textDisabled)

                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusSmall)
                        .fill(DesignTokens.Color.surfaceTint)
                    Image(systemName: "square.and.arrow.down")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.primaryText)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(track.title)
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(durationText(track.durationSec))
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Same id format `MixBuilder.selectedSource(from:)` rebuilds on Refresh
    /// (`"<rawValue>:<persistentID>"`), so a restored selection compares equal.
    private func selectedSource(for track: Track) -> SelectedSource {
        let persistentID = UInt64(bitPattern: track.persistentID)
        return SelectedSource(
            id: "\(SourceType.importedSong.rawValue):\(persistentID)", type: .importedSong,
            label: track.title, persistentID: persistentID
        )
    }

    private func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func reload() {
        tracks = (try? store.db?.loadImportedTracks()) ?? []
        missing = ImportedSongsRecordStore.missing(db: store.db)
        viewModel.refreshImportedSongsCount()
    }

    private func askToRemove(_ track: Track) {
        pendingRemovalMixCount = (try? store.db?.mixCount(usingTrackID: track.persistentID)) ?? 0
        pendingRemoval = track
    }

    private func remove(_ track: Track) {
        guard let db = store.db else { return }
        // If it's ticked for the mix being assembled, untick it first so the
        // Hub's chip row doesn't keep pointing at a song that's gone.
        let source = selectedSource(for: track)
        if viewModel.isSelected(source) { viewModel.toggle(source) }
        do {
            if let fileName = try db.deleteImportedTrack(trackID: track.persistentID) {
                ImportedMusicStore.removeFile(named: fileName)
            }
            // Removed on purpose — don't let a stale backup record bring it
            // back as "missing".
            ImportedSongsRecordStore.remove(trackID: track.persistentID)
            store.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }
}
