import SwiftUI
import PlaylistCore

/// Screen 1 of the confirmed two-screen Source Selection design (see
/// CLAUDE.md's "Source Selection (revised, confirmed)"): a compact hub —
/// pinned "Use your whole library" row, four category rows (Playlists/
/// Genres/Artists/Albums), the mode picker, and a sticky "Build Mix" bar.
///
/// **Global search added 2026-08-15** — the confirmed design always
/// specified one search field here (not per-category), but it was never
/// actually built until real-device feedback from an event surfaced the
/// gap directly. See `SourceSelectionViewModel.performSearch`'s own doc
/// comment for the full reasoning and the search results list below.
///
/// **All five category rows are now real** (Genres, Playlists, Artists,
/// Albums, and Songs — `SongPickerView`, added 2026-08-16, was the last,
/// closing out ADR-7's original five confirmed source types), each with
/// selection state flowing back into this Hub's chip row and live
/// "N selected" counts. **"Build Mix" is wired for real** (see
/// `MixBuilder`) and now resolves any combination of genre/playlist/
/// artist/album/song selections — only "whole library" still shows an
/// error explaining it isn't supported yet, per the reasoning in
/// `MixBuilder`'s own doc comment.
///
/// **"Whole library" gained real exclusion support 2026-09-09, per Andy's
/// direct request.** The category rows used to gray out entirely the
/// moment "Use your whole library" was on — a pick made in that mode now
/// means *leave this out of* the whole library instead, so those rows stay
/// fully usable; `categoryRow`'s badge and `chipRow`'s chips both switch to
/// a distinct `warning`-tinted "excluded" look in that mode so the two
/// meanings (include vs. exclude) never read as identical. See
/// `SourceSelectionViewModel.useWholeLibrary`'s own doc comment for the
/// underlying selection-state rule, and `MixBuilder.resolveWholeLibraryPool`
/// for how the exclusion actually gets applied at Build Mix/Refresh time.
///
/// **Navigation on success changed twice, both real bugs, not style
/// choices.** First (2026-08-14): this used to push `PlaylistDetailView`
/// directly from *within* this Hub via `.navigationDestination(item:)`,
/// landing it on top of the Hub in `MyMixesView`'s shared `NavigationStack`
/// — My Mixes → Hub → Playlist Detail. Tapping back from Playlist Detail
/// then returned to this same (now-stale) Hub instead of My Mixes, a real,
/// repeatable loophole real-device feedback caught. Fixed by handing the
/// built playlist *up* to `MyMixesView` via `onBuilt` and calling
/// `dismiss()` on this Hub right after.
///
/// **Second (2026-08-15): that `dismiss()` call itself is gone now, and
/// that's also a real bug fix, not a cleanup.** Calling `dismiss()` here
/// while `MyMixesView` *separately* mutated its own state to push Playlist
/// Detail — two independent navigation-stack changes from two different
/// views, in the same tick — could race each other in SwiftUI's
/// `NavigationStack`. Real-device testing caught it directly: Build Mix
/// would briefly flash My Mixes, then a blank screen, recoverable only by
/// tapping back (the mix itself was always saved correctly underneath).
/// `MyMixesView` now owns a single managed navigation `path` covering both
/// this Hub's own push *and* the Playlist Detail push, so replacing that
/// path in one atomic step (pop Hub, push Playlist Detail) is enough on its
/// own — this Hub calling `dismiss()` on top of that would just reintroduce
/// the same race from the other direction. See `MyMixesView`'s own doc
/// comment for the full diagnosis.
struct SourceSelectionHubView: View {
    let store: PlaylistStore
    /// Called once, right after a successful build, with the new playlist,
    /// any DRM-exclusion message, the actual excluded tracks themselves
    /// (**added 2026-08-21**, per Andy's direct request), and
    /// (**added 2026-09-05**) any duplicate-song groups found — see
    /// `DuplicateFilter`'s own doc comment. See this file's own doc comment
    /// for why navigation moved up to the caller (`MyMixesView`) instead of
    /// happening here.
    let onBuilt: (Playlist, String?, [Track], [[Track]]) -> Void

    @StateObject private var viewModel = SourceSelectionViewModel()
    @StateObject private var mixBuilder = MixBuilder()
    @Environment(\.dismiss) private var dismiss

