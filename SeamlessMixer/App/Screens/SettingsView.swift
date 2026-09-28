import SwiftUI
import UniformTypeIdentifiers

/// First real slice of the Settings screen — deliberately deferred since
/// Phase 3 status, per CLAUDE.md ("first-run analysis/DRM-exclusion/Settings
/// screens stay deferred until the code that needs them... exists"), and My
/// Mixes' own gear icon has been a no-op since the screen was first built.
///
/// **Built 2026-08-15, narrowly scoped to one thing: showing which build is
/// currently installed.** Andy asked directly, mid-testing: "Is there any
/// way of knowing if I am testing the current build? Can we implement the
/// version e.g. V1.0.27 into the settings." A real, recurring friction point
/// across this whole real-device testing effort — every round has had to
/// establish "which build is this" from context (a Codemagic build number,
/// a timestamp) rather than the app just saying so. Reads
/// `CFBundleShortVersionString`/`CFBundleVersion` straight from
/// `Bundle.main` — the same two values `project.yml`'s `MARKETING_VERSION`/
/// `CURRENT_PROJECT_VERSION` (`$(BUILD_NUMBER)`) already write into the
/// generated Info.plist at build time (see CLAUDE.md's 0.18.11–0.18.14
/// versioning saga), so this is genuinely the same number Codemagic/
/// TestFlight assign, not a separately-maintained string that could drift.
/// Displayed as "V{short version}.{build}" (e.g. "V1.0.27"), matching the
/// exact format Andy used when asking for this.
///
/// **Extended 2026-08-20 with a "Library" section** — the real entry point
/// for `LibraryScanView` (the first-run/whole-library scan, per the
/// confirmed "First-Run Library Analysis — UX" design), reachable
/// explicitly rather than triggered automatically on first launch, which
/// stays separate, deferred work. Needed `store: PlaylistStore` threaded
/// in for the first time — the version-only slice never touched the
/// database, so this screen's `init` previously took no parameters at all.
///
/// **Extended 2026-09-10** with a "What's new" row → `ChangelogView`, a
/// per-build plain-language list of user-facing changes (backlog #63) — so
/// a tester can see which fixes landed in which build without digging
/// through chat.
///
/// **Extended 2026-09-28 with a "Backup" section** — export/import for
/// Seamless Mixes, per Andy's direct request: deleting and reinstalling the
/// app wipes the local database entirely, and there was no way to get a
/// hand-picked mix back except remembering exactly what was selected and
/// rebuilding it by hand. See `MixBackup`'s own doc comment for the full
/// design (only the "recipe" is saved, not the actual track list — the same
/// thing "Refresh" already recomputes for an existing mix). Native
/// "Add to Playlist" lists aren't covered, per Andy's own confirmed scope
/// ("Just Seamless Mixes for now").
///
/// Everything else a real Settings screen would eventually hold
/// (DRM-exclusion overrides) is still out of scope for this slice on
/// purpose.
struct SettingsView: View {
    @ObservedObject var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLibraryScan = false
    /// **Added 2026-09-05** — seeded from `AppSettings.includeDuplicateTracks`
    /// at init (a plain `UserDefaults`-backed value, not `@Published`, so a
    /// local `@State` mirror is what actually drives the `Toggle`), written
    /// back on every change. See `DuplicateFilter`'s own doc comment for why
    /// this exists — real duplicate library entries were clustering
    /// back-to-back in whole-library mixes.
    @State private var includeDuplicateTracks = AppSettings.includeDuplicateTracks

    /// **Added 2026-09-28** — backup/restore state. `mixBuilder` is this
    /// screen's own instance (not the app-wide `PlaybackEngine`-style
    /// singleton) since restoring only ever happens from here, one-shot,
    /// not something any other screen needs to observe.
    @StateObject private var mixBuilder = MixBuilder()
    @State private var exportedFile: ExportedFile?
    @State private var backupError: String?
    @State private var isRestoring = false
    @State private var showImporter = false
    @State private var restoreSummary: MixBackup.RestoreSummary?

