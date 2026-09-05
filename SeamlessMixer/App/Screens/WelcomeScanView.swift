import SwiftUI

/// The app's actual first screen on a fresh install, per Andy's own
/// concrete design (2026-08-20/21) revising slice 1's Settings-triggered
/// approach — "the main thing though is to get the full scan right."
/// Shown by `RootView` whenever `LibraryScanner.hasCompletedAnyScan` is
/// false; once a scan finishes here, `onCompleted()` flips `RootView` over
/// to `MyMixesView` for this launch and every one after.
///
/// **Andy's own copy, used verbatim** — heading "Welcome to Seamless DJ.
/// An App for creating seamless playlist mixes!", body explaining the
/// one-time scan and, conditionally ("if some songs are not found, it
/// could be..."), the two real reasons a song might not be included.
/// That conditional framing is deliberately different from the *during*-
/// scan reminder below it: Andy separately flagged (Testing 44) that
/// stating "some songs aren't downloaded" as settled fact before a scan
/// has run anything is presumptuous — this welcome copy avoids that by
/// staying hedged ("if... it could be..."), matching what he actually
/// asked for here.
///
/// **Layout, per Andy's description**: heading, body, a progress bar
/// (empty before tapping, live once running), then a "Scan Library"
/// button underneath — with the "X of Y songs scanned" count shown
/// inside the button itself once scanning starts (the "integrated in the
/// button" alternative he floated), rather than as a separate line of
/// text. A brief completion state follows before handing off to My
/// Mixes, matching the positive reception the three-state Settings flow
/// already got ("a good alternative...").
struct WelcomeScanView: View {
    @ObservedObject var store: PlaylistStore
    let onCompleted: () -> Void

    /// **Changed 2026-08-21** — was `@StateObject private var scanner =
    /// LibraryScanner()`. Now shared app-wide (`SeamlessMixerApp`), same
    /// reasoning as `PlaybackEngine` — see `LibraryScanner`'s own
    /// top-of-file doc comment for why a fresh instance per screen became
    /// unsafe once real background-task registration was added.
    @EnvironmentObject private var scanner: LibraryScanner
    @State private var didStart = false
    @State private var didFinish = false

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()

            // **Fixed 2026-08-21** -- the heading previously stayed
            // "Welcome to Seamless DJ..." in the completion state too,
            // which is exactly why the finished screen read as "another
            // Welcome screen" rather than a distinct step -- a real,
            // separate complaint from the auth bug that produced the
            // confusing near-instant transition in the first place.
            Text(didFinish ? "Library ready" : "Welcome to Seamless DJ. An App for creating seamless playlist mixes!")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(DesignTokens.Color.textPrimary)

            if didFinish {
                completionBody
            } else {
                Text("We have to scan your whole library to index all songs in order to build a fast mix. This scan only happens once and may take time. Please note that if some songs are not found, it could be they are Apple Music subscribed songs or songs not downloaded to this device.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.Color.textSecondary)

                // **Added 2026-09-05, per Testing (60)/(61)** -- Andy timed
                // a full 2,722-song scan two ways: ~22 minutes with the app
                // open and the screen on, vs. a ~49 songs/min pace while
                // backgrounded/locked (projecting to roughly an hour for
                // the same library). That ~2.5x gap is iOS's own background
                // CPU throttling, not this app's analysis code being slow
                // -- not something a third-party app can opt out of, so
                // the honest fix is setting the right expectation here
                // rather than a code change.
                Text("Tip: leave the app open with your screen on for the fastest results. Locking your phone works too, but iOS slows background processing down to save battery, which can make a full scan take noticeably longer.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.Color.textSecondary)

                // **Added 2026-09-05, real bug found via Andy's own repeated
                // testing** — the count was only ever shown inside the
                // "Scan Library" button's own label (see `scanButtonLabel`
                // below), never as a standalone, clearly-readable progress
                // line. Andy: "I only see [the] progress bar... and the
                // song titles flashing underneath. Nothing more... I
                // assumed [there was no number] because you did not know
                // the number of songs." The number was there the whole
                // time, just never noticed across many real testing
                // rounds — a button's own label doesn't read as a progress
                // indicator the way a bold headline does. This is what
                // actually lets him tell "background scanning genuinely
                // stalled" apart from "still working, just slow" — the
                // whole point of the background-continuation investigation
                // he's now asking to pursue "in earnest."
                if didStart {
                    Text("\(scanner.analyzedCount) of \(scanner.totalCount) songs analyzed")
                        .font(.title3.bold())
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                }

                ProgressView(value: Double(scanner.analyzedCount), total: Double(max(scanner.totalCount, 1)))
                    .tint(DesignTokens.Color.primary)

                if didStart, let currentTrackTitle = scanner.currentTrackTitle {
                    Text(currentTrackTitle)
                        .font(.footnote)
                        .lineLimit(1)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                }

                // **Added 2026-08-21**, alongside the authorization fix --
                // a genuine failure (access denied, or a rarer per-track
                // issue) now shows here and the button resets to "Scan
                // Library" for a retry, instead of silently proceeding to
                // a false "0 songs analyzed, you're ready" completion.
                if let scanError = scanner.scanError {
                    Text(scanError)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(DesignTokens.Color.error)
                }
            }

            Spacer()

            if !didFinish {
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
                    Text(scanButtonLabel)
                        .frame(maxWidth: .infinity, minHeight: DesignTokens.Size.buttonHeightStandard)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Color.primary)
                .foregroundStyle(DesignTokens.Color.onPrimary)
                .disabled(scanner.isScanning)
            }
        }
        .padding(DesignTokens.Spacing.lg)
    }

    /// Before tapping: "Scan Library." Once running: the live count,
    /// doubling as both the button's own disabled state and the progress
    /// announcement Andy asked for "integrated in the button" — no
    /// separate text element needed for it.
    private var scanButtonLabel: String {
        guard didStart else { return "Scan Library" }
        return "\(scanner.analyzedCount) of \(scanner.totalCount) songs scanned"
    }

    private var completionBody: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(DesignTokens.Color.success)
            if scanner.notDownloadedCount > 0 {
                // **Reworded 2026-08-21** -- see the matching change in
                // LibraryScanView.swift for why "couldn't be included"
                // replaces "aren't downloaded" here too.
                Text("\(scanner.analyzedCount - scanner.notDownloadedCount) of \(scanner.analyzedCount) songs analyzed — \(scanner.notDownloadedCount) couldn't be included (not downloaded, or protected).")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            } else {
                Text("\(scanner.analyzedCount) songs analyzed. You're ready to build your first seamless mix.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
            Button {
                onCompleted()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity, minHeight: DesignTokens.Size.buttonHeightStandard)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Color.primary)
            .foregroundStyle(DesignTokens.Color.onPrimary)
        }
    }
}

#Preview {
    WelcomeScanView(store: PlaylistStore(), onCompleted: {})
        .environmentObject(LibraryScanner())
}
