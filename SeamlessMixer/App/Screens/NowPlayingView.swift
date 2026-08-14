import SwiftUI
import MediaPlayer

/// First real slice of the Now Playing screen, per CLAUDE.md's "Now
/// Playing (confirmed layout, first pass)" — reached by tapping Play on
/// Playlist Detail, per the confirmed Navigation Flow. Shows what's
/// actually sounding right now, driven live off the shared, app-wide
/// `PlaybackEngine` (see `SeamlessMixerApp`'s doc comment for why it moved
/// from a per-screen `@StateObject` to an `@EnvironmentObject` alongside
/// this screen).
///
/// **Real transport added 2026-08-14**, after real-device testing found the
/// original Stop-only control unusable for actually verifying playback:
/// tapping it tore the whole session down and auto-navigated away (read by
/// Andy as "pause doesn't work, it just stops and starts over"), and with no
/// seek control, reaching a real crossfade meant waiting out an entire
/// track. Controls are now a real prev/play-pause/next row
/// (`PlaybackEngine.skipToPrevious`/`.pause`/`.resume`/`.skipToNext`), and
/// the progress bar is a real draggable `Slider` calling
/// `PlaybackEngine.seek(toSeconds:)` — dragging near a track's end is now
/// the intended way to force-test a transition without waiting through a
/// whole song. No separate "Stop" button — matches Apple Music's own Now
/// Playing paradigm (pause, or navigate away; playback keeps running in the
/// background either way, per the confirmed background-audio design), not
/// an oversight.
///
/// Also added this pass: real static album artwork (`MPMediaItem.artwork`),
/// looked up fresh whenever `nowPlayingTrackID` changes — same lookup
/// pattern `PlaybackEngine.resolveFileURL` already uses elsewhere in this
/// codebase. Falls back to the flat placeholder tile when a track has no
/// artwork.
///
/// **Source caption is a scrolling `MarqueeText` as of 2026-08-14** — the
/// same real-device feedback pass found the static caption truncated for
/// longer source descriptions with no way to read the rest short of leaving
/// this screen. See `Views/MarqueeText.swift`.
///
/// **Remaining time (not total duration) shown on the right of the progress
/// bar, as of 2026-08-14** — matches Apple Music's own `-M:SS` convention,
/// confirmed directly against a real Apple Music screenshot Andy shared.
///
/// **Queue icon is real, opening `QueueView`, as of 2026-08-14** — resolves
/// a Round 4 discussion (should Playlist Detail merge into Now Playing?)
/// started from that same screenshot: it shouldn't, since real Apple Music
/// keeps its playlist-browsing screen separate too and only ever shows an
/// embedded queue *preview* from Now Playing — `QueueView` is that preview,
/// not a merge. See its own doc comment for the full reasoning and its
/// deliberately read-only first-slice scope.
///
/// **Deliberate, flagged simplifications still remaining** — each omission
/// below is a real, separate follow-up, not an oversight:
/// - **Static background, not the confirmed dynamic artwork-derived
///   `MeshGradient`.** That needs Core Image dominant-color extraction from
///   the now-real artwork plus adaptive light/dark text — a meaningfully
///   bigger, separate piece of work than just displaying the artwork itself.
/// - **No connected-output-device name.** The confirmed design (from the
///   real Apple Music reference screenshots) shows the Bluetooth
///   speaker/amp currently in use — directly relevant to this app's whole
///   premise, but not wired this slice. Would read from
///   `AVAudioSession.sharedInstance().currentRoute.outputs`.
/// - **No favourite star / "..." overflow on this screen.** `PlaylistOverflowSheet`
///   is keyed off a real `Playlist`, which this screen was deliberately
///   *not* handed (only `rows`/`sourceCaption`, a lighter snapshot) to keep
///   this slice's scope to "show what's playing," not duplicate Playlist
///   Detail's controls. Revisit if that turns out to matter in practice.
struct NowPlayingView: View {
    let rows: [PlaylistDetailRow]
    let sourceCaption: String

