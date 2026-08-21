import SwiftUI

/// First real screen for the confirmed "First-Run Library Analysis" UX
/// (CLAUDE.md) — reached from `SettingsView`'s new "Scan your library" row,
/// not automatically on first launch (that trigger is `RootView`'s job on
/// a fresh install, via `WelcomeScanView` instead).
///
/// Three states, matching the confirmed design almost exactly: an
/// explanation screen with one "Start analyzing" button, a progress screen
/// ("N of M analyzed" + bar + current track), and a low-key completion
/// banner. **Copy note, still accurate as of 2026-08-21**: the progress
/// screen still doesn't literally say "you can close the app or lock your
/// phone" — real background continuation exists now (`scanner.startScan(store:)`,
/// see `LibraryScanner`'s own doc comment), but it's genuinely conditional
/// (iOS 26+ gets it reliably; below that, `BGProcessingTask` finishes
/// unattended on the system's own opportunistic schedule, not guaranteed
/// to be either immediate or continuous). "Stay on this screen while it
/// runs" remains the honest baseline claim regardless of which tier
/// actually applies on a given device.
struct LibraryScanView: View {
    // `PlaylistStore` is passed explicitly everywhere else in this app
    // (`PlaylistDetailView`, `SourceSelectionHubView`, etc.) rather than
    // via `.environmentObject` -- only `PlaybackEngine`/`LibraryScanner`
    // are app-wide that way, per `SeamlessMixerApp`'s own doc comment.
    // Matching that convention here rather than introducing a second,
    // inconsistent way to reach the store.
    @ObservedObject var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    /// **Changed 2026-08-21** — was `@StateObject private var scanner =
    /// LibraryScanner()`. Now shared app-wide — see `LibraryScanner`'s own
    /// top-of-file doc comment for why a fresh instance per screen became
    /// unsafe once real background-task registration was added.
    @EnvironmentObject private var scanner: LibraryScanner

    @State private var didStart = false
    @State private var didFinish = false

    var body: some View {
        NavigationStack {
            Group {
                if didFinish {
                    completionView
                } else if didStart {
                    progressView
                } else {
                    explanationView
                }
            }
            .padding(DesignTokens.Spacing.lg)
            .navigationTitle("Library Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Only offered before/after a scan is actively running --
                    // leaving mid-scan is still possible (there's no modal
                    // lock), just not via a labeled button that implies it's
                    // the expected way out.
                    if !scanner.isScanning {
                        Button(didFinish ? "Done" : "Close") { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: - Explanation

    private var explanationView: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(DesignTokens.Color.primary)
            Text("Analyze your library")
                .font(.title2.bold())
                .foregroundStyle(DesignTokens.Color.textPrimary)
            Text("To build seamless mixes from your whole library, the app needs to scan it once and learn each song's tempo, key, and energy. This happens once — after that, a whole-library mix is instant.")
                .multilineTextAlignment(.center)
                .foregroundStyle(DesignTokens.Color.textSecondary)
            Text("Stay on this screen while it runs. If you leave partway through, coming back later picks up right where it left off — nothing already analyzed gets redone.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(DesignTokens.Color.textSecondary)
            // **Added 2026-08-21**, alongside `LibraryScanner`'s
            // authorization fix -- a genuine failure (access denied) now
            // shows here rather than the flow silently proceeding to
            // `completionView`'s "N songs analyzed" with N stuck at 0.
            if let scanError = scanner.scanError {
                Text(scanError)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.Color.error)
            }
            Spacer()
            Button {
                didStart = true
                Task {
                    // **Changed 2026-08-21** — was `scanner.scan(store:
                    // store)`. `startScan` layers real background
                    // continuation on top of the exact same scan loop —
                    // see `LibraryScanner`'s own doc comment.
                    await scanner.startScan(store: store)
                    if scanner.scanError == nil {
                        didFinish = true
                    } else {
                        didStart = false
                    }
                }
            } label: {
                Text("Start analyzing")
                    .frame(maxWidth: .infinity, minHeight: DesignTokens.Size.buttonHeightStandard)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Color.primary)
            .foregroundStyle(DesignTokens.Color.onPrimary)
        }
    }

    // MARK: - Progress

    private var progressView: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()
            Text("\(scanner.analyzedCount) of \(scanner.totalCount) songs analyzed")
                .font(.title3.bold())
                .foregroundStyle(DesignTokens.Color.textPrimary)
            ProgressView(value: Double(scanner.analyzedCount), total: Double(max(scanner.totalCount, 1)))
                .tint(DesignTokens.Color.primary)
            if let currentTrackTitle = scanner.currentTrackTitle {
                Text(currentTrackTitle)
                    .font(.footnote)
                    .lineLimit(1)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
            // **Reworded 2026-08-20, extended 2026-08-21** -- Andy
            // correctly objected to the original wording ("Some songs in
            // your library aren't downloaded...") stating this as an
            // established fact about his library before the scan had even
            // found anything — "How do you know that?" Right call: this
            // should be preventive guidance shown regardless of outcome,
            // not a claim the app can't back up yet. **2026-08-21**: Andy
            // then directly ffprobe'd real excluded files and found some
            // are genuinely, permanently DRM-protected (old-format
            // purchases, not a download-status issue at all) — see
            // `DRMExclusionSummary.message`'s own doc comment in
            // PlaylistCore for the full evidence. Mentioning that
            // possibility here too, so the reminder doesn't overclaim
            // downloading as a guaranteed fix. The actual, factual count
            // (how many really weren't accessible) still shows on the
            // completion screen, once it's genuinely known — see
            // `completionView` below.
            Text("For a complete scan, make sure the songs in your library are downloaded to this device first. Some songs may still be skipped even so — older purchases can be permanently protected by Apple's copy protection, which no download can fix.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(DesignTokens.Color.textSecondary)
            if let scanError = scanner.scanError {
                Text(scanError)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.Color.warning)
            }
            Spacer()
        }
    }

    // MARK: - Completion

    private var completionView: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(DesignTokens.Color.success)
            Text("Library ready")
                .font(.title2.bold())
                .foregroundStyle(DesignTokens.Color.textPrimary)
            // **Reworded 2026-08-20** -- the completion message previously
            // just said "N songs analyzed," which folded in songs that
            // were only *processed*, not successfully analyzed (see
            // `LibraryScanner.notDownloadedCount`'s own doc comment). Now
            // reports both numbers honestly, matching the DRM-Exclusion
            // UX's "quiet, factual line" principle -- this is also the
            // real, factual version of the during-scan reminder above,
            // shown once it's actually known rather than assumed.
            if scanner.notDownloadedCount > 0 {
                // **Reworded 2026-08-21** -- "aren't downloaded" is only
                // one of two real, confirmed causes (see
                // DRMExclusionSummary.message's own doc comment for the
                // ffprobe evidence of the other, genuinely-DRM-protected
                // one) -- "couldn't be included" stays accurate either way.
                Text("\(scanner.analyzedCount - scanner.notDownloadedCount) of \(scanner.analyzedCount) songs analyzed — \(scanner.notDownloadedCount) couldn't be included (not downloaded, or protected). You can now build a mix from your whole library.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            } else {
                Text("\(scanner.analyzedCount) songs analyzed. You can now build a mix from your whole library.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity, minHeight: DesignTokens.Size.buttonHeightStandard)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Color.primary)
            .foregroundStyle(DesignTokens.Color.onPrimary)
        }
    }
}

#Preview {
    LibraryScanView(store: PlaylistStore())
        .environmentObject(LibraryScanner())
}
