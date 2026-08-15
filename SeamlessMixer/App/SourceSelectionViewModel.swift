import Foundation
import MediaPlayer
import PlaylistCore

/// One picked source, e.g. a single genre or artist — the in-memory
/// selection-state equivalent of a `PlaylistSource` row, but lighter: no
/// `playlistID` exists yet at selection time (that only gets created once
/// "Build Mix" actually persists a playlist), so this isn't `PlaylistSource`
/// itself, just what will eventually become one. `id` is a stable
/// type-prefixed key (e.g. `"genre:Smooth Jazz"`) rather than relying on
/// `label` for identity/equality, since two different sources could share a
/// display label in principle (unlikely for genres, more plausible for
/// artist names) but never share the same underlying value.
///
/// `persistentID` (added for `MixBuilder`'s non-genre source resolution) is
/// nil for genres — a genre has no `MPMediaEntityPersistentID` of its own in
/// `MediaPlayer`, it's just resolved by name — and set by
/// `ArtistPickerView`/`AlbumPickerView`/`PlaylistPickerView` to the real
/// underlying collection's persistent ID, since matching by display name
/// alone would be both imprecise (two artists could share a name) and,
/// for playlists, is the only way to re-find that exact playlist at all.
struct SelectedSource: Identifiable {
    let id: String
    let type: SourceType
    let label: String
    var persistentID: MPMediaEntityPersistentID?

    init(id: String, type: SourceType, label: String, persistentID: MPMediaEntityPersistentID? = nil) {
        self.id = id
        self.type = type
        self.label = label
        self.persistentID = persistentID
    }
}

extension SelectedSource: Equatable, Hashable {
    static func == (lhs: SelectedSource, rhs: SelectedSource) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Drives the Source Selection Hub screen. First real use of `MediaPlayer`
/// in this codebase — `MPMediaQuery` is what ADR-7 designates as the
/// candidate-pool source (Playlist/Songs/Genre/Artist/Album), separate from
/// and upstream of the `tracks` SQLite table: browsing categories here needs
/// no prior analysis, only a granted media-library permission. Analysis
/// only becomes necessary once a pool is actually built (per "First-Run
/// Library Analysis — UX"'s inline-vs-prompt behavior) — not part of this
/// screen yet.
///
/// Real device/library counts can't be verified in this environment or on
/// Codemagic's Simulator build (no synced media library there) — same
/// category of gap as Bluetooth/background-audio behavior elsewhere in this
/// project: the code is written against the real API surface and compiles,
/// but needs a real-device check once Andy can install a build, same as
/// `RealAudioValidationTests` needed real audio files Codemagic alone
/// couldn't supply.
@MainActor
final class SourceSelectionViewModel: ObservableObject {
    @Published private(set) var authorizationStatus: MPMediaLibraryAuthorizationStatus = MPMediaLibrary.authorizationStatus()

    @Published private(set) var playlistCount: Int = 0
    @Published private(set) var genreCount: Int = 0
    @Published private(set) var artistCount: Int = 0
    @Published private(set) var albumCount: Int = 0

    /// Segmented-control selection, per the confirmed Source Selection
    /// design ("Mode picker") — defaults to Energy Wave.
    @Published var mode: PlaylistMode = .energyWave

    /// Target playlist length, in minutes. Previously hardcoded to 30 in
    /// `MixBuilder`'s only caller with no real control anywhere (flagged as
    /// a Tier 1 gap in `documentation/Editability_UX_Gap_Analysis.docx`) —
    /// now a real Hub control; 30 stays the default so behavior is
    /// unchanged unless the user actually adjusts it. Range/step (10...120,
    /// by 5) mirrors `playlist_mixer.py`'s `--max-minutes` default cap of
    /// 120 at the top end.
    @Published var targetMinutes: Int = 30

    /// When true, Build Mix includes every analyzed/DRM-accessible track in
    /// the selected pool, ignoring `targetMinutes` entirely — the iOS
    /// equivalent of `playlist_mixer.py`'s `--keep-all` mode (Sequencer
    /// already supports this via its own `keepAll` parameter; this is just
    /// the first UI control to actually set it). Added 2026-08-14 after
    /// real-device feedback questioned why a picked source (e.g. one genre)
    /// gets trimmed to a duration at all rather than just including
    /// everything in it. Mutually exclusive in spirit with `targetMinutes`
    /// (the Hub grays out the Stepper while this is on), though both remain
    /// real, independent properties rather than one replacing the other.
    /// **Defaults to `true` (changed same day, explicit instruction)** —
    /// Andy asked for "include everything" to be the standing default until
    /// he says otherwise, not just an available option.
    @Published var includeEverything: Bool = true

