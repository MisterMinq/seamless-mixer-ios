import Foundation
import MediaPlayer
import PlaylistCore

/// Drives the confirmed "First-Run Library Analysis" UX (CLAUDE.md) for
/// real, for the first time.
///
/// **This is slice 1 — foreground-only, not the full confirmed design.**
/// The full design calls for `BGContinuedProcessingTask` (iOS 26+) with a
/// `BGProcessingTask` background fallback, so a scan survives the app
/// backgrounding or the phone locking. That's real, separate follow-up
/// work — `ios/SeamlessMixer/project.yml`'s deployment target is iOS 18.0,
/// not 26, so `BGContinuedProcessingTask` specifically would need an
/// `if #available` gate rather than being usable outright, on top of the
/// background-mode Info.plist entry and task-identifier registration
/// neither of which exist yet. This slice only runs while `LibraryScanView`
/// is on screen and the app is in the foreground — leaving the screen or
/// backgrounding the app stops the scan, and the UI says so honestly
/// rather than claiming the "close the app, keep going" capability the
/// confirmed design describes. Resuming this screen later picks up where
/// it left off for free: every track already analyzed is skipped near-
/// instantly (see `TrackAnalysisCoordinator.upsertAndAnalyzeIfNeeded`'s own
/// `existing.isAnalyzed` short-circuit), so nothing already done is
/// re-done.
///
/// Reuses `TrackAnalysisCoordinator.upsertAndAnalyzeIfNeeded` — the exact
/// same per-track "analyze if not already analyzed" logic `MixBuilder`
/// already uses and has been real-device-validated through many rounds of
/// testing — over `MediaLibraryResolver.allSongs()` instead of a bounded
/// source. Andy's own insight, 2026-08-20: "It is nothing less than the
/// scan we do when we want to build and choose 'Use the whole library'" —
/// right about the mechanism being the same one already proven, though
/// "Use the whole library" itself was never actually wired up in Build Mix
/// until this same round (see `MixBuilder`'s own updated doc comment).
@MainActor
final class LibraryScanner: ObservableObject {
    @Published private(set) var isScanning = false
    /// Count of songs *processed* so far (drives the progress bar), not
    /// necessarily count *successfully analyzed* -- see `notDownloadedCount`.
    @Published private(set) var analyzedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var currentTrackTitle: String?
    @Published var scanError: String?
    /// **Added 2026-08-20**, after Andy found a real, related bug (see
    /// `MixBuilder.countUnanalyzed`'s own doc comment): a song without raw
    /// audio access (not downloaded / DRM-restricted) can never actually be
    /// analyzed, no matter how many times a scan runs. Before this,
    /// `analyzedCount` alone claimed "N songs analyzed" on completion even
    /// though some of those N were only ever *processed*, not truly
    /// analyzed -- honest, but not the whole story. Tracked separately here
    /// so `LibraryScanView`'s completion screen can report both numbers
    /// instead of a single count that quietly included failures.
    @Published private(set) var notDownloadedCount = 0

    /// Persisted across launches via `UserDefaults` — deliberately simple
    /// (a single date, not a real analytics/state system), since this
    /// slice only needs to answer one question: has a full pass over the
    /// library ever completed. Read by `SettingsView` (to label its own
    /// "Scan your library" row) without needing an instantiated scanner.
    private static let completedKey = "libraryScanCompletedAt"

    static var hasCompletedAnyScan: Bool {
        UserDefaults.standard.object(forKey: completedKey) != nil
    }

    /// Runs a full pass over every song in the library, analyzing anything
    /// not already analyzed. Safe to call more than once — already-analyzed
    /// tracks are skipped near-instantly, so re-entering this after a
    /// partial/interrupted run (the app was backgrounded, the screen was
    /// left) just picks up the remainder.
    func scan(store: PlaylistStore) async {
        guard !isScanning, let db = store.db else { return }
        isScanning = true
        scanError = nil
        defer { isScanning = false; currentTrackTitle = nil }

        let items = MediaLibraryResolver.allSongs()
        totalCount = items.count
        analyzedCount = 0
        notDownloadedCount = 0

        for item in items {
            currentTrackTitle = item.title ?? item.albumTitle ?? "Unknown"
            do {
                let track = try await TrackAnalysisCoordinator.upsertAndAnalyzeIfNeeded(item: item, db: db)
                if !track.hasRawAudioAccess {
                    notDownloadedCount += 1
                }
            } catch {
                // A rarer database read/write failure -- a plain analysis
                // failure never throws here, it's handled silently inside
                // `upsertAndAnalyzeIfNeeded` and reflected in the track's
                // own `hasRawAudioAccess`/`isAnalyzed` state instead. Leave
                // this one and move on rather than aborting the whole scan
                // over a single bad track.
                scanError = "Some songs couldn't be analyzed and were skipped. You can try again later."
            }
            analyzedCount += 1
        }

        UserDefaults.standard.set(Date(), forKey: Self.completedKey)
    }
}