    /// **Added 2026-08-22**, per Andy's direct report: "If a mix is being
    /// built and some songs, artists, albums etc have been selected
    /// already and I click on the arrow < to go to the previous screen,
    /// there should be a warning window... There are many a time I have
    /// made a choice only to lose it because I clicked on that arrow."
    /// Guards the back navigation behind a confirmation only when there's
    /// actually something to lose (`viewModel.hasSelection`) -- backing out
    /// of an empty Hub still needs no confirmation at all.
    ///
    /// **Known gap, flagged not silently missing**: this only covers a tap
    /// on the custom back chevron below. iOS's own edge-swipe-to-go-back
    /// gesture isn't intercepted by this — `.navigationBarBackButtonHidden`
    /// hides the button but doesn't disable that gesture, and reliably
    /// blocking/confirming it needs a lower-level UIKit hook
    /// (`UINavigationControllerDelegate`) that's meaningfully riskier to
    /// get right blind than this button-only fix. Revisit if swiping past
    /// a real selection turns out to be a real, felt gap in practice.
    @State private var showDiscardConfirmation = false

    /// Caps a single chip's label width in `chipRow`, below — see that
    /// property's own doc comment for the real screen-misalignment bug this
    /// fixes. Roughly a third of a standard iPhone's content width, wide
    /// enough to show a real name without truncating almost everything.
    private let chipMaxWidth: CGFloat = 160

