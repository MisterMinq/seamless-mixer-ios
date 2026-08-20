import Foundation
import MediaPlayer
import PlaylistCore
import BackgroundTasks

/// Drives the confirmed "First-Run Library Analysis" UX (CLAUDE.md) for
/// real.
///
/// **Real background continuation, added 2026-08-21** — per Andy's direct
/// complaint after testing slice 1: "no one would expect me to keep an app
/// open... till the end... if I come back to the screen to check and
/// realise no progress in analysis, that is a real damp in UX." Researched
/// against Apple's own WWDC25 session and header diffs (not guessed at,
/// given this is the least-verifiable API surface in the whole project —
/// no compiler here, and a genuinely new iOS 26 API) before building.
/// `startScan(store:)` is the real entry point now, replacing plain
/// `scan(store:)` at both call sites (`WelcomeScanView`, `LibraryScanView`):
/// - **iOS 26+**: `BGContinuedProcessingTask` — the API actually built for
///   this exact case (a user-initiated, foreground-started task that keeps
///   running with real system-level progress — Dynamic Island/Lock Screen —
///   when backgrounded). See `startWithContinuedProcessing(store:)`.
/// - **Below iOS 26**: `BGProcessingTask`, submitted alongside a plain
///   foreground scan — see `BackgroundScanRegistrar.swift` for the honest
///   trade-off (the system decides *when* it runs, not "immediately and
///   continuously").
///
/// `LibraryScanner` is now an app-wide `@StateObject` (`SeamlessMixerApp`),
/// injected via `.environmentObject` — the same promotion `PlaybackEngine`
/// already went through, and for the same underlying reason: `BGTaskScheduler`
/// only allows *one* registration per task identifier per process, so two
/// screens each owning their own `LibraryScanner` (the original slice-1
/// design) would either crash on double-registration or silently leave one
/// screen's progress state stale. One shared instance means one
/// registration, consistent progress no matter which screen is watching.
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

    /// **Added 2026-08-21** — the iOS 26+ continued-processing task
    /// identifier. Must also be listed in `project.yml`'s
    /// `BGTaskSchedulerPermittedIdentifiers`, alongside
    /// `BackgroundScanRegistrar`'s own separate identifier for the
    /// `BGProcessingTask` fallback tier — two distinct identifiers since
    /// the two tiers genuinely need separate scheduling/handling logic.
    private static let continuedTaskIdentifier = "com.misterminq.SeamlessMixer.libraryscan.continued"
    /// See `registerContinuedTaskIfNeeded`'s own doc comment for why this
    /// is a plain instance flag, safe only because `LibraryScanner` is now
    /// a single, app-wide shared instance (not one per screen).
    private var hasRegisteredContinuedTask = false

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
    ///
    /// **Fixed 2026-08-21 — a real bug, found via a fresh delete/reinstall.**
    /// This never explicitly requested `MPMediaLibrary` authorization —
    /// `SourceSelectionViewModel.requestAccessAndLoadCounts()` was the only
    /// place in the whole app that ever did, called from the Source
    /// Selection Hub's own `.onAppear`. That was invisible until
    /// `WelcomeScanView` made this scanner the very first thing to touch
    /// `MediaPlayer` on a genuinely fresh install: on `.notDetermined`
    /// authorization, `MPMediaQuery.songs().items` silently returns nothing
    /// — no prompt, no error — so the scan "completed" having processed
    /// zero songs, and (worse) still marked itself done via
    /// `completedKey` below, permanently hiding the real gap until a
    /// manual Settings re-scan (reached only after the Hub had already
    /// requested and gotten real access) papered over it. Fixed by
    /// explicitly requesting authorization first, same as the Hub already
    /// does, and by not marking the scan complete at all if that fails —
    /// `scanError` is set instead, so the caller can show a real retry
    /// state rather than a false "0 songs analyzed, you're ready" success.
    func scan(store: PlaylistStore) async {
        guard !isScanning, let db = store.db else { return }
        isScanning = true
        scanError = nil
        defer { isScanning = false; currentTrackTitle = nil }

        guard await ensureAuthorized() else {
            scanError = "Seamless DJ needs access to your music library. Grant access in Settings > Privacy & Security > Media & Apple Music, then try again."
            return
        }

        let items = MediaLibraryResolver.allSongs()
        totalCount = items.count
        analyzedCount = 0
        notDownloadedCount = 0

        for item in items {
            // **Added 2026-08-21**, alongside background continuation --
            // lets an enclosing `Task` (the BGProcessingTask/
            // BGContinuedProcessingTask expiration handlers, or a plain
            // manual cancel) stop this loop cleanly between tracks rather
            // than running to completion regardless. Returning here instead
            // of breaking means `completedKey` below is never reached on
            // this path -- an interrupted scan should never claim to be
            // fully done.
            if Task.isCancelled { return }
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

    /// **Added 2026-08-21** — the real entry point `WelcomeScanView`/
    /// `LibraryScanView`'s "Scan Library" button now calls, in place of
    /// plain `scan(store:)` directly. Layers real background continuation
    /// on top of the exact same scan loop above — see this file's own
    /// top-of-file doc comment for the two-tier design and why.
    func startScan(store: PlaylistStore) async {
        if #available(iOS 26.0, *) {
            await startWithContinuedProcessing(store: store)
        } else {
            BackgroundScanRegistrar.scheduleProcessingTaskIfNeeded()
            await scan(store: store)
        }
    }

    /// **iOS 26+ only.** Registers (lazily, on first use — see
    /// `hasRegisteredContinuedTask`'s own doc comment for why that's safe
    /// here specifically, unlike the `BGProcessingTask` fallback tier) and
    /// submits a `BGContinuedProcessingTaskRequest`, then waits for the
    /// registered handler (`registerContinuedTaskIfNeeded`) to actually run
    /// `scan(store:)` on `self`. Because it's the *same* `self` this
    /// screen is already observing via `@EnvironmentObject`, progress keeps
    /// updating live in the UI exactly as it did before this feature
    /// existed — background continuation is additive, not a separate,
    /// silent code path the visible screen can't see.
    ///
    /// `.strategy = .fail` (not the default `.queue`) deliberately, per
    /// Apple's own WWDC25 sample: this is a direct response to a user
    /// tapping a button right now, so if the system genuinely can't grant a
    /// continued-processing session at this exact moment, failing
    /// immediately and falling back to a plain foreground scan is more
    /// honest than silently queuing something the user has no way to know
    /// is pending.
    @available(iOS 26.0, *)
    private func startWithContinuedProcessing(store: PlaylistStore) async {
        registerContinuedTaskIfNeeded(store: store)
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.continuedTaskIdentifier,
            title: "Analyzing your library",
            subtitle: "Learning each song's tempo, key, and energy"
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            await scan(store: store)
            return
        }

        // **Real bug caught before shipping, not guessed at**: the first
        // draft of this returned right here, right after submission --
        // but the actual scan runs inside the registered handler
        // (`runContinuedTask`), invoked *asynchronously* by the system in
        // response to the submitted request, not synchronously as part of
        // this call stack. Returning immediately after `submit` would have
        // made the caller's own "did it finish?" check run almost
        // instantly, while the scan had barely started -- the exact same
        // false-completion bug already fixed once for the authorization
        // gap (see `scan(store:)`'s own 2026-08-21 doc comment). Fixed:
        // wait for `isScanning` (the same `@Published` state `scan(store:)`
        // itself sets) to reflect the handler actually starting, then wait
        // for it to finish -- matching `scan(store:)`'s own contract of
        // only returning once the real work is done. Bounded on the first
        // wait: a `.fail`-strategy, user-initiated request that submits
        // successfully should hand off to the handler almost immediately
        // in practice: if it somehow doesn't within ~5 seconds, fall back
        // to a direct foreground scan rather than hanging forever.
        var waited = 0
        while !isScanning, waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        guard isScanning else {
            await scan(store: store)
            return
        }
        while isScanning {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// `BGTaskScheduler` documents registering the same identifier twice
    /// within one process as a hard error -- but per Apple's own WWDC25
    /// guidance, a continued-processing handler is explicitly fine to
    /// register dynamically, right before its first real use, unlike
    /// `BGProcessingTask`'s classic "must register before the app finishes
    /// launching" requirement (see `BackgroundScanRegistrar.registerHandler`
    /// for that tier's own early, `init()`-time registration). Registering
    /// here, lazily, on `LibraryScanner`'s one shared app-wide instance
    /// (not per-screen — see this file's top-of-file doc comment) avoids
    /// both the double-registration crash and the timing risk of touching
    /// `BGTaskScheduler` before the app is fully live.
    @available(iOS 26.0, *)
    private func registerContinuedTaskIfNeeded(store: PlaylistStore) {
        guard !hasRegisteredContinuedTask else { return }
        hasRegisteredContinuedTask = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.continuedTaskIdentifier, using: nil) { [weak self] task in
            guard let self, let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await self.runContinuedTask(continuedTask, store: store)
            }
        }
    }

    /// Runs the real scan inside the system-granted continued-processing
    /// session, mirroring this object's own live `analyzedCount`/
    /// `totalCount` into `task.progress` every half second -- coarse
    /// enough to be cheap, fine enough relative to how long a single
    /// track's decode+analyze pass actually takes (seconds, per
    /// `RealAudioValidationTests`' own timing) that the system-level
    /// progress indicator (Dynamic Island/Lock Screen) reads as genuinely
    /// live, not stalled. Single call site for `setTaskCompleted`,
    /// deliberately -- same reasoning as `BackgroundScanRegistrar.handle`'s
    /// own doc comment: `expirationHandler` only cancels, it never
    /// completes the task itself, avoiding a race between two closures
    /// both trying to call `setTaskCompleted` on the same task.
    @available(iOS 26.0, *)
    private func runContinuedTask(_ task: BGContinuedProcessingTask, store: PlaylistStore) async {
        let scanTask = Task { await self.scan(store: store) }
        task.expirationHandler = {
            scanTask.cancel()
        }
        let progressTask = Task { @MainActor [weak self] in
            while let self, !scanTask.isCancelled {
                let isDone = self.totalCount > 0 && self.analyzedCount >= self.totalCount
                task.progress.totalUnitCount = Int64(max(self.totalCount, 1))
                task.progress.completedUnitCount = Int64(self.analyzedCount)
                if isDone { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        await scanTask.value
        progressTask.cancel()
        task.progress.totalUnitCount = Int64(max(totalCount, 1))
        task.progress.completedUnitCount = Int64(analyzedCount)
        task.setTaskCompleted(success: !scanTask.isCancelled)
    }

    /// Bridges `MPMediaLibrary`'s completion-handler-based
    /// `requestAuthorization` into `async`/`await`, matching this
    /// codebase's structured-concurrency style elsewhere. `.authorized`
    /// returns immediately; `.notDetermined` triggers iOS's real system
    /// permission dialog and waits for the answer; `.denied`/`.restricted`
    /// fail immediately with no dialog (nothing to wait for).
    private func ensureAuthorized() async -> Bool {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }
}
