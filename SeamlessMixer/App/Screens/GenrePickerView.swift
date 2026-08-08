import SwiftUI
import MediaPlayer
import PlaylistCore

/// First real Screen 2 of the confirmed two-screen Source Selection design
/// — "a plain alphabetical list, no index rail (genre lists are short
/// enough not to need one) and no artwork". Built first among the four
/// category pickers precisely because it's the simplest: no A-Z rail
/// (Artists/Albums) and no artwork grid (Playlists/Albums) to get right.
///
/// Selecting a genre here is deliberately how "Build Mix" gets a *small*,
/// bounded pool to work with next — testing that against "whole library"
/// first would mean the first real analysis run tries to process Andy's
/// entire library synchronously and blind, the same class of mistake this
/// project already learned to avoid the hard way (Rule 6's sandbox RAM
/// ceiling, the 8-track — not whole-library — real-audio validation set).
struct GenrePickerView: View {
    @ObservedObject var viewModel: SourceSelectionViewModel
    @State private var genres: [GenreRow] = []

    /// A plain struct rather than a tuple for `List`'s data — sidesteps any
    /// ambiguity between labeled/unlabeled tuple types across the
    /// `compactMap`/`sorted`/property-assignment chain, and gives `List` a
    /// real `Identifiable` to key rows off directly.
    struct GenreRow: Identifiable {
        let name: String
        let songCount: Int
        var id: String { name }
    }

    var body: some View {
        List(genres) { genre in
            row(for: genre)
        }
        .listStyle(.plain)
        .navigationTitle("Genres")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadGenres)
    }

    private func row(for genre: GenreRow) -> some View {
        let source = SelectedSource(id: "genre:\(genre.name)", type: .genre, label: genre.name)
        let selected = viewModel.isSelected(source)

        return Button {
            viewModel.toggle(source)
        } label: {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? DesignTokens.Color.primary : DesignTokens.Color.textDisabled)
                Text(genre.name)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                Spacer()
                // Same "N songs" caption the confirmed design keeps from the
                // first Source Selection pass, per category-row consistency.
                Text("\(genre.songCount) songs")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func loadGenres() {
        let collections = MPMediaQuery.genres().collections ?? []
        genres = collections
            .compactMap { collection -> GenreRow? in
                guard let name = collection.representativeItem?.genre, !name.isEmpty else { return nil }
                return GenreRow(name: name, songCount: collection.items.count)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
