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
/// `MixBuilder` now resolves `.artist` selections for real (via
/// `MPMediaItemPropertyArtistPersistentID`, using each row's real
/// `persistentID` — see `SelectedSource`'s own doc comment for why display
/// names alone aren't used), added the same slice as the Playlists/Albums
/// non-genre resolution.
struct ArtistPickerView: View {
    @ObservedObject var viewModel: SourceSelectionViewModel
    @State private var sections: [ArtistSection] = []
    /// **Added 2026-08-15** — see `GenrePickerView`'s own note on why this
    /// is separate from the Hub's global search. Filtering happens per
    /// section (below) rather than flattening the list, so the A-Z rail's
    /// own letters stay meaningful against whatever's currently visible.
    @State private var searchText = ""
    /// **Added 2026-08-15, real-device bug** — Andy searched "Shalamar" (an
    /// artist confirmed via Apple Music's own library search to genuinely
    /// exist in his library) and got no match here, even after the Hub's
    /// own search got a defensive fallback for exactly this. Root cause
    /// still not fully confirmed, but Apple's own app finding it directly
    /// disproves the original "Album Artist vs. Artist tag" theory — this
    /// picker's `sections` (built once from `MPMediaQuery.artists()
    /// .collections`) may simply not include every artist `MPMediaQuery`
    /// itself can otherwise resolve. Rather than guess a third theory blind,
    /// this supplements the local filter with the same direct, live
    /// song-level Artist-field query the Hub's search already uses —
    /// bypassing whatever's making `.artists()`'s own grouping incomplete —
    /// run only while actively searching (not on every full-list load, to
    /// avoid paying a full-library query cost just to show the picker).
    @State private var supplementalArtists: [ArtistRow] = []

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

    /// Filters each section's own artists rather than the flat row list,
    /// then drops any section left empty — keeps the A-Z rail (built from
    /// this same array, see `indexRail`) showing only letters that actually
    /// have a visible match. Also merges in `supplementalArtists` (see its
    /// own doc comment) via the same `grouped(_:)` helper `loadArtists`
    /// uses, so a match found only through the fallback query still gets
    /// grouped and sorted consistently with everything else.
    private var filteredSections: [ArtistSection] {
        guard !searchText.isEmpty else { return sections }
        let matched = sections.flatMap { section in
            section.artists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        let existingIDs = Set(matched.map(\.persistentID))
        let combined = matched + supplementalArtists.filter { !existingIDs.contains($0.persistentID) }
        return grouped(combined)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                List {
                    ForEach(filteredSections) { section in
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

                if searchText.isEmpty, sections.count > 1 {
                    indexRail(proxy: proxy)
                }
            }
        }
        .background(DesignTokens.Color.background)
        .searchable(text: $searchText, prompt: "Search artists")
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadArtists)
        .onChange(of: searchText) { _, newValue in
            performSupplementalSearch(newValue)
        }
    }

    /// See `supplementalArtists`'s own doc comment. Queries `MPMediaQuery
    /// .songs()` directly by `MPMediaItemPropertyArtist` rather than relying
    /// on `MPMediaQuery.artists()`'s own grouping — the same fallback
    /// approach `SourceSelectionViewModel.performSearch` already uses for
    /// the Hub's search. Capped to 25 songs, matching that same limit.
    private func performSupplementalSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            supplementalArtists = []
            return
        }
        let songQuery = MPMediaQuery.songs()
        songQuery.addFilterPredicate(MPMediaPropertyPredicate(value: trimmed, forProperty: MPMediaItemPropertyArtist, comparisonType: .contains))
        var seenIDs = Set<MPMediaEntityPersistentID>()
        var rows: [ArtistRow] = []
        for item in (songQuery.items ?? []).prefix(25) {
            guard let name = item.artist, !name.isEmpty, !seenIDs.contains(item.artistPersistentID) else { continue }
            seenIDs.insert(item.artistPersistentID)
            rows.append(ArtistRow(
                persistentID: item.artistPersistentID,
                name: name,
                songCount: 0,
                artwork: item.artwork?.image(at: CGSize(width: 80, height: 80))
            ))
        }
        supplementalArtists = rows
    }

    /// Shared by `loadArtists` (the full, unfiltered list) and
    /// `filteredSections` (a filtered/merged subset) — same "#" bucket and
    /// alphabetical-sort logic either way.
    private func grouped(_ rows: [ArtistRow]) -> [ArtistSection] {
        let byLetter = Dictionary(grouping: rows) { row -> String in
            guard let first = row.name.first, first.isLetter else { return "#" }
            return String(first).uppercased()
        }
        return byLetter.keys.sorted().map { letter in
            let sorted = byLetter[letter]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return ArtistSection(letter: letter, artists: sorted)
        }
    }

    /// **Fixed 2026-08-17** — same real-device bug found in `SongPickerView`
    /// (its own doc comment has the full root-cause explanation): a plain
    /// `VStack` of fixed-size rows had no bound on its own total height, so
    /// a library with enough distinct letters could overflow past the
    /// space actually available, pushing the first/last few letters
    /// somewhere not reliably tappable. Fixed the same way — a
    /// `GeometryReader` computes each row's height to fit the real
    /// available space, however many letters there are.
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

    private func row(for artist: ArtistRow) -> some View {
        let source = SelectedSource(id: "artist:\(artist.persistentID)", type: .artist, label: artist.name, persistentID: artist.persistentID)
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
        // "#" bucket-for-non-letters convention, per `grouped(_:)`'s own
        // doc comment.
        sections = grouped(rows)
    }
}
