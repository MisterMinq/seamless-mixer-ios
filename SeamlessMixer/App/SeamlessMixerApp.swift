import SwiftUI
import PlaylistCore

/// App entry point — deliberately minimal. Its only job right now is to
/// prove the real app target actually links against `PlaylistCore` (data
/// layer + analysis + sequencing, all validated separately via
/// `PlaylistCoreTests` on Codemagic) and can run a real screen against it,
/// per CLAUDE.md's "Build & Verification Pipeline — No Mac" phased
/// approach: start small, add one confirmed screen at a time, not all five
/// at once.
///
/// **`PlaybackEngine` is created here and injected via `.environmentObject`
/// (added alongside the Now Playing screen)** — previously it was a
/// per-`PlaylistDetailView` `@StateObject`, which meant playback would have
/// been silently torn down and rebuilt every time that view left the
/// navigation stack. Now Playing needs to be reachable as its own screen
/// (per the confirmed Navigation Flow: Play -> Now Playing) and playback
/// needs to keep going while browsing elsewhere (the confirmed persistent
/// mini-player is future work, but even without it, playback surviving
/// navigation is the correct baseline), so `PlaybackEngine` moved up to
/// live for the whole app session instead of one screen's lifetime.
///
/// **`.preferredColorScheme(.light)` added 2026-08-14** — real-device
/// feedback found the status bar's time/signal/wifi/battery icons nearly
/// invisible on Now Playing. Root cause: this app only has one, light,
/// design-token palette (per CLAUDE.md's "Design Tokens" section) — there's
/// no dark variant — but nothing ever told iOS that, so on a phone set to
/// system Dark Mode, iOS inferred a dark app and rendered light-colored
/// status bar content, which is nearly invisible against the app's actual
/// (still light) background regardless of system setting. Forcing light
/// mode here keeps status bar content dark/legible everywhere until a real
/// dark palette is designed — a design decision, not something to improvise
/// per-screen.
@main
struct SeamlessMixerApp: App {
    @StateObject private var playbackEngine = PlaybackEngine()
    /// **Fixed 2026-08-14 — a real, severe bug, not a style nit.** This used
    /// to be constructed inline as `MyMixesView(store: PlaylistStore())`
    /// inside `body`. `body` is a computed property SwiftUI re-invokes any
    /// time a `@StateObject` it references publishes a change — including
    /// `playbackEngine`, whose `tick()` mutates `elapsedSeconds` roughly 10
    /// times a second during playback. Since `PlaylistStore` was passed in
    /// as a fresh constructor argument (`@ObservedObject`, not
    /// `@StateObject`, on the receiving `MyMixesView`), every one of those
    /// re-evaluations created a *brand-new* `PlaylistStore`, which opens a
    /// *brand-new* `DatabaseManager`/GRDB `DatabaseQueue` — a real,
    /// independent SQLite connection to the same on-disk file — on top of
    /// whichever earlier ones hadn't been deallocated yet. `DatabaseQueue`
    /// only serializes access *within one instance*; it does nothing to
    /// protect against a second, fully independent connection to the same
    /// file, and the database's default (non-WAL) journal mode locks the
    /// whole file during any write transaction. A `Build Mix` write landing
    /// while a freshly-spawned stray connection was also active was exactly
    /// what produced the real-device "SQLite error 5: database is locked -
    /// while executing `COMMIT TRANSACTION`" failure. Fixed the same way
    /// `playbackEngine` already correctly avoided this: `@StateObject` here
    /// too, so exactly one `PlaylistStore`/one SQLite connection exists for
    /// the app's entire lifetime, and every `body` re-evaluation passes the
    /// same instance rather than constructing a new one.
    @StateObject private var store = PlaylistStore()
    /// **Added 2026-08-21, promoted app-wide for the same reason
    /// `playbackEngine` above is** — `BGTaskScheduler` only allows one
    /// registration per task identifier per process, so `LibraryScanner`
    /// can no longer be a fresh `@StateObject` on each of `WelcomeScanView`/
    /// `LibraryScanView` (slice 1's design) without risking a double-
    /// registration crash or split, inconsistent progress state between
    /// screens. See `LibraryScanner`'s own top-of-file doc comment for the
    /// full reasoning.
    @StateObject private var libraryScanner = LibraryScanner()

    /// **Added 2026-08-21** — registers the `BGProcessingTask` fallback
    /// tier as early as this pure-SwiftUI-lifecycle app (no `AppDelegate`)
    /// can manage. `init()` running exactly once per process, before any
    /// scene appears, is the standard substitute developers rely on for
    /// `UIApplicationDelegate.application(_:didFinishLaunchingWithOptions:)`
    /// timing when there's no explicit delegate — see
    /// `BackgroundScanRegistrar`'s own doc comment for why this tier
    /// specifically needs registration this early, unlike the iOS 26+
    /// continued-processing tier (registered lazily instead, on
    /// `LibraryScanner` itself). Adding this custom `init()` doesn't
    /// disturb `store`/`playbackEngine`/`libraryScanner`'s own default-value
    /// initialization above — Swift still applies each property's default
    /// expression automatically in any initializer that doesn't otherwise
    /// assign it.
    init() {
        BackgroundScanRegistrar.registerHandler()
    }

    var body: some Scene {
        WindowGroup {
            // **Changed 2026-08-20/21** — was `MyMixesView(store: store)`
            // directly. Now routes through `RootView`, which shows the
            // mandatory first-run scan (`WelcomeScanView`) on a fresh
            // install and `MyMixesView` on every launch after — see
            // `RootView`'s own doc comment.
            RootView(store: store)
                .environmentObject(playbackEngine)
                .environmentObject(libraryScanner)
                .preferredColorScheme(.light)
        }
    }
}
