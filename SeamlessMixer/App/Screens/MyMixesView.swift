import SwiftUI
import UIKit
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
/// already reads unambiguously.
///
/// **Toolbar "+" removed entirely, same day, on further real-device
/// feedback**: keeping it "as a quick-access shortcut" turned out to just
/// be a second, differently-labeled path to the exact same screen, and
/// tapping it with nothing selected left Build Mix disabled there with no
/// clear next step — genuinely more confusing than not having the shortcut
/// at all. One unambiguous entry point now, not two.
///
/// **Owns the entire navigation stack via a single `path`, 2026-08-14 — a
/// real bug fix, the second one in this area, not a refactor for its own
/// sake.** The first attempt at the navigation-loophole fix (Hub hands the
/// built playlist up via `handleBuilt`, calls its own `dismiss()`, while
/// this screen separately set a `navigateToPlaylist` item to push Playlist
/// Detail) genuinely closed the original loophole, but introduced a new,
/// real race: two independent navigation-stack mutations — a child popping
/// *itself* via `dismiss()`, and a parent pushing a *new* destination via a
/// state change — fired in the same tick from two different views, with no
/// guaranteed ordering between them. Real-device testing caught this
/// directly: Build Mix would briefly flash My Mixes, then show a blank
/// screen "probably on top of the Selection Hub screen," recoverable only
/// by tapping back — the mix itself was always saved correctly (visible
/// once you navigated back), so this was a pure UI/navigation-stack glitch,
/// not a data bug.
///
/// Fixed by giving this screen ONE `path: [Destination]`, with *every* push
/// — Hub included — flowing through it, rather than mixing a plain
/// `NavigationLink { Hub() }` (opaque, not part of any path) with a
/// separate item-driven push for Playlist Detail. `handleBuilt` now
/// replaces the whole path in a single atomic assignment
/// (`path = [.playlist(playlist)]`), which SwiftUI resolves as one coherent
/// transition (pop Hub, push Playlist Detail) instead of two separate,
/// racing operations — `SourceSelectionHubView` no longer needs to (and no
/// longer does) call `dismiss()` on itself at all.
struct MyMixesView: View {
    @ObservedObject var store: PlaylistStore

    /// Every screen reachable from here via a *managed* push. `.hub` and
    /// `.playlist` are the only two cases because those are the only two
    /// pushes that ever need to be driven by this screen's own state
    /// (`MixRow`'s row-tap push to Playlist Detail stays a plain, opaque
    /// `NavigationLink` — see its own doc comment — since nothing needs to
    /// coordinate around it).
    ///
    /// **`.hub` carries a `UUID`, added 2026-08-17 — a real bug, not
    /// defensive styling.** Andy found that selections made in one "New
    /// Seamless Mix" session (particularly ones picked via the Hub's
    /// search results — see `SourceSelectionViewModel.performSearch`)
    /// silently carried over into a *later, separate* Build Mix session he
    /// never re-selected: "these songs were also used for the next build
    /// without me knowing they were still selected." Root cause: `.hub`
    /// previously had no associated value, so every push of it was
    /// `Hashable`-equal to every other push. `NavigationStack`'s
    /// path-based destination matching can treat two equal path values as
    /// the *same* logical destination rather than a fresh one — a real,
    /// documented SwiftUI behavior, not a hypothesis — which meant
    /// `SourceSelectionHubView`'s `@StateObject`s (`viewModel`,
    /// `mixBuilder`) were never guaranteed to reinitialize on a second
    /// visit; the same `SourceSelectionViewModel.selectedSources` array
    /// could persist across what looked, from the UI, like a completely
    /// new session. A fresh `UUID` per push makes every `.hub` value
    /// genuinely distinct, forcing a real, fresh destination — and a
    /// fresh `@StateObject` — every time.
    private enum Destination: Hashable {
        case hub(UUID)
        case playlist(Playlist)
    }

