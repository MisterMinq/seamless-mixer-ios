import SwiftUI
import UIKit
import MediaPlayer
import PlaylistCore

/// The real Favourites category picker — closes the gap Andy flagged in
/// Testing (65)/CLAUDE.md 0.25.71: the Hub's pinned Favourites row (Batch 1,
/// 0.25.69) only ever let you toggle "all favourited songs" as one opaque
/// bucket, with no way to actually see which songs were tagged. Andy's own
/// comparison was exact — this should behave like every other category row
/// (Playlists/Genres/Artists/Albums/Songs): tap in, see the real list,
/// check off individually, combine with anything else already picked.
///
/// Deliberately mirrors `SongPickerView` almost exactly (same A-Z rail
/// implementation, same per-album artwork caching, same `.songs`-typed
/// individual selection) rather than introducing anything new — a
/// favourited song picked here is indistinguishable from the same song
/// picked via the plain Songs picker, which already has full, tested
/// resolve/persist/Refresh support (see `SourceSelectionHubView
/// .categoryRows`'s own doc comment for the "shared badge count" trade-off
/// this implies). The only real difference from `SongPickerView` is the
/// source query: `tracks WHERE is_favorite = 1` (this app's own database,
/// via `store`) instead of every song in the library (pure `MediaPlayer`,
/// no `store` needed) — that's also why this screen needs a `store`
/// parameter `SongPickerView` never did.
struct FavoriteSongsPickerView: View {
    @ObservedObject var viewModel: SourceSelectionViewModel
    let store: PlaylistStore
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

    /// Matches title OR artist, same reasoning as `SongPickerView`'s own
    /// local filter.
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
        VStack(spacing: 0) {
            InlineSearchField(text: $searchText, prompt: "Search favourites")
            if sections.isEmpty {
                Spacer()
                Text("No favourites yet — mark a song from any track's \u{201c}…\u{201d} menu, or the star on Now Playing while it's playing.")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(DesignTokens.Spacing.lg)
                Spacer()
            } else {
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
        }
        .background(DesignTokens.Color.background)
        .navigationTitle("Favourites")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadFavoriteSongs)
    }

    /// Identical implementation to `SongPickerView.indexRail` — same fourth-
    /// attempt fix already validated there (plain `Text` + `.onTapGesture`,
    /// no `Button` machinery, since a bare `Button` here picks up unwanted
    /// default chrome that fully hides the tiny letter text).
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

    /// **Uses `.songs`, not `.favoriteSongs`** — see this file's own doc
    /// comment for why: a favourited song picked here is meant to be a
    /// perfectly ordinary individual song pick, resolved/persisted/Refreshed
    /// through the exact same, already-proven path `SongPickerView` uses.
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
                    Image(systemName: "star.fill")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.primaryText)
                }
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusSmall))
    }

    /// Reads favourited persistentIDs from this app's own database (raw
    /// SQL, same `tracks.is_favorite` convention `MediaLibraryResolver`'s
    /// `.favoriteSongs` case and `SourceSelectionViewModel
    /// .loadFavoriteSongsCount` already established), then resolves each
    /// against `MPMediaQuery.songs()` via a plain Swift `==` filter on a
    /// `Set` — never a `MPMediaPropertyPredicate` keyed on a raw
    /// persistentID, the exact class of bug this project has already hit
    /// and fixed multiple times (see `MediaLibraryResolver`'s own doc
    /// comments for the history). Same per-album artwork-caching trick
    /// `SongPickerView.loadSongs()` already validated — real cost scales
    /// with distinct album count among favourites, not favourite-song
    /// count.
    private func loadFavoriteSongs() {
        guard let db = store.db else {
            sections = []
            return
        }
        let favoriteIDs: [Int64] = (try? db.dbQueue.read { conn in
            try Int64.fetchAll(conn, sql: "SELECT persistent_id FROM tracks WHERE is_favorite = 1")
        }) ?? []
        guard !favoriteIDs.isEmpty else {
            sections = []
            return
        }
        let favoriteIDSet = Set(favoriteIDs)

        let items = (MPMediaQuery.songs().items ?? []).filter { favoriteIDSet.contains(Int64(bitPattern: $0.persistentID)) }

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
