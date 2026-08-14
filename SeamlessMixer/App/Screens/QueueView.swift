import SwiftUI

/// The confirmed "Queue / Up next" screen (CLAUDE.md's "Queue / 'Up next'
/// (confirmed layout, first pass)"), opened via Now Playing's queue icon —
/// added 2026-08-14, resolving Round 4's "should Playlist Detail merge into
/// Now Playing" discussion. It doesn't: Andy's own Apple Music reference
/// screenshot showed Now Playing embedding a lightweight *queue preview*
/// ("Continue Playing / From [playlist]") via its own queue affordance,
/// while still keeping a separate playlist-browsing screen elsewhere in the
/// app. This screen is that queue preview — not a merge, not a replacement
/// for Playlist Detail, which keeps its own real job (browsing/editing/
/// reordering a mix independent of whether it's currently playing).
///
/// Presented as its own sheet sliding up over Now Playing, using the static
/// light theme rather than the (still not built) dynamic artwork
/// background — per the confirmed design, "it's a utility list, not part of
/// the 'mood' experience," the same split real Apple Music's own playlist-
/// view vs. Now Playing screens make. Reuses the teal/gray connector-line
/// convention `PlaylistDetailView`'s track list already established (solid
/// teal for the one imminent transition, lighter gray further out) and the
/// real animated `NowPlayingBarsView` for the now-playing row, instead of a
/// static icon.
///
/// **Deliberately read-only for this first slice** — the per-track "..."
/// menu is shown (per the confirmed design, every row but "now playing" has
/// one) but its actions are visible-and-disabled placeholders, the same
/// "visible but disabled, not hidden" treatment this project uses
/// everywhere else for a deferred action. Wiring "Remove from this mix" up
/// for real here would mean handing this screen the actual `Playlist`/
/// `PlaylistStore`, which `NowPlayingView` was deliberately never given
/// (only a lightweight `rows` snapshot, per its own doc comment, to keep
/// its footprint small) — kept out of scope for this pass rather than
/// widening that on the strength of this one screen.
///
/// **Now-playing row pinned above a scrollable list, as of 2026-08-14** —
/// the first version put every row (including now-playing) inside one
/// `List`, so scrolling down carried the now-playing row away with
/// everything else, leaving no visual anchor for "what's actually playing"
/// once scrolled even slightly (exactly what real-device feedback reported:
/// "the whole screen is scrolled up till the 'Now Playing' button
/// disappears"). Restructured so only the *remaining* upcoming tracks live
/// inside the scrollable `List`; the now-playing row is a fixed sibling
/// above it, opaque against the same background, so the list visibly
/// scrolls underneath it rather than carrying it away.
struct QueueView: View {
    let rows: [PlaylistDetailRow]

    @EnvironmentObject private var playbackEngine: PlaybackEngine
    @Environment(\.dismiss) private var dismiss

    /// Index of the now-playing row within `rows`. `nil` shouldn't happen in
    /// practice — this sheet is only reachable from a screen that's already
    /// showing something playing — but handled defensively rather than
    /// force-unwrapped.
    private var nowPlayingIndex: Int? {
        rows.firstIndex { $0.trackPersistentID == playbackEngine.nowPlayingTrackID }
    }

    /// The now-playing row plus everything after it, in order — tracks
    /// already played aren't part of "up next".
    private var upcoming: [PlaylistDetailRow] {
        guard let nowPlayingIndex else { return [] }
        return Array(rows[nowPlayingIndex...])
    }

    /// Everything in `upcoming` except the now-playing row itself — what
    /// actually goes inside the scrollable `List`.
    private var remaining: [PlaylistDetailRow] {
        Array(upcoming.dropFirst())
    }

    var body: some View {
        NavigationStack {
            Group {
                if upcoming.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .background(DesignTokens.Color.background)
            .navigationTitle("Up next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(DesignTokens.Color.primaryText)
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            subtitleRow
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.xs)

            if let nowPlaying = upcoming.first {
                // Pinned, not part of the scrollable List below -- see this
                // file's own doc comment. `isImminent: true` on its own
                // connector matches Playlist Detail's convention (the
                // transition immediately after "now playing" is always the
                // imminent one) -- fixes a real off-by-one in the previous
                // version, which passed this to the *second* row instead.
                rowView(nowPlaying, isNowPlaying: true, isImminent: true, isLast: remaining.isEmpty)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.top, DesignTokens.Spacing.xs)
                    .background(DesignTokens.Color.background)
            }

            if remaining.isEmpty {
                Spacer()
                Text("Nothing else queued")
                    .font(.body)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                Spacer()
            } else {
                List {
                    Section {
                        ForEach(Array(remaining.enumerated()), id: \.element.id) { index, row in
                            rowView(row, isNowPlaying: false, isImminent: false, isLast: index == remaining.count - 1)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: DesignTokens.Spacing.md, bottom: 0, trailing: DesignTokens.Spacing.md))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// The confirmed design's own note on this screen's title: keep it
    /// plain and functional ("Up next" — instantly parseable), with the
    /// purpose reminder living one line down instead of replacing the title.
    private var subtitleRow: some View {
        Text("Blending seamlessly, in order.")
            .font(.footnote)
            .foregroundStyle(DesignTokens.Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text("Nothing queued")
                .font(.title2.weight(.semibold))
                .foregroundStyle(DesignTokens.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Row

    private func rowView(_ row: PlaylistDetailRow, isNowPlaying: Bool, isImminent: Bool, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                if isNowPlaying {
                    // Bars only animate while actually audible, not just
                    // "this is the now-playing slot" -- same 2026-08-14 fix
                    // as `PlaylistDetailView`/`MyMixesView` (paused sessions
                    // were incorrectly still showing animated bars).
                    if !playbackEngine.isPaused {
                        NowPlayingBarsView(color: DesignTokens.Color.primaryText, barWidth: 2.5, maxHeight: 12)
                            .frame(width: 20, alignment: .trailing)
                    } else {
                        Image(systemName: "pause.fill")
                            .font(.footnote)
                            .foregroundStyle(DesignTokens.Color.primaryText)
                            .frame(width: 20, alignment: .trailing)
                    }
                } else {
                    Spacer().frame(width: 20)
                }

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

                // Per the confirmed design, every row but "now playing" gets
                // its own "..." menu -- real actions deferred, see this
                // file's own doc comment.
                if !isNowPlaying {
                    Menu {
                        Button {} label: {
                            Label("Remove from this mix", systemImage: "minus.circle")
                        }
                        .disabled(true)
                        Button {} label: {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        .disabled(true)
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                            .frame(width: DesignTokens.Size.tapTargetMin, height: DesignTokens.Size.tapTargetMin)
                    }
                }
            }
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .padding(.horizontal, isNowPlaying ? DesignTokens.Spacing.xs : 0)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusSmall)
                    .fill(isNowPlaying ? DesignTokens.Color.surfaceTint : Color.clear)
            )

            if !isLast {
                connector(isImminent: isImminent)
            }
        }
    }

    /// Same teal/gray convention as Playlist Detail's own track-list
    /// connector — solid teal for the one imminent transition (now playing
    /// into the very next track), lighter gray further out (queued, not
    /// imminent).
    private func connector(isImminent: Bool) -> some View {
        Rectangle()
            .fill(isImminent ? DesignTokens.Color.primary : DesignTokens.Color.border)
            .frame(width: 2, height: DesignTokens.Spacing.md)
            .padding(.leading, 20 + DesignTokens.Spacing.sm)
    }
}

#Preview {
    QueueView(rows: [])
        .environmentObject(PlaybackEngine())
}
