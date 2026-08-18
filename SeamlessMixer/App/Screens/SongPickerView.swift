import SwiftUI
import UIKit
import MediaPlayer
import PlaylistCore

/// Fifth and last of the confirmed Source Selection category pickers,
/// closing out ADR-7's original five source types (Playlist/Songs/Genre/
/// Artist/Album). "Songs" was always meant to be its own individual-song
/// browsing picker, matching Apple Music's own Songs tab — but only the
/// other four category pickers ever got built, and `.songs` quietly became
/// the internal label for the separate "whole library" toggle instead (see
/// CLAUDE.md's 0.24.0 entry, which first flagged this as a real, confirmed
/// gap, not a misunderstanding). Andy's own recommended next priority once
/// that gap surfaced.
///
/// Plain alphabetical list (grouped by song title's first letter, matching
/// `GenrePickerView`'s convention) with an A-Z index rail, reusing
/// `ArtistPickerView`'s pattern — a song list scales the same way an artist
/// list does, and Andy's library almost certainly has many more individual
/// songs than the ~313 artists already seen in earlier testing.
///
/// **Real per-row artwork, cached per *album* — not per song.** First
/// version of this screen skipped artwork entirely, reasoning (wrongly)
/// that a real library's song count (plausibly thousands) meant thousands
/// of thumbnail renders. Andy caught the real flaw in that reasoning: a
/// song's artwork isn't its own — it's its *album's* cover, shared by
/// every other song on that same album. The number of genuinely distinct
/// images that ever need rendering is bounded by how many albums are
/// represented (a few hundred, the same order of magnitude
/// `AlbumPickerView` already renders without issue), regardless of how
/// many thousands of songs sit across them. `loadSongs()` now renders each
/// album's artwork once, keyed by `albumPersistentID` in a local
/// dictionary, and every song sharing that album reuses the same already-
/// rendered `UIImage` — so the real cost scales with album count, not song
/// count, which is exactly the number this project already knows is safe.
///
/// **Selecting individual songs re-sequences them like any other source**
/// (Andy's explicit call, 2026-08-16) — a picked song just joins the
/// candidate pool the same way a genre or artist pick would; the Sequencer
/// still decides final track order for the harmonic/energy-arc reasons
/// that are this app's whole point, not the order songs were checked off
/// in. No special-casing needed anywhere else in the pipeline for this.
///
/// `MediaLibraryResolver`/`MixBuilder` resolve `.songs` selections by the
/// song's own `persistentID` via `MPMediaItemPropertyPersistentID` — the
/// same "identify by persistentID, not display name" convention every
/// other non-genre source already uses.
struct SongPickerView: View {
    @ObservedObject var viewModel: SourceSelectionViewModel
    @State private var sections: [SongSection] = []
    @State private var searchText = ""

    struct SongRow: Identifiable {
        let persistentID: MPMediaEntityPersistentID
        let title: String
        let artist: String
        let artwork: UIImage?
        var id: MPMediaEntityPersistentID { persistentID }
    }

    struct SongSection: Identifiable {
        let letter: String
        let songs: [SongRow]
        var id: String { letter }
    }