    @State private var path: [Destination] = []
    /// The just-built playlist's DRM-exclusion message, if any -- handed to
    /// `PlaylistDetailView` at push time (see `navigationDestination` below)
    /// rather than shown as an alert *here*. See `handleBuilt`'s doc comment
    /// for why this moved 2026-08-14.
    @State private var pendingExclusionMessage: String?
    /// **Added 2026-08-15** — the gear icon was a no-op button since this
    /// screen was first built; now opens `SettingsView`'s first real slice
    /// (just the version/build number, per Andy's direct request).
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
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
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .hub:
                    SourceSelectionHubView(store: store, onBuilt: handleBuilt)
                case .playlist(let playlist):
                    PlaylistDetailView(playlist: playlist, store: store, initialExclusionMessage: pendingExclusionMessage)
                }
            }
            // `switch destination` above matches on the case alone (the
            // associated UUID is irrelevant to which screen to show), so
            // Swift lets the pattern `case .hub` bind without needing
            // `case .hub(_):` explicitly.
            .toolbar {
                // The toolbar "+" was removed 2026-08-14 -- real-device
                // feedback pointed out it was genuinely redundant with the
                // labeled "Build Mix" bar below (both led to the same
                // screen), and worse, tapping it with nothing selected left
                // Build Mix disabled there with no obvious way forward,
                // which read as more confusing than having no shortcut at
                // all. One clear, labeled entry point beats two differently
                // -labeled ones to the same place.
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .tint(DesignTokens.Color.primaryText)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(store: store)
            }
        }
    }

    /// Receives a just-built playlist (and any DRM-exclusion message) from
    /// `SourceSelectionHubView`. Replaces `path` outright rather than
    /// appending to it — see this file's own doc comment for why a single
    /// atomic replacement (as opposed to the Hub popping itself while this
    /// screen separately pushes something new) is what actually closes the
    /// navigation race, not just the loophole it was originally meant to fix.
    ///
    /// **Exclusion alert lives on `PlaylistDetailView` itself, not here** —
    /// a separate, earlier fix for a related but different race (this
    /// screen presenting an `.alert(...)` and pushing a navigation
    /// destination from the same state update). `pendingExclusionMessage`
    /// is still set here since `PlaylistDetailView` needs the value, just
    /// not presented here.
    private func handleBuilt(playlist: Playlist, exclusionMessage: String?) {
        pendingExclusionMessage = exclusionMessage
        path = [.playlist(playlist)]
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
            NavigationLink(value: Destination.hub(UUID())) {
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
                                FavoriteCard(playlist: playlist, store: store)
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
            NavigationLink(value: Destination.hub(UUID())) {
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
///
/// **Now-playing indicator added 2026-08-14** — real-device feedback
/// (repeated across several rounds) flagged that this screen gave no clue
/// which mix, if any, was currently playing — finding it was "trial and
/// error." A real, persistent mini-player is still the confirmed design's
/// complete answer and remains unbuilt, but this is a small, immediate,
/// scoped piece of the same problem: whichever row's playlist matches
/// `PlaybackEngine.currentPlaylistID` shows the real animated
/// `NowPlayingBarsView` in place of the flat artwork-placeholder icon —
/// tapping that row already leads to Playlist Detail, whose own Play button
/// already resumes (not restarts) an in-progress session, so this closes a
/// real practical gap even without the full mini-player.
///
/// **Stays a plain, opaque `NavigationLink { PlaylistDetailView(...) }`,
/// deliberately not converted to `MyMixesView`'s managed `path`** — unlike
/// the Hub/Build-Mix push (see that file's own doc comment on the
/// navigation race that fix closed), tapping an existing row is a single,
/// simple, user-initiated push with nothing else racing it, so there's no
/// reason to route it through `path` too.
///
/// **Ellipsis trailing padding added 2026-08-15** — real-device feedback:
/// the "..." button's tap target sat right up against `List`'s own
/// system-provided disclosure chevron (added automatically for any
/// `NavigationLink` row), with almost no visual or functional gap between
/// them — Andy reported landing on the ellipsis instead of the chevron
/// "almost 90% of the time" when trying to open Playlist Detail. Adding
/// breathing room after the button doesn't change either tap target's own
/// size, just separates them enough that a tap near the row's trailing
/// edge reliably lands on the chevron instead. **Widened again the next
/// day** (`Spacing.xs` -> `Spacing.sm`) — Andy confirmed the mis-tap itself
/// was fixed but asked for more room, comparing it to the roomier feel of
/// `PlaylistDetailView`'s per-track "..." menu. Not a like-for-like fix —
/// that row has no competing chevron to crowd against in the first place,
/// since it isn't itself a `NavigationLink` — but more trailing space here
/// is the real, actionable part of the ask regardless.
private struct MixRow: View {
    let playlist: Playlist
    let store: PlaylistStore

    @EnvironmentObject private var playbackEngine: PlaybackEngine
    @State private var showOverflow = false

    /// `!playbackEngine.isPaused` added 2026-08-14 — a real bug: this used
    /// to key off `isPlaying` alone, which stays true while paused (by
    /// design, elsewhere), so a paused mix's row kept showing animated bars
    /// as if it were still audibly playing.
    private var isPlaying: Bool {
        playbackEngine.isPlaying && !playbackEngine.isPaused && playlist.id != nil && playbackEngine.currentPlaylistID == playlist.id
    }

    /// **Added 2026-08-20** — up to 4 distinct-album images for this row's
    /// thumbnail, per Andy's request to reuse Playlist Detail's new
    /// collage here too. Reads from `PlaylistStore`'s batch-loaded
    /// dictionary (see its own doc comment for why this isn't a per-row
    /// query) rather than resolving anything itself.
    private var collageImages: [UIImage] {
        guard let id = playlist.id else { return [] }
        return store.collagesByPlaylistID[id] ?? []
    }

    var body: some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist, store: store)
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                artworkTile

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
                    // **Reverted 2026-08-18** -- briefly removed this circle
                    // in the same round, on a misreading of Andy's report.
                    // He corrected it directly: this one gray circle is the
                    // correct, intended look and was never the problem --
                    // the actual bug is that `PlaylistDetailView`'s "..."
                    // (a `Menu`) renders an *extra*, unwanted gray layer
                    // from iOS's own default `Menu` chrome, stacked on top
                    // of a background matching this one, and Now Playing's
                    // transport buttons have the same kind of unwanted
                    // extra layer from default `Button` chrome. Both are
                    // fixed at their own source now (`.menuStyle
                    // (.borderlessButton)` / `.buttonStyle(.plain)`) rather
                    // than by touching this correct one.
                    Image(systemName: "ellipsis")
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(DesignTokens.Color.surfaceTint))
                        .frame(width: DesignTokens.Size.tapTargetMin, height: DesignTokens.Size.tapTargetMin)
                }
                .buttonStyle(.borderless)
                .padding(.trailing, DesignTokens.Spacing.sm)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .listRowBackground(DesignTokens.Color.surface)
        .sheet(isPresented: $showOverflow) {
            PlaylistOverflowSheet(playlist: playlist, store: store)
        }
    }

    /// **Added 2026-08-20.** Andy asked for the collage to replace this
    /// row's flat placeholder, but also flagged a real design question
    /// directly: once a real thumbnail is there, how does "this mix is
    /// playing" stay visible without just hiding the artwork behind the
    /// bars indicator the way the flat-icon version did? His own two
    /// suggestions were to swap the thumbnail out for the bars while
    /// playing, or show the bars *on* the thumbnail in a visible color —
    /// he explicitly left the final call to "whichever process is
    /// best." This does the latter: the collage stays visible underneath
    /// a darkening scrim (so the row keeps its identity at a glance even
    /// while playing, unlike swapping it out), with the bars rendered in
    /// white on top -- guaranteed visible regardless of the collage's own
    /// colors, rather than risking `DesignTokens.Color.primaryText`
    /// blending into a similarly-dark album cover.
    private var artworkTile: some View {
        ZStack {
            if collageImages.isEmpty {
                RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork)
                    .fill(DesignTokens.Color.surfaceTint)
                Image(systemName: "music.note.list")
                    .foregroundStyle(DesignTokens.Color.primaryText)
            } else {
                CollageArtworkView(images: collageImages)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork))
            }

            if isPlaying {
                RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork)
                    .fill(Color.black.opacity(0.35))
                NowPlayingBarsView(color: .white, maxHeight: 18)
            }
        }
        .frame(width: 56, height: 56)
    }
}

private struct FavoriteCard: View {
    let playlist: Playlist
    let store: PlaylistStore

    /// Same collage lookup `MixRow` uses -- see `PlaylistStore
    /// .collagesByPlaylistID`'s own doc comment. No now-playing overlay
    /// here (unlike `MixRow`) -- this card never tracked playback state to
    /// begin with, and Andy's request was specifically about the main
    /// list's thumbnails, not this row.
    private var collageImages: [UIImage] {
        guard let id = playlist.id else { return [] }
        return store.collagesByPlaylistID[id] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Group {
                if collageImages.isEmpty {
                    RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork)
                        .fill(DesignTokens.Color.surfaceTint)
                        .overlay(
                            Image(systemName: "music.note.list")
                                .foregroundStyle(DesignTokens.Color.primaryText)
                        )
                } else {
                    CollageArtworkView(images: collageImages)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork))
                }
            }
            .frame(width: 120, height: 120)
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
