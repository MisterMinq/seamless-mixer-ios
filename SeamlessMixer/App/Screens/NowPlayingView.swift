import SwiftUI

/// First real slice of the Now Playing screen, per CLAUDE.md's "Now
/// Playing (confirmed layout, first pass)" — reached by tapping Play on
/// Playlist Detail, per the confirmed Navigation Flow. Shows what's
/// actually sounding right now, driven live off the shared, app-wide
/// `PlaybackEngine` (see `SeamlessMixerApp`'s doc comment for why it moved
/// from a per-screen `@StateObject` to an `@EnvironmentObject` alongside
/// this screen).
///
/// **Deliberate, flagged simplifications for this first slice** — the
/// confirmed design has more than this screen implements yet, and each
/// omission below is a real, separate follow-up, not an oversight:
/// - **Static background, not the confirmed dynamic artwork-derived
///   `MeshGradient`.** That needs Core Image dominant-color extraction from
///   real album artwork plus adaptive light/dark text — a meaningfully
///   bigger, separate piece of work. Uses the flat design-token background
///   everywhere else in the app uses, same as Playlist Detail's placeholder
///   artwork tile.
/// - **No connected-output-device name.** The confirmed design (from the
///   real Apple Music reference screenshots) shows the Bluetooth
///   speaker/amp currently in use — directly relevant to this app's whole
///   premise, but not wired this slice. Would read from
///   `AVAudioSession.sharedInstance().currentRoute.outputs`.
/// - **No queue icon / Queue screen.** That screen doesn't exist yet
///   either — this slice is Now Playing only.
/// - **No favourite star / "..." overflow on this screen.** `PlaylistOverflowSheet`
///   is keyed off a real `Playlist`, which this screen was deliberately
///   *not* handed (only `rows`/`sourceCaption`, a lighter snapshot) to keep
///   this slice's scope to "show what's playing," not duplicate Playlist
///   Detail's controls. Revisit if that turns out to matter in practice.
/// - **Playback controls are Stop-only.** `PlaybackEngine` doesn't support
///   pause or manual prev/next yet (only a fresh `play(queue:)` or a full
///   `stop()`) — prev/next are shown per the confirmed layout but disabled,
///   same "visible but disabled, not hidden" treatment used everywhere else
///   in this app for not-yet-built actions.
struct NowPlayingView: View {
    let rows: [PlaylistDetailRow]
    let sourceCaption: String

    @EnvironmentObject private var playbackEngine: PlaybackEngine
    @Environment(\.dismiss) private var dismiss

    private var nowPlayingRow: PlaylistDetailRow? {
        rows.first { $0.trackPersistentID == playbackEngine.nowPlayingTrackID }
    }

    private var nextRow: PlaylistDetailRow? {
        rows.first { $0.trackPersistentID == playbackEngine.nextTrackPersistentID }
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            if !sourceCaption.isEmpty {
                Text(sourceCaption)
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork)
                .fill(DesignTokens.Color.surfaceTint)
                .frame(width: 260, height: 260)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: DesignTokens.Size.iconLarge * 2))
                        .foregroundStyle(DesignTokens.Color.primaryText)
                )

            if let row = nowPlayingRow {
                VStack(spacing: DesignTokens.Spacing.xxs) {
                    Text(row.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(row.artist)
                        .font(.body)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, DesignTokens.Spacing.lg)
            } else {
                Text("Nothing playing")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }

            progressBar

            controls

            if let nextRow {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.secondary)
                    Text("Blending into \(nextRow.title)")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Bottom row per the confirmed design: connected output device +
            // queue icon. Both deferred (see this file's own doc comment) --
            // shown here as disabled placeholders so the layout's final
            // shape is already right, not left for a later restructure.
            HStack {
                Label("This iPhone", systemImage: "hifispeaker")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Color.textDisabled)
                Spacer()
                Image(systemName: "list.bullet")
                    .foregroundStyle(DesignTokens.Color.textDisabled)
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
        }
        .padding(.vertical, DesignTokens.Spacing.lg)
        .background(DesignTokens.Color.background)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: playbackEngine.isPlaying) { _, isPlaying in
            // If playback stops entirely (queue ran out, or an error) while
            // this screen is showing, there's nothing left to display --
            // popping back to Playlist Detail is a cleaner outcome than
            // sitting on a "Nothing playing" screen the user didn't
            // navigate to on purpose.
            if !isPlaying {
                dismiss()
            }
        }
    }

    // MARK: - Progress

    private var progressBar: some View {
        VStack(spacing: DesignTokens.Spacing.xxs) {
            ProgressView(value: playbackEngine.elapsedSeconds, total: max(playbackEngine.currentTrackDurationSec, 1))
                .tint(DesignTokens.Color.primary)
            HStack {
                Text(Self.formatTime(playbackEngine.elapsedSeconds))
                Spacer()
                Text(Self.formatTime(playbackEngine.currentTrackDurationSec))
            }
            .font(.caption)
            .foregroundStyle(DesignTokens.Color.textSecondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: DesignTokens.Spacing.xl) {
            Image(systemName: "backward.fill")
                .font(.title2)
                .foregroundStyle(DesignTokens.Color.textDisabled)

            Button {
                playbackEngine.stop()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(DesignTokens.Color.primary)
            }

            Image(systemName: "forward.fill")
                .font(.title2)
                .foregroundStyle(DesignTokens.Color.textDisabled)
        }
    }
}

#Preview {
    NavigationStack {
        NowPlayingView(rows: [], sourceCaption: "Genre · Smooth jazz · Energy wave · 12 songs · 47 min")
            .environmentObject(PlaybackEngine())
    }
}
