import Foundation
import BackgroundTasks
import PlaylistCore

/// **Added 2026-08-21**, per Andy's real-device complaint: leaving the app
/// mid-scan stops all progress until he comes back — "no one would expect
/// me to keep an app open... till the end." This is the `BGProcessingTask`
/// fallback tier — available since iOS 13, so every device gets it,
/// including the pre-iOS-26 devices `LibraryScanner.startScan(store:)`'s
/// own doc comment flags as not qualifying for the nicer continued-
/// processing tier. Real, researched trade-off, not glossed over: the
/// system decides *when* this actually runs, based on its own heuristics
/// (charging, idle, etc.) — submitting a request doesn't mean immediate or
/// continuous progress, it means "this will very likely finish eventually,
/// without you having to sit here." That's a different, weaker promise
/// than the iOS 26+ tier makes, and is exactly why this app is building
/// both rather than treating this as the whole answer.
///
/// **Deliberately independent of any particular `LibraryScanner`/
/// `PlaylistStore` instance.** Two real constraints drove this:
/// (1) `BGTaskScheduler` registration must happen very early — before the
/// app finishes launching, per Apple's long-standing guidance — which is
/// before any SwiftUI `@StateObject` is guaranteed safely readable, so the
/// handler closure can't safely capture a live `store`/`scanner` from that
/// point in the app's lifecycle. (2) By the time this handler actually
/// *runs*, the app is genuinely backgrounded (that's the whole reason this
/// tier exists), so there's no live UI observing progress anyway — a
/// fresh, standalone `PlaylistStore()` constructed here is safe in a way it
/// wouldn't be during active foreground rendering (see `SeamlessMixerApp`'s
/// own doc comment on the real SQLite-connection-storm bug that pattern
/// caused once already — that bug was about *high-frequency* re-construction
/// racing a live UI, not an occasional background-only connection).
enum BackgroundScanRegistrar {
    private static let identifier = "com.misterminq.SeamlessMixer.libraryscan"

    /// Called once, from `SeamlessMixerApp.init()` — as early as a pure
    /// SwiftUI-lifecycle app (no `AppDelegate`) can reliably manage,
    /// matching the widely-relied-on pattern of registering from the
    /// `App`'s own `init()` rather than needing a `UIApplicationDelegateAdaptor`
    /// just for this. Registering the same identifier twice within one
    /// process is documented to be a hard error, so this must only ever be
    /// called once — `SeamlessMixerApp.init()` running exactly once per
    /// process is what guarantees that here.
    @discardableResult
    static func registerHandler() -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // `using: nil` means the system may invoke this closure on a
            // background queue, not necessarily the main actor -- but
            // `LibraryScanner`/`PlaylistStore` are both `@MainActor`-
            // isolated (see their own doc comments), so constructing them
            // directly here would be a compile error regardless of which
            // thread actually calls this closure. Hop explicitly rather
            // than assume.
            Task { @MainActor in
                handle(processingTask)
            }
        }
    }

    /// Submits a request for this tier's opportunistic continuation.
    /// Called once per scan start on a pre-iOS-26 device (see
    /// `LibraryScanner.startScan(store:)`) — deliberately not tied to
    /// detecting the exact moment of backgrounding, since `BGProcessingTask`
    /// gives no guarantee about *when* it runs anyway; submitting early and
    /// letting the system decide is simpler and no less effective. Safe to
    /// call even if the scan finishes in the foreground first — the system
    /// either never gets around to running the request, or runs it and
    /// finds nothing left to do (every already-analyzed track short-
    /// circuits near-instantly, per `TrackAnalysisCoordinator`'s own
    /// `existing.isAnalyzed` check).
    static func scheduleProcessingTaskIfNeeded() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /// **Single call site for `setTaskCompleted`, deliberately** — an
    /// earlier draft of this had `expirationHandler` call it directly
    /// (`success: false`) *and* the work continuation call it separately
    /// once `scan()` returned, which can race: cancelling a `Task` doesn't
    /// abort it instantly, it just flips `Task.isCancelled`, so both
    /// closures could end up calling `setTaskCompleted` on the same task.
    /// Fixed by having `expirationHandler` only cancel; the one place that
    /// actually calls `setTaskCompleted` is here, after `scan()` has
    /// genuinely returned (whether it finished normally or exited early
    /// due to cancellation), reading `Task.isCancelled` at that point to
    /// decide success and whether to ask for another slice of time.
    @MainActor
    private static func handle(_ task: BGProcessingTask) {
        let store = PlaylistStore()
        let scanner = LibraryScanner()
        let workTask = Task {
            await scanner.scan(store: store)
            let stillIncomplete = scanner.totalCount > 0 && scanner.analyzedCount < scanner.totalCount
            if !Task.isCancelled, stillIncomplete {
                scheduleProcessingTaskIfNeeded()
            }
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = {
            workTask.cancel()
        }
    }
}