    private struct ExportedFile: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    private var versionString: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "V\(shortVersion).\(build)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Version")
                            .foregroundStyle(DesignTokens.Color.textPrimary)
                        Spacer()
                        Text(versionString)
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                    }
                    NavigationLink {
                        ChangelogView()
                    } label: {
                        Text("What's new")
                            .foregroundStyle(DesignTokens.Color.textPrimary)
                    }
                } footer: {
                    Text("This is the exact build/version number shown in TestFlight — useful for confirming which build you're testing against.")
                }

                Section {
                    Button {
                        showLibraryScan = true
                    } label: {
                        HStack {
                            Text(LibraryScanner.hasCompletedAnyScan ? "Re-scan your library" : "Scan your library")
                                .foregroundStyle(DesignTokens.Color.textPrimary)
                            Spacer()
                            if LibraryScanner.hasCompletedAnyScan {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(DesignTokens.Color.success)
                            }
                        }
                    }
                } footer: {
                    Text("Analyzes every song's tempo, key, and energy so a \"Use your whole library\" mix can be built without a long wait. Only needs to run once — you can leave and come back to finish later.")
                }

                Section {
                    Toggle(isOn: $includeDuplicateTracks) {
                        Text("Include duplicate copies")
                            .foregroundStyle(DesignTokens.Color.textPrimary)
                    }
                    .tint(DesignTokens.Color.primary)
                    .onChange(of: includeDuplicateTracks) { _, newValue in
                        AppSettings.includeDuplicateTracks = newValue
                    }
                } footer: {
                    Text("Off by default: when the same song appears more than once in your library (title, artist, and length all matching), only one copy is used per mix, so it doesn't end up playing back-to-back. Turn this on to include every copy instead.")
                }

                Section {
                    Button {
                        do {
                            exportedFile = ExportedFile(url: try MixBackup.makeFile(store: store))
                        } catch {
                            backupError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    } label: {
                        Text("Back up my mixes")
                            .foregroundStyle(DesignTokens.Color.textPrimary)
                    }

                    Button {
                        // **Set the instant this is tapped, not partway
                        // through the async flow below — 2026-09-29 fix.**
                        // Andy tapped this a second time after seeing no
                        // visible progress indicator, before the file
                        // picker had even been dismissed, producing two
                        // full copies of every restored mix. The button's
                        // own `.disabled` now covers the entire window from
                        // this tap through the restore actually finishing,
                        // closing that gap outright rather than relying on
                        // the spinner alone to be noticed in time.
                        isRestoring = true
                        showImporter = true
                    } label: {
                        HStack {
                            Text(isRestoring ? "Restoring…" : "Restore mixes from backup")
                                .foregroundStyle(DesignTokens.Color.textPrimary)
                            if isRestoring {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRestoring)
                } footer: {
                    Text("Backs up which sources each Seamless Mix was built from, not the audio itself — so it survives deleting and reinstalling the app. Restoring rebuilds each mix fresh from your current library, the same way \"Refresh\" already does.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showLibraryScan) {
                LibraryScanView(store: store)
            }
            .sheet(item: $exportedFile) { file in
                ActivityShareSheet(items: [file.url])
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                // `isRestoring` was already set `true` the instant the
                // button was tapped (see that Button's own comment) — every
                // path out of this closure, including a cancelled picker,
                // must reset it back to `false`, or the button stays
                // permanently disabled until the app relaunches.
                switch result {
                case .success(let url):
                    Task {
                        do {
                            let recipes = try MixBackup.loadRecipes(from: url)
                            restoreSummary = await MixBackup.restore(recipes: recipes, store: store, mixBuilder: mixBuilder)
                        } catch {
                            backupError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                        isRestoring = false
                    }
                case .failure(let error):
                    // Also reached if the user just cancels the picker
                    // without choosing a file, not only on a real error.
                    let cancelled = (error as NSError).code == NSUserCancelledError
                    if !cancelled {
                        backupError = error.localizedDescription
                    }
                    isRestoring = false
                }
            }
            .alert("Couldn't do that", isPresented: Binding(get: { backupError != nil }, set: { if !$0 { backupError = nil } })) {
                Button("OK") { backupError = nil }
            } message: {
                Text(backupError ?? "")
            }
            .alert("Restore complete", isPresented: Binding(get: { restoreSummary != nil }, set: { if !$0 { restoreSummary = nil } })) {
                Button("OK") { restoreSummary = nil }
            } message: {
                Text(restoreSummary?.summaryText ?? "")
            }
        }
    }
}

#Preview {
    SettingsView(store: PlaylistStore())
}
