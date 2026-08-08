import SwiftUI
import PlaylistCore

/// The screen a generated seamless playlist lands on right after "Build
/// Mix" (per the confirmed Navigation Flow: Hub -> Build Mix -> Playlist
/// Detail -> Now Playing) — the bridge between picking a source and actually
/// playing something. Layout per CLAUDE.md's "Playlist Detail (confirmed
/// layout, first pass)": back chevron (automatic, via `NavigationStack`) +
/// star/dots top row, collage artwork, title + source-context subtitle, a
/// single centered Play button, track list reusing the Queue screen's
/// teal/gray connector-line treatment, and a footer line.
///
/// **Deliberate, flagged simplifications for this slice:**
/// - Favorite (star) and the "..." overflow sheet (Favourite/Share/Play
///   Next/Rename/Refresh/Delete) are still no-ops, same pattern as
///   `MyMixesView`'s row ellipsis — real wiring is its own later slice.
/// - The Play button is present but disabled, with a caption explaining
///   why: the AVAudioEngine mixing engine that would actually play a
///   blended set doesn't exist yet (still a first-pass design, per
///   CLAUDE.md's "Mixing Engine" section) — a saved playlist here is a
///   real, correctly-sequenced recipe, it just can't be *played* yet. Per
///   Rule 3's spirit, this screen doesn't pretend otherwise.
/// - Collage artwork is the same flat placeholder tile `MyMixesView` uses,
///   not real per-track artwork compositing.
struct PlaylistDetailView: View {
    let playlist: Playlist
    let store: PlaylistStore

    @StateObject private var viewModel = PlaylistDetailViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                header
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, DesignTokens.Spacing.xl)
                } else if viewModel.rows.isEmpty {
                    Text("This playlist has no tracks yet.")
                        .font(.body)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                } else {
                    trackList
                    footer
                }
            }
            .padding(DesignTokens.Spacing.md)
        }
        .background(DesignTokens.Color.background)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: {}) {
                    Image(systemName: playlist.isFavorite ? "star.fill" : "star")
                }
                .tint(DesignTokens.Color.primaryText)
                Button(action: {}) {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(DesignTokens.Color.primaryText)
            }
        }
        .task {
            viewModel.load(playlist: playlist, store: store)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork)
                .fill(DesignTokens.Color.surfaceTint)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .overlay(
                    Image(systemName: "music.note.list")
                        .font(.system(size: DesignTokens.Size.iconLarge))
                        .foregroundStyle(DesignTokens.Color.primaryText)
                )

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(playlist.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                if !viewModel.subtitle.isEmpty {
                    Text(viewModel.subtitle)
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                }
            }

            VStack(spacing: DesignTokens.Spacing.xxs) {
                Button(action: {}) {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: DesignTokens.Size.buttonHeightStandard)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Color.primary)
                .foregroundStyle(DesignTokens.Color.onPrimary)
                .disabled(true)

                Text("Playback isn't built yet — this recipe is saved and sequenced, just not playable yet.")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, DesignTokens.Spacing.xs)
        }
    }

    // MARK: - Track list

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(viewModel.rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 0) {
                    trackRow(row)
                    if index < viewModel.rows.count - 1 {
                        connector(isImminent: index == 0)
                    }
                }
            }
        }
    }

    private func trackRow(_ row: PlaylistDetailRow) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("\(row.position + 1)")
                .font(.footnote)
                .foregroundStyle(DesignTokens.Color.textSecondary)
                .frame(width: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(row.title)
                    .font(.body)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .lineLimit(1)
                Text(row.artist)
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(row.durationText)
                .font(.footnote)
                .foregroundStyle(DesignTokens.Color.textSecondary)

            Button(action: {}) {
                Image(systemName: "ellipsis")
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .frame(width: DesignTokens.Size.tapTargetMin, height: DesignTokens.Size.tapTargetMin)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    /// Solid teal for the first transition (the one that would be imminent
    /// the moment Play is tapped), lighter gray further out — same
    /// visual-blending signal as the confirmed Queue screen design, adapted
    /// here since Playlist Detail has no "now playing" row of its own yet
    /// (playback hasn't started). Flagged as a judgment call, not an
    /// explicit CLAUDE.md spec for this screen's pre-playback state.
    private func connector(isImminent: Bool) -> some View {
        Rectangle()
            .fill(isImminent ? DesignTokens.Color.primary : DesignTokens.Color.border)
            .frame(width: 2, height: DesignTokens.Spacing.md)
            .padding(.leading, 20 + DesignTokens.Spacing.sm)
    }

    // MARK: - Footer

    private var footer: some View {
        Text(viewModel.footerText)
            .font(.caption)
            .foregroundStyle(DesignTokens.Color.textSecondary)
            .padding(.top, DesignTokens.Spacing.sm)
    }
}

#Preview {
    NavigationStack {
        PlaylistDetailView(
            playlist: Playlist(name: "Smooth Jazz Seamless Mix", mode: .energyWave),
            store: PlaylistStore()
        )
    }
}
