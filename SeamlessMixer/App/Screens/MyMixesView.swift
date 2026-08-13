import SwiftUI
import PlaylistCore

/// The app's root screen — no tab bar, per CLAUDE.md's "Library / My Mixes"
/// judgment call (a single-section personal utility doesn't need one).
/// First real screen wired to `PlaylistCore`: shows the confirmed empty
/// state until a Source Selection -> Build Mix flow exists to create real
/// playlists (that flow is deliberately not built yet — this screen is the
/// first slice of the app target, not the whole loop at once).
///
/// Known, deliberate simplification: rows show `playlist.name` and
/// `playlist.mode.displayName` only, not the full auto-naming subtitle
/// ("Genre · Smooth jazz · Energy wave · 12 songs · 47 min") — that needs a
/// join against `playlist_sources` and `playlist_tracks`, which has no
/// caller to shape its API around yet (same reasoning `Sequencer.sequence`'s
/// doc comment gives for not returning an exclusion count). Revisit once
/// Source Selection exists and playlists have real sources to describe.
///
/// Rows are now tappable through to `PlaylistDetailView`, and the "..."
/// button opens the real `PlaylistOverflowSheet` (Favourite/Rename/Refresh/
/// Delete) — both previously missing, see `MixRow`'s own doc comment.
///
/// **CTA clarity fixed 2026-08-14**: the empty state already had a clear,
/// labeled "New mix" button, but once real playlists exist, the only way to
/// start a new one was the bare "+" glyph in the toolbar — real-device
/// feedback confirmed this reads as "add a playlist" rather than "build a
/// new mix" (a fair critique; Apple's own toolbar "+" affordances are
/// usually paired with a list-management context this app doesn't have).
/// Added a persistent, explicitly-labeled "Build Mix" bar at the bottom of
/// the non-empty list, matching how the empty state's own labeled button
/// already reads unambiguously. The toolbar "+" stays too, as a quick-access
/// shortcut, but is no longer the *only* way in.
struct MyMixesView: View {
    @ObservedObject var store: PlaylistStore

    var body: some View {
        NavigationStack {
            Group {
                if let error = store.loadError {
                    errorState(error)
                } else if store.playlists.isEmpty {
                    emptyState
                } else {
                    mixList
                }
            }
            .background(DesignTokens.Color.background)
            .navigationTitle("My Mixes")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: {}) {
                        Image(systemName: "gearshape")
                    }
                    .tint(DesignTokens.Color.primaryText)
                    NavigationLink {
                        SourceSelectionHubView(store: store)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(DesignTokens.Color.primaryText)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Spacer()
            Text("Build your first seamless mix")
                .font(.title2.weight(.semibold))
                .foregroundStyle(DesignTokens.Color.textPrimary)
            Text("Pick songs, a genre, an artist, or combine a few — we'll blend them into one continuous set.")
                .font(.body)
                .foregroundStyle(DesignTokens.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignTokens.Spacing.xl)
            NavigationLink {
                SourceSelectionHubView(store: store)
            } label: {
                Label("New mix", systemImage: "plus")
                    .frame(minHeight: DesignTokens.Size.buttonHeightStandard)
                    .padding(.horizontal, DesignTokens.Spacing.lg)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Color.primary)
            .foregroundStyle(DesignTokens.Color.onPrimary)
            .padding(.top, DesignTokens.Spacing.sm)
            Spacer()
            Spacer()
        }
        .padding(DesignTokens.Spacing.lg)
    }

    // MARK: - Error state

