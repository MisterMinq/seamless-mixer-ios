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
        .background(DesignTokens.Color.background)
        .searchable(text: $searchText, prompt: "Search songs")
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadSongs)
    }

    /// **Fixed 2026-08-17, real-device bug** — Andy: "the letters #, A, X, Y
    /// and Z in 'Songs' can hardly be clicked on to navigate there." Root
    /// cause: this was a plain `VStack` of fixed-size rows with no bound on
    /// its own total height — with Songs spanning nearly the full alphabet
    /// (unlike Genres' short list), the stacked rail could genuinely run
    /// taller than the space actually available between the status bar and
    /// the search field, pushing the first/last few letters into an area
    /// that isn't reliably tappable. Now wrapped in a `GeometryReader` so
    /// every letter's row height is computed to fit the *actual* available
    /// height, however many letters there are — the rail can never overflow
    /// its own bounds again, regardless of library size.
    private func indexRail(proxy: ScrollViewProxy) -> some View {
        GeometryReader { geo in
            let rowHeight = geo.size.height / CGFloat(max(sections.count, 1))
            VStack(spacing: 0) {
                ForEach(sections) { section in
                    Button {
                        proxy.scrollTo(section.letter, anchor: .top)
                    } label: {
                        Text(section.letter)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(DesignTokens.Color.primaryText)
                    }
                    .frame(width: 18, height: rowHeight)
                }
            }
        }
        .frame(width: 18)
        .padding(.trailing, DesignTokens.Spacing.xxs)
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
