import SwiftUI
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
/// **Deliberately no per-song artwork thumbnail** — a real, flagged
/// simplification, not an oversight. `ArtistPickerView`/`AlbumPickerView`
/// load one artwork image per *collection* (hundreds of artists/albums);
/// this screen's list is `MPMediaQuery.songs()` directly, which could
/// plausibly run to several thousand individual rows on a real library —
/// eagerly generating a resized thumbnail for every single one in
/// `loadSongs()`'s upfront pass risks exactly the kind of "worked fine at
/// smaller scale, stalls at real scale" problem this project has hit
/// before (Rule 6, the 8-track-not-whole-library validation set). A flat
/// placeholder icon for every row, matching the same deferred-artwork
/// precedent My Mixes' own collage tiles already use, is the safe default
/// until there's a reason (and a way to test) to add lazy per-row loading.
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

    private func indexRail(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 1) {
            ForEach(sections) { section in
                Button {
                    proxy.scrollTo(section.letter, anchor: .top)
                } label: {
                    Text(section.letter)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DesignTokens.Color.primaryText)
                        .frame(width: 18)
                }
            }
        }
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

                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusSmall)
                        .fill(DesignTokens.Color.surfaceTint)
                    Image(systemName: "music.note")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.primaryText)
                }
                .frame(width: 36, height: 36)

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

    private func loadSongs() {
        let items = MPMediaQuery.songs().items ?? []
        let rows: [SongRow] = items.compactMap { item in
            guard let title = item.title, !title.isEmpty else { return nil }
            return SongRow(persistentID: item.persistentID, title: title, artist: item.artist ?? "Unknown Artist")
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
