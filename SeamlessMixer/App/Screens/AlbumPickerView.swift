import SwiftUI
import UIKit
import MediaPlayer
import PlaylistCore

/// Fourth and last of the four category pickers (Screen 2), per the
/// confirmed Source Selection design: "same grid treatment as Playlists,
/// plus an A-Z index rail like Artists — album collections scale the same
/// way artist lists do."
///
/// Deliberately combines two already-proven patterns rather than
/// introducing a third: `PlaylistPickerView`'s artwork-grid cell (square
/// tile, checkmark overlay, name + song count) and `ArtistPickerView`'s
/// A-Z rail (`ScrollViewReader` + per-letter `.id()`, tap-to-scroll
/// overlay) — both confirmed compiling and working on Codemagic already.
/// One structural difference from Artists: this uses a plain `ScrollView`
/// + `LazyVStack` of (letter header + `LazyVGrid`) per section, not
/// `List`/`Section`, since a `List` doesn't nest a grid per section
/// cleanly — a `ScrollView`-based layout was the more direct fit here.
///
/// Selection-only this slice, same phasing every other picker used —
/// `MixBuilder` still only resolves genre sources; its error copy already
/// covers albums generically.
struct AlbumPickerView: View {
    @ObservedObject var viewModel: SourceSelectionViewModel
    @State private var sections: [AlbumSection] = []

    struct AlbumRow: Identifiable {
        let persistentID: MPMediaEntityPersistentID
        let title: String
        let songCount: Int
        let artwork: UIImage?
        var id: MPMediaEntityPersistentID { persistentID }
    }

    struct AlbumSection: Identifiable {
        let letter: String
        let albums: [AlbumRow]
        var id: String { letter }
    }

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: DesignTokens.Spacing.sm)]

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        ForEach(sections) { section in
                            Text(section.letter)
                                .font(.headline)
                                .foregroundStyle(DesignTokens.Color.textSecondary)
                                .id(section.letter)
                                .padding(.top, DesignTokens.Spacing.sm)

                            LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.md) {
                                ForEach(section.albums) { album in
                                    cell(for: album)
                                }
                            }
                        }
                    }
                    .padding(DesignTokens.Spacing.md)
                }

                if sections.count > 1 {
                    indexRail(proxy: proxy)
                }
            }
        }
        .background(DesignTokens.Color.background)
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadAlbums)
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

    private func cell(for album: AlbumRow) -> some View {
        let source = SelectedSource(id: "album:\(album.persistentID)", type: .album, label: album.title)
        let selected = viewModel.isSelected(source)

        return Button {
            viewModel.toggle(source)
        } label: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                ZStack(alignment: .topTrailing) {
                    artworkTile(for: album)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? DesignTokens.Color.primary : .white)
                        .padding(4)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                        .padding(DesignTokens.Spacing.xxs)
                }
                Text(album.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .lineLimit(1)
                Text("\(album.songCount) songs")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func artworkTile(for album: AlbumRow) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium)
            .fill(DesignTokens.Color.surfaceTint)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artwork = album.artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium))
                } else {
                    Image(systemName: "square.stack")
                        .foregroundStyle(DesignTokens.Color.primaryText)
                }
            }
            .clipped()
    }

    private func loadAlbums() {
        let collections = MPMediaQuery.albums().collections ?? []
        let rows: [AlbumRow] = collections.compactMap { collection in
            guard let item = collection.representativeItem,
                  let title = item.albumTitle, !title.isEmpty else { return nil }
            return AlbumRow(
                persistentID: item.albumPersistentID,
                title: title,
                songCount: collection.items.count,
                artwork: item.artwork?.image(at: CGSize(width: 140, height: 140))
            )
        }

        // Same "#" bucket-for-non-letters convention as ArtistPickerView.
        let grouped = Dictionary(grouping: rows) { row -> String in
            guard let first = row.title.first, first.isLetter else { return "#" }
            return String(first).uppercased()
        }

        sections = grouped.keys.sorted().map { letter in
            let sorted = grouped[letter]!.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return AlbumSection(letter: letter, albums: sorted)
        }
    }
}