    /// True once "Use your whole library" is picked — per the confirmed
    /// design, this clears/disables the four category rows since combining
    /// it with anything else is redundant.
    @Published var useWholeLibrary: Bool = false {
        didSet {
            if useWholeLibrary { selectedSources.removeAll() }
            refreshPreviewSongCount()
        }
    }

    /// Real per-category picks, populated live as checkboxes are ticked on
    /// a category picker screen — all four (Genres, Playlists, Artists,
    /// Albums) are real pickers as of `AlbumPickerView`. This is what the
    /// confirmed design's chip row reads from.
    @Published private(set) var selectedSources: [SelectedSource] = []

    /// How many distinct songs the current selection resolves to, before
    /// "Build Mix" is even tapped — added 2026-08-14, real-device feedback
    /// asked for a way to compare "how many songs did I pick" against "how
    /// many actually made it into the finished mix" without waiting for a
    /// full build. Recomputed via `MediaLibraryResolver` (the exact same
    /// resolution/de-duplication `MixBuilder` uses, moved into its own
    /// shared type specifically so this preview and the real build can't
    /// drift apart) any time `selectedSources`/`useWholeLibrary` changes.
    /// `nil` for "whole library" (never resolved this way — see
    /// `refreshPreviewSongCount`) or while nothing is selected.
    @Published private(set) var previewSongCount: Int?

    var hasSelection: Bool { useWholeLibrary || !selectedSources.isEmpty }

    func selectedCount(for type: SourceType) -> Int {
        selectedSources.filter { $0.type == type }.count
    }

    func isSelected(_ source: SelectedSource) -> Bool {
        selectedSources.contains(source)
    }

    /// Ticking any per-source checkbox implicitly clears "whole library" —
    /// the two are mutually exclusive per the confirmed design (picking
    /// "All Songs" clears the chip row and grays out the category rows;
    /// this is that same rule working in the other direction).
    func toggle(_ source: SelectedSource) {
        useWholeLibrary = false
        if let index = selectedSources.firstIndex(of: source) {
            selectedSources.remove(at: index)
        } else {
            selectedSources.append(source)
        }
        refreshPreviewSongCount()
    }

    /// Re-runs the same `MPMediaQuery` resolution `MixBuilder` will run at
    /// Build Mix time, purely for the live count — synchronous and local
    /// (no network, no analysis), so recomputing on every selection change
    /// is cheap at personal-library scale. `useWholeLibrary` has no source
    /// list to resolve (it was never modeled as a `SelectedSource`, see
    /// `MediaLibraryResolver`'s own doc comment), so the count is `nil`
    /// rather than a misleading 0.
    private func refreshPreviewSongCount() {
        guard !useWholeLibrary, !selectedSources.isEmpty else {
            previewSongCount = nil
            return
        }
        previewSongCount = MediaLibraryResolver.resolveItems(for: selectedSources).count
    }

    func requestAccessAndLoadCounts() {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:
            authorizationStatus = .authorized
            loadCounts()
        case .notDetermined:
            MPMediaLibrary.requestAuthorization { [weak self] status in
                Task { @MainActor in
                    self?.authorizationStatus = status
                    if status == .authorized {
                        self?.loadCounts()
                    }
                }
            }
        default:
            // .denied / .restricted -- nothing to query; the view reads
            // `authorizationStatus` and shows a plain explanation instead.
            authorizationStatus = MPMediaLibrary.authorizationStatus()
        }
    }

    private func loadCounts() {
        playlistCount = MPMediaQuery.playlists().collections?.count ?? 0
        genreCount = MPMediaQuery.genres().collections?.count ?? 0
        artistCount = MPMediaQuery.artists().collections?.count ?? 0
        albumCount = MPMediaQuery.albums().collections?.count ?? 0
    }

    // MARK: - Hub-level search

    /// **Added 2026-08-15** — the confirmed Source Selection design (see
    /// CLAUDE.md's "Search: one global field on the hub, not per-category,"
    /// revised twice and confirmed 2026-08-02) always specified exactly one
    /// search field living here on the Hub, searching across song titles,
    /// artist/album/genre/playlist names together, surfacing the matching
    /// *source* — never a bare song list, since a song was never itself a
    /// pickable source per ADR-7. That field was designed but never actually
    /// built until now; real-device feedback (Andy: "someone at the event
    /// had some song requests... made it easier to find") is what finally
    /// surfaced the gap. Andy separately asked for a search box inside each
    /// category picker too — a genuinely different, narrower need (filtering
    /// an already-open list) — see each picker's own `searchText`/`filtered...`
    /// addition for that half; this is only the hub-level, cross-category
    /// half of the request.
    struct SearchResult: Identifiable {
        let id: String
        let source: SelectedSource
        /// Set only for a match that came from a *song* title, not a direct
        /// name match — e.g. "via “Autumn Leaves”" under an artist result,
        /// so it's clear why that artist showed up for a query that doesn't
        /// match their name at all.
        let matchDetail: String?
    }

