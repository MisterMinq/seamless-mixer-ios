import SwiftUI

/// **Added 2026-08-20/21**, per Andy's own explicit design revision — the
/// first-run library scan becomes the app's actual first screen on a fresh
/// install, not something reached only via Settings. Reads
/// `LibraryScanner.hasCompletedAnyScan` once at launch (a plain
/// `UserDefaults` check, cheap, no reason to re-check it every `body`
/// evaluation) and shows `WelcomeScanView` until that first scan finishes,
/// at which point `onCompleted` flips `hasCompletedScan` and this view
/// swaps to `MyMixesView` for the rest of the session — and every launch
/// after this one, since the flag persists.
///
/// Andy's own note: since he already ran the Settings-triggered scan
/// (slice 1) and it completed, `hasCompletedAnyScan` is already `true` on
/// his device — he won't see this new Welcome screen without deleting and
/// reinstalling the TestFlight build first, which resets `UserDefaults`.
struct RootView: View {
    @ObservedObject var store: PlaylistStore
    @State private var hasCompletedScan = LibraryScanner.hasCompletedAnyScan

    var body: some View {
        if hasCompletedScan {
            MyMixesView(store: store)
        } else {
            WelcomeScanView(store: store) {
                hasCompletedScan = true
            }
        }
    }
}
