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
                        SourceSelectionHubView()
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
                SourceSelectionHubView()
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
                    MixRow(playlist: playlist)
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
    }
}

/// One row in the main list — collage artwork placeholder (a rule-generated
/// mix has no single cover of its own, per the auto-generated-collage
/// pattern noted from the real Apple Music reference screens) + title +
/// mode + trailing overflow. Real per-track artwork compositing is future
/// work; this is a flat placeholder tile using the same corner radius token
/// real artwork will use later, so the layout doesn't shift once it lands.
private struct MixRow: View {
    let playlist: Playlist

    var body: some View {
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

            Button(action: {}) {
                Image(systemName: "ellipsis")
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .frame(width: DesignTokens.Size.tapTargetMin, height: DesignTokens.Size.tapTargetMin)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .listRowBackground(DesignTokens.Color.surface)
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
    MyMixesView(store: PlaylistStore())
}