    @EnvironmentObject private var playbackEngine: PlaybackEngine
    @Environment(\.dismiss) private var dismiss

    /// While the user has a finger on the slider, the displayed value comes
    /// from `dragValue` (not the live-updating `playbackEngine.elapsedSeconds`)
    /// so the thumb doesn't fight the user's own drag gesture — `seek(toSeconds:)`
    /// only actually runs once the drag ends.
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    @State private var artworkImage: UIImage?
    @State private var showQueue = false

    private var nowPlayingRow: PlaylistDetailRow? {
        rows.first { $0.trackPersistentID == playbackEngine.nowPlayingTrackID }
    }

    private var nextRow: PlaylistDetailRow? {
        rows.first { $0.trackPersistentID == playbackEngine.nextTrackPersistentID }
    }

    var body: some View {
        // Wrapped in a ScrollView as of 2026-08-14 -- real-device feedback
        // found the play button, the time labels, and long titles cut off
        // ("out of range, not in the screen range") once a track was
        // playing.
        //
        // **Corrected 2026-08-14 (same day) — the first fix only addressed
        // vertical overflow.** Real-device screenshots after that fix showed
        // the cutoff was actually *horizontal* (left and right edges both
        // cut, content not centered) — a different bug the vertical-only fix
        // didn't touch at all. Root cause: `.frame(minHeight: geo.size.height)`
        // constrained height but never explicitly constrained *width*, and
        // `MarqueeText`'s inner content (two `.fixedSize()` copies of
        // `sourceCaption` side by side, deliberately wider than the screen
        // so it has somewhere to scroll to) could report that large ideal
        // width back up through the view hierarchy — `MarqueeText`'s own
        // `.clipped()` stops it from *rendering* outside its bounds, but
        // doesn't stop it from *sizing* its ancestors that way, so the
        // whole content column (title, transport row, everything) could end
        // up wider than the actual screen with no explicit width to stop it.
        // Fixed by pinning both dimensions explicitly instead of just one.
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.lg) {
                    if !sourceCaption.isEmpty {
                        // Real scrolling marquee (2026-08-14) — a static,
                        // centered, single-line caption truncated for longer
                        // source descriptions (e.g. several combined
                        // sources), with no way to read the rest without
                        // leaving this screen.
                        MarqueeText(text: sourceCaption)
                            .padding(.horizontal, DesignTokens.Spacing.lg)
                    }

                    Spacer()

                    artworkTile

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

                    // Bottom row per the confirmed design: connected output
                    // device + queue icon. Output device is still deferred
                    // (see this file's own doc comment) -- shown as a
                    // disabled placeholder so the layout's final shape is
                    // already right. Queue icon is real as of 2026-08-14
                    // (see `QueueView`).
                    HStack {
                        Label("This iPhone", systemImage: "hifispeaker")
                            .font(.caption)
                            .foregroundStyle(DesignTokens.Color.textDisabled)
                        Spacer()
                        Button {
                            showQueue = true
                        } label: {
                            Image(systemName: "list.bullet")
                                .foregroundStyle(DesignTokens.Color.primaryText)
                        }
                        .disabled(nowPlayingRow == nil)
                    }
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                }
                .padding(.vertical, DesignTokens.Spacing.lg)
                .frame(width: geo.size.width)
                .frame(minHeight: geo.size.height)
            }
        }
        .background(DesignTokens.Color.background)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: playbackEngine.isPlaying) { _, isPlaying in
            // If playback stops entirely (queue ran out, or an error) while
            // this screen is showing, there's nothing left to display --
            // popping back to Playlist Detail is a cleaner outcome than
            // sitting on a "Nothing playing" screen the user didn't
            // navigate to on purpose. Pausing does NOT trigger this --
            // `isPlaying` stays true while paused, only a genuine stop
            // flips it.
            if !isPlaying {
                dismiss()
            }
        }
        .onChange(of: playbackEngine.nowPlayingTrackID) { _, trackID in
            loadArtwork(for: trackID)
        }
        .onAppear {
            loadArtwork(for: playbackEngine.nowPlayingTrackID)
        }
        .sheet(isPresented: $showQueue) {
            QueueView(rows: rows)
        }
    }

    // MARK: - Artwork

    @ViewBuilder
    private var artworkTile: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork)
            .fill(DesignTokens.Color.surfaceTint)
            .frame(width: 260, height: 260)
            .overlay {
                if let artworkImage {
                    Image(uiImage: artworkImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 260, height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: DesignTokens.Size.iconLarge * 2))
                        .foregroundStyle(DesignTokens.Color.primaryText)
                }
            }
    }

    /// Synchronous single-item `MPMediaQuery` lookup, same pattern
    /// `PlaybackEngine.resolveFileURL` already uses — a lookup by one exact
    /// `persistentID` is cheap enough not to need a detached `Task`.
    private func loadArtwork(for trackID: Int64?) {
        guard let trackID else {
            artworkImage = nil
            return
        }
        let query = MPMediaQuery.songs()
        let mediaID = UInt64(bitPattern: trackID)
        query.addFilterPredicate(MPMediaPropertyPredicate(value: mediaID, forProperty: MPMediaItemPropertyPersistentID))
        guard let item = query.items?.first, let artwork = item.artwork else {
            artworkImage = nil
            return
        }
        artworkImage = artwork.image(at: CGSize(width: 260, height: 260))
    }

    // MARK: - Progress

    private var progressBar: some View {
        VStack(spacing: DesignTokens.Spacing.xxs) {
            Slider(
                value: Binding(
                    get: { isDragging ? dragValue : playbackEngine.elapsedSeconds },
                    set: { dragValue = $0 }
                ),
                in: 0...max(playbackEngine.currentTrackDurationSec, 1),
                onEditingChanged: { editing in
                    if editing {
                        dragValue = playbackEngine.elapsedSeconds
                        isDragging = true
                    } else {
                        playbackEngine.seek(toSeconds: dragValue)
                        isDragging = false
                    }
                }
            )
            .tint(DesignTokens.Color.primary)
            .disabled(nowPlayingRow == nil)
            HStack {
                Text(Self.formatTime(isDragging ? dragValue : playbackEngine.elapsedSeconds))
                Spacer()
                // Remaining time, not total duration -- matches Apple
                // Music's own convention (confirmed directly against Andy's
                // reference screenshot, "-4:09"). Real-device feedback
                // (Round 3, issue 6) asked for exactly this.
                Text(Self.formatRemainingTime(
                    elapsed: isDragging ? dragValue : playbackEngine.elapsedSeconds,
                    total: playbackEngine.currentTrackDurationSec
                ))
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

    private static func formatRemainingTime(elapsed: Double, total: Double) -> String {
        guard total.isFinite, total > 0 else { return "-0:00" }
        return "-" + formatTime(max(0, total - elapsed))
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: DesignTokens.Spacing.xl) {
            Button {
                playbackEngine.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundStyle(DesignTokens.Color.primaryText)
            }
            .disabled(nowPlayingRow == nil)

            Button {
                if playbackEngine.isPaused {
                    playbackEngine.resume()
                } else {
                    playbackEngine.pause()
                }
            } label: {
                Image(systemName: playbackEngine.isPaused ? "play.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(DesignTokens.Color.primary)
            }
            .disabled(nowPlayingRow == nil)

            Button {
                playbackEngine.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundStyle(DesignTokens.Color.primaryText)
            }
            .disabled(nextRow == nil)
        }
    }
}

#Preview {
    NavigationStack {
        NowPlayingView(rows: [], sourceCaption: "Genre · Smooth jazz · Energy wave · 12 songs · 47 min")
            .environmentObject(PlaybackEngine())
    }
}