    @Published var searchText: String = ""
    @Published private(set) var searchResults: [SearchResult] = []

    /// Synchronous, local `MPMediaQuery` lookups — same "cheap at personal-
    /// library scale, no network" reasoning `refreshPreviewSongCount` above
    /// already relies on. Direct name matches (genre/artist/album/playlist)
    /// are searched first, then song titles — a song match surfaces its
    /// artist, album, and genre as separate, individually-selectable
    /// results, each tagged with which song matched, since the song itself
    /// was never a source `MixBuilder` can resolve. Capped to 40 results so
    /// a very broad query (e.g. a single common letter) doesn't produce an
    /// unusably long list.
    func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        let lower = query.lowercased()
        var results: [SearchResult] = []
        var seenIDs = Set<String>()

        func add(_ source: SelectedSource, detail: String? = nil) {
            guard !seenIDs.contains(source.id) else { return }
            seenIDs.insert(source.id)
            results.append(SearchResult(id: source.id, source: source, matchDetail: detail))
        }

        for collection in MPMediaQuery.genres().collections ?? [] {
            guard let name = collection.representativeItem?.genre, name.lowercased().contains(lower) else { continue }
            add(SelectedSource(id: "genre:\(name)", type: .genre, label: name))
        }
        for collection in MPMediaQuery.artists().collections ?? [] {
            guard let item = collection.representativeItem, let name = item.artist, name.lowercased().contains(lower) else { continue }
            add(SelectedSource(id: "artist:\(item.artistPersistentID)", type: .artist, label: name, persistentID: item.artistPersistentID))
        }
        for collection in MPMediaQuery.albums().collections ?? [] {
            guard let item = collection.representativeItem, let title = item.albumTitle, title.lowercased().contains(lower) else { continue }
            add(SelectedSource(id: "album:\(item.albumPersistentID)", type: .album, label: title, persistentID: item.albumPersistentID))
        }
        for collection in MPMediaQuery.playlists().collections ?? [] {
            guard let playlist = collection as? MPMediaPlaylist, let name = playlist.name, name.lowercased().contains(lower) else { continue }
            add(SelectedSource(id: "playlist:\(playlist.persistentID)", type: .playlist, label: name, persistentID: playlist.persistentID))
        }

        let songQuery = MPMediaQuery.songs()
        songQuery.addFilterPredicate(MPMediaPropertyPredicate(value: query, forProperty: MPMediaItemPropertyTitle, comparisonType: .contains))
        for item in (songQuery.items ?? []).prefix(25) {
            let songTitle = item.title ?? query
            if let artist = item.artist, !artist.isEmpty {
                add(SelectedSource(id: "artist:\(item.artistPersistentID)", type: .artist, label: artist, persistentID: item.artistPersistentID), detail: "via “\(songTitle)”")
            }
            if let album = item.albumTitle, !album.isEmpty {
                add(SelectedSource(id: "album:\(item.albumPersistentID)", type: .album, label: album, persistentID: item.albumPersistentID), detail: "via “\(songTitle)”")
            }
            if let genre = item.genre, !genre.isEmpty {
                add(SelectedSource(id: "genre:\(genre)", type: .genre, label: genre), detail: "via “\(songTitle)”")
            }
        }

        // **Added 2026-08-15** — real-device testing found an artist Andy
        // knows is in his library ("Shalamar") came back with zero matches,
        // even though the direct `MPMediaQuery.artists()` loop above should
        // have caught it. Leading hypothesis, not yet confirmed against
        // Andy's real library: `MPMediaQuery.artists()` groups by each
        // track's own `MPMediaItemPropertyArtist` tag — if a track's Artist
        // field reads something else (e.g. a compilation tagged "Various
        // Artists" at the track level with the real performer only in Album
        // Artist), that artist never gets its own top-level grouping there
        // at all, direct-name match or not. This second query searches
        // `MPMediaItemPropertyArtist` on individual songs directly (not
        // through the `.artists()` grouping), so an artist missing from that
        // grouping for this reason is still findable via any track that
        // actually carries their name in its own Artist field.
        let artistSongQuery = MPMediaQuery.songs()
        artistSongQuery.addFilterPredicate(MPMediaPropertyPredicate(value: query, forProperty: MPMediaItemPropertyArtist, comparisonType: .contains))
        for item in (artistSongQuery.items ?? []).prefix(25) {
            guard let artist = item.artist, !artist.isEmpty else { continue }
            add(SelectedSource(id: "artist:\(item.artistPersistentID)", type: .artist, label: artist, persistentID: item.artistPersistentID))
        }

        searchResults = Array(results.prefix(40))
    }
}