    var body: some View {
        Group {
            switch viewModel.authorizationStatus {
            case .authorized:
                content
            case .notDetermined:
                ProgressView()
            default:
                permissionDenied
            }
        }
        .background(DesignTokens.Color.background)
        .navigationTitle("New Seamless Mix")
        .navigationBarTitleDisplayMode(.inline)
        // **Custom back button, added 2026-08-22** -- the default system
        // back button can't be intercepted with a confirmation, so it's
        // replaced with one that checks `viewModel.hasSelection` first.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    if viewModel.hasSelection {
                        showDiscardConfirmation = true
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
        }
        .alert("Discard this mix?", isPresented: $showDiscardConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("OK", role: .destructive) { dismiss() }
        } message: {
            Text("Going back will lose everything selected for this mix so far.")
        }
        .onAppear {
            // **Added 2026-09-07** — `viewModel` had no database access at
            // all before Favourites needed one (see `SourceSelectionViewModel
            // .attach(store:)`'s own doc comment); must run before
            // `requestAccessAndLoadCounts()` so the Favourites count loads
            // correctly the first time too, not just on a later refresh.
            viewModel.attach(store: store)
            viewModel.requestAccessAndLoadCounts()
        }
        .overlay {
            if mixBuilder.isBuilding {
                buildingOverlay
            }
        }
        .alert("Couldn't build mix", isPresented: buildErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mixBuilder.buildError ?? "")
        }
    }

    private var buildErrorBinding: Binding<Bool> {
        Binding(
            get: { mixBuilder.buildError != nil },
            set: { if !$0 { mixBuilder.buildError = nil } }
        )
    }

    private var buildingOverlay: some View {
        ZStack {
            DesignTokens.Color.background.opacity(0.9).ignoresSafeArea()
            VStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView()
                    .tint(DesignTokens.Color.primary)
                Text(mixBuilder.progressText)
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
        }
    }

    /// **Fixed 2026-08-20 — was `.searchable()`, the exact same real bug
    /// already found and fixed for the five category pickers (see
    /// `InlineSearchField`'s own doc comment for the full mechanism):
    /// `.searchable()` hands the nav bar to `UISearchController` the
    /// moment the field becomes active, hiding the back button.** Andy hit
    /// this here too: "Search field is still down below on the screen,
    /// making it impossible to get back to previous screen like before.
    /// Should be placed at the top for consistency." The category pickers
    /// were fixed for this same reason back in Testing (38); the Hub's own
    /// global search field was overlooked at the time since it's a
    /// different call site. Replaced with the same `InlineSearchField`,
    /// pinned above *both* `hubContent` and `searchResultsList` (not
    /// duplicated inside each) so it stays visible and at the top
    /// regardless of which one is showing below it.
    private var content: some View {
        VStack(spacing: 0) {
            InlineSearchField(text: $viewModel.searchText, prompt: "Search songs, artists, albums...")
            if viewModel.searchText.isEmpty {
                hubContent
            } else {
                searchResultsList
            }
        }
        .onChange(of: viewModel.searchText) { _, _ in viewModel.performSearch() }
    }

    private var hubContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                allSongsRow
                categoryRows
                chipRow
                modePicker
                durationControl
                // Bottom padding so the sticky Build Mix bar doesn't cover
                // the last row.
                Color.clear.frame(height: DesignTokens.Size.buttonHeightStandard + DesignTokens.Spacing.lg)
            }
            .padding(DesignTokens.Spacing.md)
        }
        .safeAreaInset(edge: .bottom) { buildMixBar }
    }

    // MARK: - Search results

    /// Shown in place of the normal Hub content while `searchText` is
    /// non-empty. Each row is directly selectable — tapping toggles that
    /// source the same way a category picker's checkbox does, so a song
    /// request can go straight from "search" to "selected" without a
    /// detour through a category screen.
    ///
    /// **`buildMixBar` attached here too, 2026-08-17 — a real bug, not a
    /// missing nicety.** Andy: "you cannot add the songs to build a mix,
    /// because the arrow at the top goes missing as soon as you start
    /// typing in the search field... managed to get to the arrow by
    /// cancelling the search." Root cause: `buildMixBar` was only ever
    /// attached to `hubContent` (via its own `.safeAreaInset`) — while
    /// `searchText` was non-empty, `content` showed this view *instead*,
    /// which had no Build Mix affordance anywhere, not even after
    /// dismissing the keyboard. Search results select correctly, but
    /// there was never a way to actually build with them short of
    /// clearing the search text first (losing the search context) to get
    /// back to `hubContent`. Now the same sticky bar is reachable directly
    /// from the search results list too.
    private var searchResultsList: some View {
        List {
            if viewModel.searchResults.isEmpty {
                Text("No matches for “\(viewModel.searchText)”")
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(viewModel.searchResults) { result in
                    searchResultRow(result)
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) { buildMixBar }
    }

    private func searchResultRow(_ result: SourceSelectionViewModel.SearchResult) -> some View {
        let selected = viewModel.isSelected(result.source)
        return Button {
            viewModel.toggle(result.source)
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? DesignTokens.Color.primary : DesignTokens.Color.textDisabled)
                Image(systemName: icon(for: result.source.type))
                    .foregroundStyle(DesignTokens.Color.primaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.source.label)
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                    Text(result.matchDetail ?? typeLabel(for: result.source.type))
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func icon(for type: SourceType) -> String {
        switch type {
        case .playlist: return "music.note.list"
        case .genre: return "guitars"
        case .artist: return "person.wave.2"
        case .album: return "square.stack"
        case .songs: return "music.note"
        // Never actually shown here -- the Hub's global search only
        // surfaces song/artist/album/genre/playlist matches (per the
        // confirmed design, "Whole library" is a standalone pinned row,
        // not a search-result type) -- but needed for this switch to stay
        // exhaustive now that `.wholeLibrary` is a real `SourceType` case.
        case .wholeLibrary: return "books.vertical"
        // Never actually shown here either (same reasoning as `.wholeLibrary`
        // above) — Favourites is a standalone pinned row, not a search-
        // result type — but needed to keep this switch exhaustive.
        case .favoriteSongs: return "star.fill"
        // Never shown here either — a `CustomPlaylist` isn't a Hub search-
        // result type, it's picked from the merged Playlists picker (see
        // `PlaylistPickerView`) — but needed to keep this switch exhaustive,
        // per every other never-searched case above. Reuses the same icon
        // as a real Apple Music playlist; the two are visually
        // differentiated by the "SM" badge on the picker's own cells, not
        // by a different icon here.
        case .customPlaylist: return "music.note.list"
        }
    }

    private func typeLabel(for type: SourceType) -> String {
        switch type {
        case .playlist: return "Playlist"
        case .genre: return "Genre"
        case .artist: return "Artist"
        case .album: return "Album"
        case .songs: return "Song"
        case .wholeLibrary: return "Library"
        case .favoriteSongs: return "Favourites"
        case .customPlaylist: return "Playlist"
        }
    }

    // MARK: - Rows

    /// **Subtitle added 2026-09-09**, alongside the category rows no longer
    /// graying out below — see `categoryRows`' own doc comment for the full
    /// reasoning. This is the row where that mode switch is actually
    /// toggled, so it's the natural place to state plainly what picking
    /// something else now means while it's active.
    private var allSongsRow: some View {
        Button {
            viewModel.useWholeLibrary.toggle()
        } label: {
            HStack {
                Image(systemName: "music.note.house")
                    .font(.system(size: DesignTokens.Size.iconMedium))
                    .foregroundStyle(DesignTokens.Color.primaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use your whole library")
                        .font(.body.weight(.medium))
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                    if viewModel.useWholeLibrary {
                        Text("Picks below now exclude — leave a genre, artist, etc. out of the mix.")
                            .font(.caption2)
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                    }
                }
                Spacer()
                if viewModel.useWholeLibrary {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignTokens.Color.primary)
                }
            }
            .padding(DesignTokens.Spacing.sm)
            .background(DesignTokens.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium)
                    .strokeBorder(DesignTokens.Color.border, lineWidth: DesignTokens.Size.borderWidthStandard)
            )
        }
        .buttonStyle(.plain)
    }

    /// **Revised 2026-09-07 (Testing 65 / CLAUDE.md 0.25.71) — from a pinned
    /// toggle row into a real category picker, matching Andy's own direct
    /// clarification.** Batch 1's original version was a single opaque
    /// toggle-the-whole-bucket row (mirroring "Use your whole library"'s own
    /// shape) — you could select "all favourites" as one block, but never
    /// see which songs were actually in it. Andy: "I was expecting... when
    /// I declare a song as a favourite, that these 'songs' populate the
    /// Favourites category in the SelectionHub so I can 1. view the songs
    /// and 2. select them" — the same real, individually-browsable behavior
    /// every other category row already has. This now pushes to
    /// `FavoriteSongsPickerView` (mirrors `SongPickerView`'s shape/pattern
    /// exactly, filtered to `tracks.is_favorite`) via the shared
    /// `categoryRow` helper below, same as Playlists/Genres/Artists/Albums/
    /// Songs.
    ///
    /// **`SourceType.favoriteSongs` (Batch 1's bulk-bucket source type) is
    /// deliberately left in place but no longer constructed anywhere** —
    /// `FavoriteSongsPickerView`'s individual checkboxes use the same
    /// `.songs`-typed source `SongPickerView` already does (a favourited
    /// song picked here is indistinguishable from the same song picked via
    /// the plain Songs picker, which already has full, tested resolve/
    /// persist/Refresh support — no new source-type machinery needed).
    /// Removing `.favoriteSongs` outright felt like more churn than value
    /// this round: it's tested, harmless, and any playlist already saved
    /// against it during Batch 1 testing still Refreshes correctly via
    /// `MixBuilder.selectedSource(from:)`'s existing case. Parked dormant,
    /// not deleted — revisit if a real "select every current favourite in
    /// one tap, dynamically" need ever surfaces.
    ///
    /// **Known, accepted trade-off**: because both this row and the plain
    /// Songs row now share the `.songs` source type for their individual
    /// picks, `categoryRow`'s "N selected" badge below reflects the
    /// combined total of songs picked via *either* screen, not just this
    /// one — a song is either selected or it isn't, regardless of which
    /// browsing screen it was checked off in, so this is read as an honest
    /// reflection of shared state, not a bug.
    /// **No longer grayed out while "whole library" is active, 2026-09-09,
    /// per Andy's direct request.** They used to be fully disabled the
    /// moment `useWholeLibrary` turned on, since combining "everything"
    /// with more inclusions was redundant — but a pick made in that mode now
    /// means *exclude*, not *include* ("there are 2 ways of selecting
    /// things... selecting everything and excluding some... the faster way
    /// will be better option depending on the goal"), a genuinely useful
    /// thing to do, so disabling them no longer made sense. See
    /// `allSongsRow`'s own new subtitle for where that mode switch is
    /// explained, and `categoryRow`'s own doc comment for how each row's
    /// badge communicates it too.
    private var categoryRows: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            // **`selectedCountOverride` added 2026-09-08 (Testing 67) — a
            // real bug fix, not the documented trade-off above.** This row
            // and the plain Songs row both pick individual songs via the
            // same `.songs` source type, so the generic `selectedCount(for:)`
            // this row used to rely on (like every other row) reflects the
            // *combined* total picked via either screen — accurate for the
            // Songs row, but wrong here: Andy picked his only 4 favourites
            // via this row, then 2 more (non-favourite) songs via the plain
            // Songs picker, and both rows showed "6 selected," implying all
            // 6 were favourites. `selectedFavoriteSongsCount` counts only
            // the selections that are genuinely favourited tracks.
            categoryRow(
                title: "Favourites", icon: "star.fill", count: viewModel.favoriteSongsCount, type: .songs,
                selectedCountOverride: viewModel.selectedFavoriteSongsCount
            ) {
                FavoriteSongsPickerView(viewModel: viewModel, store: store)
            }
            // **Badge count widened 2026-09-07 (Batch 2)**: `PlaylistPickerView`
            // now also picks `.customPlaylist`-typed sources (native, "SM"-
            // badged playlists merged into the same grid) — this row's own
            // "N selected" badge needs to reflect both, not just `.playlist`
            // picks, or a selected custom playlist would silently show as
            // "0 selected" here despite genuinely being part of the pool.
            categoryRow(
                title: "Playlists", icon: "music.note.list", count: viewModel.playlistCount, type: .playlist,
                additionalSelectedCount: viewModel.selectedCount(for: .customPlaylist)
            ) {
                PlaylistPickerView(viewModel: viewModel, store: store)
            }
            categoryRow(title: "Genres", icon: "guitars", count: viewModel.genreCount, type: .genre) {
                GenrePickerView(viewModel: viewModel)
            }
            categoryRow(title: "Artists", icon: "person.wave.2", count: viewModel.artistCount, type: .artist) {
                ArtistPickerView(viewModel: viewModel)
            }
            categoryRow(title: "Albums", icon: "square.stack", count: viewModel.albumCount, type: .album) {
                AlbumPickerView(viewModel: viewModel)
            }
            // Fifth and last of the confirmed category rows (per ADR-7's
            // five source types) -- added 2026-08-16, closing the gap
            // CLAUDE.md's 0.24.0 entry first flagged: "Songs" was always
            // meant to be its own individual-song-browsing picker, not just
            // the internal label the separate "whole library" toggle
            // borrowed.
            categoryRow(title: "Songs", icon: "music.note", count: viewModel.songCount, type: .songs) {
                SongPickerView(viewModel: viewModel)
            }
        }
    }

    /// - Parameter type: which `SourceType` this row represents, used only
    ///   to compute the live "N selected" badge from `viewModel.selectedSources`
    ///   — the row's own picked-ness has no other bearing on navigation.
    /// - Parameter additionalSelectedCount: **added 2026-09-07** — folded
    ///   into the same badge for a row whose picker surfaces more than one
    ///   `SourceType` (only the Playlists row, so far — see its own call
    ///   site). Defaults to 0, a no-op for every other row.
    /// - Parameter selectedCountOverride: **added 2026-09-08** — when
    ///   given, replaces the generic `type`-based count entirely rather
    ///   than adding to it (unlike `additionalSelectedCount` above). Only
    ///   the Favourites row uses this so far — see its own call site for
    ///   why the generic per-`type` count is actively wrong there, not just
    ///   incomplete.
    ///
    /// **Badge reads "N excluded" in `warning`-colored text while "whole
    /// library" is active, 2026-09-09** — same picks, same count, different
    /// meaning depending on the Hub's current mode (see `categoryRows`' own
    /// doc comment); the wording/color change is what keeps that mode
    /// visible at a glance on every row, not just the pinned one where it's
    /// toggled.
    private func categoryRow<Destination: View>(
        title: String, icon: String, count: Int, type: SourceType, additionalSelectedCount: Int = 0,
        selectedCountOverride: Int? = nil,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        let selectedCount = selectedCountOverride ?? (viewModel.selectedCount(for: type) + additionalSelectedCount)
        let isExclusionMode = viewModel.useWholeLibrary
        return NavigationLink {
            destination()
        } label: {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: DesignTokens.Size.iconMedium))
                    .foregroundStyle(DesignTokens.Color.primaryText)
                Text(title)
                    .font(.body)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                Spacer()
                Text(selectedCount > 0 ? "\(selectedCount) \(isExclusionMode ? "excluded" : "selected")" : "\(count)")
                    .font(.footnote)
                    .foregroundStyle(
                        selectedCount > 0
                            ? (isExclusionMode ? DesignTokens.Color.warning : DesignTokens.Color.primaryText)
                            : DesignTokens.Color.textSecondary
                    )
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
            .padding(DesignTokens.Spacing.sm)
            .background(DesignTokens.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chip row

    /// "How do I see what I'm combining" across categories, per the
    /// confirmed design — a row of removable chips, populated live as
    /// checkboxes are ticked on any of the four category pickers.
    ///
    /// **Changed from a horizontal `ScrollView` to `FlowLayout` 2026-08-15**
    /// (real bug, not a style tweak — see `FlowLayout.swift`'s own doc
    /// comment): a horizontal scroller silently cut off every chip past one
    /// screen-width with no visible cue more existed, which is exactly what
    /// Andy hit selecting 4 genres + 2 albums. Wrapping onto additional rows
    /// means the chip row grows downward instead, so every current
    /// selection is visible without an extra gesture.
    ///
    /// **Chip label width capped, same day, after real-device testing found
    /// the whole Hub screen misaligning horizontally once wrapping was
    /// live.** Root cause: a `SelectedSource.label` can legitimately be very
    /// long (a compilation/collaboration credit like "George Benson, Al
    /// Jarreau & Herbie Hancock" is a real artist name Andy hit, not an edge
    /// case) — an uncapped `Text` reports its full, unclipped intrinsic
    /// width to the layout system regardless of the screen's actual width,
    /// and `FlowLayout` (correctly) sizes each row to fit whatever its
    /// children report, so one long chip could make a whole row — and
    /// therefore the whole screen's content width — wider than the device,
    /// the same class of bug already fixed for `NowPlayingView`'s
    /// `MarqueeText` overflow. Capping each chip to `chipMaxWidth` with
    /// `.lineLimit(1)`/`.truncationMode(.tail)` means a long label truncates
    /// with an ellipsis instead of ever reporting an oversized width.
    /// **Exclusion styling added 2026-09-09** — a chip means something
    /// different depending on the Hub's current mode (see `categoryRows`'
    /// own doc comment), and this row is exactly where that ambiguity would
    /// otherwise be most visible/dangerous (a "Christmas" chip meaning
    /// "included" one session and "excluded" the next, rendered identically
    /// either way). A leading minus sign plus the same `warning` tint
    /// `categoryRow`'s own badge uses keeps the two readings from ever
    /// looking the same.
    @ViewBuilder
    private var chipRow: some View {
        if !viewModel.selectedSources.isEmpty {
            let isExclusionMode = viewModel.useWholeLibrary
            FlowLayout(spacing: DesignTokens.Spacing.xs) {
                ForEach(viewModel.selectedSources) { source in
                    HStack(spacing: DesignTokens.Spacing.xxs) {
                        Text(isExclusionMode ? "\u{2212} \(source.label)" : source.label)
                            .font(.footnote)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: chipMaxWidth, alignment: .leading)
                        Button {
                            viewModel.toggle(source)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.footnote)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.vertical, DesignTokens.Spacing.xxs)
                    .background(isExclusionMode ? DesignTokens.Color.warning.opacity(0.15) : DesignTokens.Color.surfaceTint)
                    .foregroundStyle(isExclusionMode ? DesignTokens.Color.warning : DesignTokens.Color.primaryText)
                    .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Mode")
                .font(.footnote.weight(.medium))
                .foregroundStyle(DesignTokens.Color.textSecondary)
            Picker("Mode", selection: $viewModel.mode) {
                ForEach(PlaylistMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            crossfadeLengthControl
        }
    }

    /// **Added 2026-08-19**, per Andy's direct request — "at Build Mix in
    /// conjunction with Mode setting." Lives immediately under the mode
    /// picker rather than elsewhere on the Hub, per that instruction.
    /// 0...12 extra seconds, by 1 (widened from 0...5 on 2026-09-10 alongside
    /// the longer base blend — see `CrossfadeTiming`) -- added *on top of*
    /// each transition's own tempo-derived crossfade length, not a
    /// replacement for it, so a fast song and a slow song still don't get
    /// an identical blend length. 0 (today's exact behavior) is the
    /// default; nothing changes for a build unless this is actually moved.
    ///
    /// **Label reworded 2026-08-21** — Testing (49): Andy assumed "Standard
    /// blend length" meant a flat 2s, since the label never showed a real
    /// number, and asked to change the Stepper to a fixed "7s ± 3s" range.
    /// There is no flat standard to fix a number to -- the base is
    /// `clip(60/bpm × 8 beats, 3s, 16s)`, genuinely different per transition
    /// on purpose (a flat length would make a slow ballad's blend feel
    /// rushed or a fast track's feel sluggish -- validated back in Phase 1,
    /// carried over deliberately). Rather than silently replace that
    /// tempo-aware formula with a flat number, the label now says the real
    /// range outright, so the screen answers the question instead of the
    /// user having to guess or ask.
    private var crossfadeLengthControl: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("Crossfade length")
                .font(.footnote.weight(.medium))
                .foregroundStyle(DesignTokens.Color.textSecondary)
            Stepper(value: $viewModel.extraCrossfadeSec, in: 0...12, step: 1) {
                Text(
                    viewModel.extraCrossfadeSec > 0
                        ? "+\(Int(viewModel.extraCrossfadeSec))s on top — blends run about \(3 + Int(viewModel.extraCrossfadeSec))–\(16 + Int(viewModel.extraCrossfadeSec))s, tempo-based"
                        : "Standard — blends run 3–16s, based on each song's tempo"
                )
                .foregroundStyle(DesignTokens.Color.textPrimary)
            }
        }
    }

    // MARK: - Duration control

    /// Tier 1 quick win per `documentation/Editability_UX_Gap_Analysis.docx`
    /// — `MixBuilder` already accepted `targetSeconds` as a parameter, this
    /// screen just never gave the user a way to set it. 10...120 min, by 5,
    /// matches `playlist_mixer.py`'s `--max-minutes` default cap at the top.
    ///
    /// **"Include everything" toggle added 2026-08-14** — real-device
    /// feedback asked why picking one bounded source (a genre, an artist)
    /// still gets trimmed to a duration rather than just including
    /// everything in it, mirroring Phase 1's `--keep-all` mode. Defaults to
    /// on (Andy's explicit instruction, same day).
    ///
    /// **Display bug fixed 2026-08-14** (reported in real-device testing the
    /// same day the toggle itself shipped): the first version only grayed
    /// out and disabled the Target Length control while the toggle was on,
    /// rather than hiding it — and always showed the toggle's "no length
    /// limit" explanatory text regardless of state, which read as
    /// contradictory when off. Now the Stepper is only in the view hierarchy
    /// at all when relevant (`if !includeEverything`), and the toggle's own
    /// subtitle switches between the two states instead of only ever
    /// describing the "on" one.
    private var durationControl: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Toggle(isOn: $viewModel.includeEverything) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text("Include everything")
                        .font(.body)
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                    Text(
                        viewModel.includeEverything
                            ? "No length limit — every available song in the selected pool is included."
                            : "Off — the mix is trimmed to the target length below."
                    )
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                }
            }
            .tint(DesignTokens.Color.primary)

            if !viewModel.includeEverything {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("Target length")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                    Stepper(value: $viewModel.targetMinutes, in: 10...120, step: 5) {
                        Text("\(viewModel.targetMinutes) min")
                            .foregroundStyle(DesignTokens.Color.textPrimary)
                    }
                }
            }
        }
    }

    // MARK: - Build Mix bar

    private var buildMixBar: some View {
        VStack(spacing: DesignTokens.Spacing.xxs) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectionSummary)
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                    // Live song-count preview, added 2026-08-14 -- lets
                    // Andy compare "how many songs did I actually pick"
                    // against "how many made it into the finished mix"
                    // without waiting for a full build, per his own request
                    // during real-device testing of the exclusion-count
                    // question. `nil` for a plain "whole library" pick with
                    // nothing excluded, or an empty selection -- both
                    // already covered by `selectionSummary` above, so no
                    // redundant line. **Extended 2026-09-09** to also cover
                    // whole-library-minus-exclusions, worded as "remaining"
                    // rather than "found" since it's a subtraction, not a
                    // lookup -- see `SourceSelectionViewModel
                    // .refreshPreviewSongCount`'s own doc comment.
                    if let previewSongCount = viewModel.previewSongCount {
                        Text(viewModel.useWholeLibrary
                            ? "\(previewSongCount) song\(previewSongCount == 1 ? "" : "s") remaining"
                            : "\(previewSongCount) song\(previewSongCount == 1 ? "" : "s") found")
                            .font(.caption2)
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                        // Total minutes, added 2026-08-20 per Andy's direct
                        // request -- planning an event around a target
                        // length (e.g. "65 minutes") needs a sense of scope
                        // before Build Mix even runs, not just a song count.
                        if let previewTotalMinutes = viewModel.previewTotalMinutes {
                            Text("~\(previewTotalMinutes) min")
                                .font(.caption2)
                                .foregroundStyle(DesignTokens.Color.textSecondary)
                        }
                    }
                }
                Spacer()
                Button {
                    Task {
                        let playlist = await mixBuilder.build(
                            selectedSources: viewModel.selectedSources,
                            mode: viewModel.mode,
                            targetSeconds: Double(viewModel.targetMinutes * 60),
                            keepAll: viewModel.includeEverything,
                            extraCrossfadeSec: viewModel.extraCrossfadeSec,
                            useWholeLibrary: viewModel.useWholeLibrary,
                            store: store
                        )
                        if let playlist {
                            // Hand off to `MyMixesView`, which replaces its
                            // whole navigation path in one step (popping this
                            // Hub and pushing Playlist Detail together) --
                            // see this file's own doc comment on why this no
                            // longer also calls `dismiss()` itself here.
                            onBuilt(playlist, mixBuilder.lastBuildExclusionMessage, mixBuilder.lastExcludedTracks, mixBuilder.lastDuplicateGroups)
                        }
                    }
                } label: {
                    Text("Build Mix")
                        .frame(minHeight: DesignTokens.Size.buttonHeightStandard)
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Color.primary)
                .foregroundStyle(DesignTokens.Color.onPrimary)
                .disabled(!viewModel.hasSelection)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.xs)
        }
        .background(DesignTokens.Color.surface)
    }

    /// **Exclusion case added 2026-09-09** — "Whole library selected"
    /// unchanged when nothing's excluded (today's exact wording, for every
    /// playlist already built this way); a real, distinct summary once one
    /// or more picks are excluding something from it.
    private var selectionSummary: String {
        if viewModel.useWholeLibrary {
            let excludedCount = viewModel.selectedSources.count
            guard excludedCount > 0 else { return "Whole library selected" }
            return "Whole library, excluding \(excludedCount) source\(excludedCount == 1 ? "" : "s")"
        }
        let count = viewModel.selectedSources.count
        if count == 0 { return "No sources selected" }
        return "\(count) source\(count == 1 ? "" : "s") selected"
    }

    // MARK: - Permission denied

    private var permissionDenied: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "music.note.list")
                .font(.title)
                .foregroundStyle(DesignTokens.Color.textSecondary)
            Text("Seamless Mixer needs access to your music library to build mixes from your own songs.")
                .font(.body)
                .foregroundStyle(DesignTokens.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignTokens.Spacing.xl)
        }
        .padding(DesignTokens.Spacing.lg)
    }
}

#Preview {
    // Same reasoning as `MyMixesView`'s preview -- a successful Build Mix
    // navigates to `PlaylistDetailView`, which requires `PlaybackEngine` as
    // an `@EnvironmentObject`. `onBuilt` is a no-op here since the preview
    // has no parent `MyMixesView` to hand the result up to.
    NavigationStack {
        SourceSelectionHubView(store: PlaylistStore(), onBuilt: { _, _, _, _ in })
    }
    .environmentObject(PlaybackEngine())
}
