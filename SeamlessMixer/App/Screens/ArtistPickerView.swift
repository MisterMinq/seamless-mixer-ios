import SwiftUI
import UIKit
import MediaPlayer
import PlaylistCore

/// Third of the four category pickers (Screen 2), per the confirmed
/// Source Selection design: "A-Z alphabet index rail pinned to the right
/// edge... circular artist-photo rows grouped under letter headers, a
/// leading checkbox in place of Apple's trailing chevron."
///
/// **First use of an A-Z index rail in this codebase.** SwiftUI's `List`
/// has no built-in equivalent of UIKit's `sectionIndexTitles` — this is
/// hand-built with `ScrollViewReader` + per-letter `Section` headers each
/// given a stable `.id()`, and a tap-to-scroll rail overlay that calls
/// `proxy.scrollTo(letter)`. Flagged as the highest-risk part of this
/// slice (the `Section(header:).id()` + `ScrollViewReader` combination is
/// new territory here, unlike the plain `List`/`LazyVGrid` patterns Genres
/// and Playlists already proved out) — if this doesn't compile or scroll
/// correctly, check here first. Albums (still pending) needs the same rail
/// and should reuse this pattern rather than re-deriving it.
///
/// Selection-only this slice, same phasing Genres/Playlists used —
/// `MixBuilder` doesn't resolve `.artist` sources yet.
struct ArtistPickerView: View {
    @ObservedObject var viewModel: SourceSelectionViewModel
    @State private var sections: [ArtistSection] = []

    struct ArtistRow: Identifiable {
        let persistentID: MPMediaEntityPersistentID
        let name: String
        let songCount: Int
        let artwork: UIImage?
        var id: MPMediaEntityPersistentID { persistentID }
    }

    struct ArtistSection: Identifiable {
        let letter: String
        let artists: [ArtistRow]
        var id: String { letter }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.artists) { artist in
                                row(for: artist)
                            }
                        } header: {
                            Text(section.letter)
                                .id(section.letter)
                        }
                    }
                }
                .listStyle(.plain)

                if sections.count > 1 {
                    indexRail(proxy: proxy)
                }
            }
        }
        .background(DesignTokens.Color.background)
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadArtists)
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

    private func row(for artist: ArtistRow) -> some View {
        let source = SelectedSource(id: "artist:\(artist.persistentID)", type: .artist, label: artist.name)
        let selected = viewModel.isSelected(source)

        return Button {
            viewModel.toggle(source)
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? DesignTokens.Color.primary : DesignTokens.Color.textDisabled)

                artworkCircle(for: artist)

                Text(artist.name)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text("\(artist.songCount) songs")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func artworkCircle(for artist: ArtistRow) -> some View {
        Group {
            if let artwork = artist.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(DesignTokens.Color.surfaceTint)
                    Image(systemName: "person.fill")
                        .foregroundStyle(DesignTokens.Color.primaryText)
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private func loadArtists() {
        let collections = MPMediaQuery.artists().collections ?? []
        let rows: [ArtistRow] = collections.compactMap { collection in
            guard let item = collection.representativeItem,
                  let name = item.artist, !name.isEmpty else { return nil }
            return ArtistRow(
                persistentID: item.artistPersistentID,
                name: name,
                songCount: collection.items.count,
                artwork: item.artwork?.image(at: CGSize(width: 80, height: 80))
            )
        }

        // "#" catches anything that doesn't start with a letter (a number,
        // an emoji, etc.) rather than crashing or silently dropping it.
        let grouped = Dictionary(grouping: rows) { row -> String in
            guard let first = row.name.first, first.isLetter else { return "#" }
            return String(first).uppercased()
        }

        sections = grouped.keys.sorted().map { letter in
            let sorted = grouped[letter]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return ArtistSection(letter: letter, artists: sorted)
        }
    }
}