    /// Matches title OR artist, per the same "you may remember one but not
    /// the other" reasoning the Hub's own global search already applies —
    /// this is a local filter, not a live query, same pattern every other
    /// picker's own search uses.
    private var filteredSections: [SongSection] {
        guard !searchText.isEmpty else { return sections }
        return sections.compactMap { section in
            let matches = section.songs.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) || $0.artist.localizedCaseInsensitiveContains(searchText)
            }
            return matches.isEmpty ? nil : SongSection(letter: section.letter, songs: matches)
        }
    }

    var body: some View {
        // Plain, embedded field, not `.searchable()` -- see
        // `InlineSearchField`'s own doc comment for why.
        VStack(spacing: 0) {
            InlineSearchField(text: $searchText, prompt: "Search songs")
            ScrollViewReader { proxy in
                ZStack(alignment: .trailing) {
                    List {
                        ForEach(filteredSections) { section in
                            Section {
                                ForEach(section.songs) { song in
                                    row(for: song)
                                }
                            } header: {
                                Text(section.letter)
                                    .id(section.letter)
                            }
                        }
                    }
                    .listStyle(.plain)

                    if searchText.isEmpty, sections.count > 1 {
                        indexRail(proxy: proxy)
                    }
                }
            }
        }
        .background(DesignTokens.Color.background)
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadSongs)
    }

    /// **Fixed 2026-08-17, second attempt.** Andy: "the letters #, A, X, Y
    /// and Z in 'Songs' can hardly be clicked on to navigate there." The
    /// first fix (dividing the rail's available height evenly across every
    /// letter via `GeometryReader`) made things worse, not better — Andy's
    /// next report: "A-Z index rails are worse now. No letters seen." Root
    /// cause: `GeometryReader` can report a `size.height` of `0` on an
    /// early/transient layout pass in this `ZStack`-over-`List` arrangement
    /// (a known SwiftUI quirk, not specific to this screen), and dividing
    /// row height by the section count then collapsed every row to zero
    /// height — the letters were still in the view hierarchy, just
    /// rendered with no visible height at all.
    ///
    /// Replaced with a fixed, comfortably-tappable row height, and — when
    /// there isn't room to show every letter at that height — *thinning*
    /// the set of letters shown (evenly skipping some) rather than
    /// shrinking rows to fit. This is the same approach UIKit's own
    /// `sectionIndexTitles` uses on a long list, and it can never collapse
    /// to invisible: `maxVisible` is floored at `1`, and `max(geo.size
    /// .height, 1)` means even a bad `0`-height layout pass still yields a
    /// small but real, tappable set of letters instead of none. The last
    /// letter is always kept even after thinning, so `#`/`Z` stays
    /// reachable regardless of how aggressively the rest gets thinned.
    ///
    /// **Fixed 2026-08-17, third attempt — the real bug this whole time.**
    /// Andy: "Song, Artist picker even worse now than before" — the
    /// screenshots showed a stack of solid gray pill shapes with no visible
    /// letters at all, not just hard-to-tap or invisible-from-zero-height.
    /// Root cause, present since this rail was first built and carried
    /// through both prior "fixes" without anyone noticing: the `Button`
    /// below never had `.buttonStyle(.plain)` set. A bare, unstyled
    /// `Button` in this context picks up the platform's default bordered/
    /// platter chrome — a solid background capsule — which at `caption2`
    /// size is large enough to fully cover the tiny letter text sitting on
    /// top of it. This round's fixed, more generous 18pt row height (vs.
    /// the prior version's inconsistent/collapsing heights) made that
    /// background chrome *bigger and more visible*, not less — exactly
    /// matching "even worse now." `.buttonStyle(.plain)` removes the
    /// default chrome entirely, leaving just the letter text, the same fix
    /// every other tappable text/icon button in this app already uses.
    ///
    /// **Fixed 2026-08-17, fourth attempt — `.buttonStyle(.plain)` alone
    /// wasn't enough.** Andy re-tested with the previous fix confirmed
    /// genuinely included in the build ("the letters are the same...
    /// nothing changed there") — ruling out a file-push gap and meaning
    /// the `Button`-based chrome theory, while plausible, didn't fully
    /// explain what's on screen. Rather than guess a second style variant
    /// on the same `Button` (a bordered look surviving `.buttonStyle
    /// (.plain)` would be a genuinely unusual SwiftUI failure to keep
    /// betting on), this drops `Button` entirely — a plain `Text` with an
    /// explicit `.contentShape(Rectangle())` tap target and
    /// `.onTapGesture`, which carries no button machinery, no style
    /// resolution, and nothing for the platform to render a background
    /// for. If gray pills are still visible after this, the cause is
    /// somewhere other than this rail's own tap-target implementation
    /// (e.g. a `List` row/section styling bleeding through at the
    /// trailing edge) and needs a fresh screenshot to chase further.
    private func indexRail(proxy: ScrollViewProxy) -> some View {
        GeometryReader { geo in
            let rowHeight: CGFloat = 18
            let maxVisible = max(Int(max(geo.size.height, 1) / rowHeight), 1)
            let displayed = thinnedSections(maxVisible: maxVisible)

            VStack(spacing: 0) {
                ForEach(displayed) { section in
                    Text(section.letter)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DesignTokens.Color.primaryText)
                        .frame(width: 18, height: rowHeight)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            proxy.scrollTo(section.letter, anchor: .top)
                        }
                }
            }
        }
        .frame(width: 18)
        .padding(.trailing, DesignTokens.Spacing.xxs)
    }

    private func thinnedSections(maxVisible: Int) -> [SongSection] {
        guard sections.count > maxVisible, maxVisible > 0 else { return sections }
        let stride = Double(sections.count) / Double(maxVisible)
        var result: [SongSection] = []
        var index = 0.0
        while Int(index) < sections.count {
            result.append(sections[Int(index)])
            index += stride
        }
        if let last = sections.last, result.last?.letter != last.letter {
            result.append(last)
        }
        return result
    }

    private func row(for song: SongRow) -> some View {
        let source = SelectedSource(id: "songs:\(song.persistentID)", type: .songs, label: song.title, persistentID: song.persistentID)
        let selected = viewModel.isSelected(source)

        return Button {
            viewModel.toggle(source)
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? DesignTokens.Color.primary : DesignTokens.Color.textDisabled)

                artworkTile(for: song)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(song.title)
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func artworkTile(for song: SongRow) -> some View {
        Group {
            if let artwork = song.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusSmall)
                        .fill(DesignTokens.Color.surfaceTint)
                    Image(systemName: "music.note")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.primaryText)
                }
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusSmall))
    }

    private func loadSongs() {
        let items = MPMediaQuery.songs().items ?? []

        // Keyed by album, not by song -- see this file's own doc comment
        // for why that's the number that actually matters here. `0` is
        // `MPMediaEntityPersistentID`'s value for "no album metadata,"
        // which is never worth caching against (every such song would
        // otherwise collide on the same cache key and wrongly share
        // whichever one happened to render first).
        var artworkCache: [MPMediaEntityPersistentID: UIImage] = [:]

        let rows: [SongRow] = items.compactMap { item in
            guard let title = item.title, !title.isEmpty else { return nil }

            var artworkImage: UIImage?
            let albumID = item.albumPersistentID
            if albumID != 0, let cached = artworkCache[albumID] {
                artworkImage = cached
            } else if let rendered = item.artwork?.image(at: CGSize(width: 36, height: 36)) {
                if albumID != 0 { artworkCache[albumID] = rendered }
                artworkImage = rendered
            }

            return SongRow(persistentID: item.persistentID, title: title, artist: item.artist ?? "Unknown Artist", artwork: artworkImage)
        }

        // "#" bucket-for-non-letters convention, same as Artists/Albums.
        let grouped = Dictionary(grouping: rows) { row -> String in
            guard let first = row.title.first, first.isLetter else { return "#" }
            return String(first).uppercased()
        }

        sections = grouped.keys.sorted().map { letter in
            let sorted = grouped[letter]!.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return SongSection(letter: letter, songs: sorted)
        }
    }
}