    private func errorState(_ message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(DesignTokens.Color.error)
            Text(message)
                .font(.body)
                .foregroundStyle(DesignTokens.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignTokens.Spacing.xl)
        }
    }

    // MARK: - Mix list

    private var mixList: some View {
        List {
            let favorites = store.playlists.filter(\.isFavorite)
            if !favorites.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            ForEach(favorites) { playlist in
                                FavoriteCard(playlist: playlist)
                            }
                        }
                        .padding(.vertical, DesignTokens.Spacing.xxs)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Favorites")
                }
            }

            Section {
                ForEach(store.playlists) { playlist in
                    MixRow(playlist: playlist, store: store)
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            // `.refreshable`'s closure type is `@Sendable () async -> Void`,
            // which does not automatically inherit this view's MainActor
            // isolation -- `await` makes the actor hop explicit and correct
            // either way (harmless if isolation was already inherited,
            // required if it wasn't), rather than relying on inference.
            await store.refresh()
        }
        .safeAreaInset(edge: .bottom) { buildMixBar }
    }

    /// The explicitly-labeled "Build Mix" entry point for when playlists
    /// already exist — see this file's own doc comment for why the bare
    /// toolbar "+" wasn't enough on its own.
    private var buildMixBar: some View {
        VStack(spacing: 0) {
            Divider()
            NavigationLink {
                SourceSelectionHubView(store: store)
            } label: {
                Label("Build Mix", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.Size.buttonHeightStandard)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Color.primary)
            .foregroundStyle(DesignTokens.Color.onPrimary)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
        .background(DesignTokens.Color.surface)
    }
}

/// One row in the main list — collage artwork placeholder (a rule-generated
/// mix has no single cover of its own, per the auto-generated-collage
/// pattern noted from the real Apple Music reference screens) + title +
/// mode + trailing overflow. Real per-track artwork compositing is future
/// work; this is a flat placeholder tile using the same corner radius token
/// real artwork will use later, so the layout doesn't shift once it lands.
///
/// **Two things wired this slice, both previously missing:** the row is
/// now a real `NavigationLink` to `PlaylistDetailView` — existing playlists
/// were unreachable from this screen before (only a freshly-built one,
/// landed on straight from Source Selection, had a path to Playlist
/// Detail). And the "..." button now presents the shared
/// `PlaylistOverflowSheet` instead of doing nothing. `.buttonStyle(.borderless)`
/// on the ellipsis is what keeps its tap from also triggering the row's
/// own navigation — the standard SwiftUI pattern for a secondary button
/// inside a `List` row that's also a `NavigationLink`.
private struct MixRow: View {
    let playlist: Playlist
    let store: PlaylistStore

    @State private var showOverflow = false

    var body: some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist, store: store)
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork)
                    .fill(DesignTokens.Color.surfaceTint)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: "music.note.list")
                            .foregroundStyle(DesignTokens.Color.primaryText)
                    )

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(playlist.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                    Text(playlist.mode.displayName)
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                }

                Spacer()

                if playlist.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(DesignTokens.Color.primary)
                        .font(.caption)
                }

                Button {
                    showOverflow = true
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .frame(width: DesignTokens.Size.tapTargetMin, height: DesignTokens.Size.tapTargetMin)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .listRowBackground(DesignTokens.Color.surface)
        .sheet(isPresented: $showOverflow) {
            PlaylistOverflowSheet(playlist: playlist, store: store)
        }
    }
}

private struct FavoriteCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork)
                .fill(DesignTokens.Color.surfaceTint)
                .frame(width: 120, height: 120)
                .overlay(
                    Image(systemName: "music.note.list")
                        .foregroundStyle(DesignTokens.Color.primaryText)
                )
            Text(playlist.name)
                .font(.footnote.weight(.medium))
                .foregroundStyle(DesignTokens.Color.textPrimary)
                .lineLimit(1)
        }
        .frame(width: 120)
        .padding(.horizontal, DesignTokens.Spacing.xs)
    }
}

#Preview {
    // `.environmentObject` needed here even though this screen never reads
    // `PlaybackEngine` itself -- Xcode Previews render the whole navigable
    // subtree, and tapping through to `PlaylistDetailView` (which does
    // require it, as an `@EnvironmentObject`) would otherwise crash in the
    // preview canvas the same way it would at runtime with no injection
    // anywhere in the view hierarchy.
    MyMixesView(store: PlaylistStore())
        .environmentObject(PlaybackEngine())
}
