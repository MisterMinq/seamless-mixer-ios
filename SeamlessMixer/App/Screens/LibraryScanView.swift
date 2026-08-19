import SwiftUI

/// First real screen for the confirmed "First-Run Library Analysis" UX
/// (CLAUDE.md) — reached from `SettingsView`'s new "Scan your library" row,
/// not automatically on first launch (that trigger is separate, deferred
/// follow-up work, same as true background continuation — see
/// `LibraryScanner`'s own doc comment for the full slice-1 scope).
///
/// Three states, matching the confirmed design almost exactly: an
/// explanation screen with one "Start analyzing" button, a progress screen
/// ("N of M analyzed" + bar + current track), and a low-key completion
/// banner. **One deliberate departure from the confirmed copy**: the
/// progress screen doesn't say "you can close the app or lock your phone —
/// this keeps going in the background," since that's true background
/// continuation (`BGContinuedProcessingTask`/`BGProcessingTask`), which
/// this slice doesn't implement — saying so anyway would repeat the exact
/// "don't pretend it works" mistake Rule 3 exists to prevent. Says the
/// honest version instead: stay on this screen while it runs.
struct LibraryScanView: View {
    // `PlaylistStore` is passed explicitly everywhere else in this app
    // (`PlaylistDetailView`, `SourceSelectionHubView`, etc.) rather than
    // via `.environmentObject` -- only `PlaybackEngine` is app-wide that
    // way, per `SeamlessMixerApp`'s own doc comment. Matching that
    // convention here rather than introducing a second, inconsistent way
    // to reach the store.
    @ObservedObject var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = LibraryScanner()

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
            Spacer()
            Button {
                didStart = true
                Task {
                    await scanner.scan(store: store)
                    didFinish = true
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
            // Per the DRM-Exclusion UX section's 2026-08-20 revision --
            // the real, confirmed reason some songs get skipped here isn't
            // subscription DRM, it's simply not being downloaded yet.
            Text("Some songs in your library aren't downloaded to this device yet — these can't be processed for blending and will be skipped. Downloading them in the Music app usually fixes this.")
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
            Text("\(scanner.analyzedCount) songs analyzed. You can now build a mix from your whole library.")
                .multilineTextAlignment(.center)
                .foregroundStyle(DesignTokens.Color.textSecondary)
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
}
