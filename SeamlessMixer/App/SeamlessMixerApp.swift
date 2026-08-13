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

    var body: some Scene {
        WindowGroup {
            MyMixesView(store: PlaylistStore())
                .environmentObject(playbackEngine)
                .preferredColorScheme(.light)
        }
    }
}
