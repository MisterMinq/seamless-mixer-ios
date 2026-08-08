import SwiftUI
import PlaylistCore

/// App entry point — deliberately minimal. Its only job right now is to
/// prove the real app target actually links against `PlaylistCore` (data
/// layer + analysis + sequencing, all validated separately via
/// `PlaylistCoreTests` on Codemagic) and can run a real screen against it,
/// per CLAUDE.md's "Build & Verification Pipeline — No Mac" phased
/// approach: start small, add one confirmed screen at a time, not all five
/// at once.
@main
struct SeamlessMixerApp: App {
    var body: some Scene {
        WindowGroup {
            MyMixesView(store: PlaylistStore())
        }
    }
}
