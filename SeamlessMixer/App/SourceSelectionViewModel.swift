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
    /// **Added 2026-09-09** — set true only when this source was picked
    /// while "Use your whole library" was active, in which case it means
    /// *leave this out of* the whole library rather than *combine it with*
    /// other picks. `MixBuilder`/`MediaLibraryResolver` don't actually need
    /// this to resolve correctly (the whole `selectedSources` list is
    /// interpreted as exclusions or inclusions together, based on
    /// `useWholeLibrary` at Build Mix time) — it exists so `persist(...)`
    /// can carry the right meaning into each individual `PlaylistSource`
    /// row it writes (see that type's own `isExclusion` doc comment), since
    /// a whole-library build's saved sources are a mix of one real base row
    /// and N exclusion rows in the same array.
    var isExclusion: Bool = false

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
    /// **Added 2026-08-16** alongside `SongPickerView`, the fifth and last
    /// confirmed category picker (Playlist/Songs/Genre/Artist/Album, per
    /// ADR-7).
    @Published private(set) var songCount: Int = 0
    /// **Added 2026-09-10**, per Andy's "whole library usable count" request
    /// (backlog item logged 0.25.81). `songCount` above is a raw
    /// `MPMediaQuery` count with no awareness of whether a track is actually
    /// downloaded/DRM-free/analyzed — so a "Use your whole library" build
    /// routinely includes fewer songs than that number, with the real
    /// figure only ever surfacing in the after-the-fact exclusion alert.
    /// This is the count of tracks the app has already scanned and confirmed
    /// it can actually mix (`has_raw_audio_access = 1` and analyzed) — data
    /// that already exists post-scan. `nil` until a scan has completed
    /// (`LibraryScanner.hasCompletedAnyScan`), since before that the number
    /// is just "however few tracks happen to be in the DB" and misleading.
    @Published private(set) var wholeLibraryReadyCount: Int?
    /// **Added 2026-09-07** — how many tracks are currently marked favorite
    /// (`Track.isFavorite`), shown on the Hub's pinned Favourites row. Reads
    /// this app's own database, not `MediaPlayer` — the first count here to
    /// do so, which is why this view model now needs `store` at all (see
    /// `attach(store:)`).
    @Published private(set) var favoriteSongsCount: Int = 0

    /// **Added 2026-09-08 (Testing 67)** — every currently-favourited
    /// track's own `persistentID`, needed to compute the Favourites row's
    /// "N selected" badge *correctly*, separately from the plain Songs
    /// row's. Both rows pick individual songs via the identical `.songs`
    /// source type (per `categoryRows`' own doc comment — a deliberate,
    /// documented trade-off), which made the Favourites badge quietly wrong
    /// in practice: Andy picked 4 (his only 4) favourited songs via this
    /// row, then 2 more, non-favourited songs via the plain Songs row — and
    /// *both* rows showed "6 selected," implying all 6 were favourites when
    /// only 4 were. See `selectedFavoriteSongsCount` below for the actual
    /// fix.
    @Published private(set) var favoriteSongPersistentIDs: Set<Int64> = []

    /// **Added 2026-09-07**, alongside `favoriteSongsCount`/`.favoriteSongs`
    /// — this view model had no database access at all before now (every
    /// prior count/selection came purely from `MediaPlayer`). Set once via
    /// `attach(store:)` from `SourceSelectionHubView`'s `.onAppear`, the
    /// same "thread it in after construction, not through `@StateObject`'s
    /// own init expression" pattern already used elsewhere in this app
    /// (e.g. `PlaylistDetailViewModel.load(playlist:store:)`), rather than
    /// risking a `@StateObject` initial-value expression that reads another
    /// of this view's own stored properties before Swift guarantees it's
    /// set.
    private var store: PlaylistStore?

    func attach(store: PlaylistStore) {
        self.store = store
        loadCustomPlaylists()
    }

    /// **Added 2026-09-07, Batch 2** — every saved `CustomPlaylist` (the new
    /// native-playlist concept), merged into `PlaylistPickerView`'s grid
    /// alongside real Apple Music playlists. Loaded once on `attach(store:)`
    /// and again via `refreshCustomPlaylists()` after anything that could
    /// change the list (a new one created, one renamed/deleted, or a copy-
    /// on-edit just ran) — `PlaylistPickerView` itself has no independent
    /// database access, so it can't refresh this on its own the way
    /// `PlaylistStore.refresh()` covers `Playlist` rows for My Mixes.
    @Published private(set) var customPlaylists: [CustomPlaylist] = []

    func refreshCustomPlaylists() {
        loadCustomPlaylists()
    }

    private func loadCustomPlaylists() {
        guard let db = store?.db else { return }
        customPlaylists = (try? db.loadCustomPlaylists()) ?? []
    }

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

    /// **Added 2026-08-19**, per Andy's direct request ("can the crossfade
    /// be extended... a time setting how long this can be, regulatable")
    /// — extra seconds added on top of each transition's own tempo-derived
    /// crossfade length (see `CrossfadeTiming.durationSec(forBPM:extraSec:)`).
    /// Andy specifically asked for this "in conjunction with Mode," i.e. a
    /// Hub control living right alongside it, not a hidden global default —
    /// see `SourceSelectionHubView.modePicker`.
    ///
    /// **Persisted across builds, 2026-08-22** — this used to reset to 0
    /// every time this screen loaded, per Andy's own direct report: "it
    /// gets tiresome if you have to always tap the buttons to 5s every
    /// time you go a build and forget to set them." Now initialized from
    /// (and saved to) `UserDefaults` on every change, so whatever value was
    /// last used is what a fresh Build Mix starts from -- a genuinely new
    /// install still starts at 0 (today's exact behavior, since nothing's
    /// been saved yet), matching the "preserve existing behavior until the
    /// user actually opts in" convention this project already uses
    /// elsewhere. **Mode does NOT get this same treatment** -- despite
    /// Andy's framing ("permanent just like the mode"), `mode` above
    /// actually resets to `.energyWave` every time too; flagged to him
    /// directly rather than assumed, since fixing this one alone doesn't
    /// actually match his stated mental model of how Mode behaves.
    @Published var extraCrossfadeSec: Double = SourceSelectionViewModel.loadPersistedExtraCrossfadeSec() {
        didSet {
            UserDefaults.standard.set(extraCrossfadeSec, forKey: Self.extraCrossfadeSecDefaultsKey)
        }
    }

    private static let extraCrossfadeSecDefaultsKey = "sourceSelection.extraCrossfadeSec"

    private static func loadPersistedExtraCrossfadeSec() -> Double {
        UserDefaults.standard.object(forKey: extraCrossfadeSecDefaultsKey) as? Double ?? 0
    }

    /// True once "Use your whole library" is picked.
    ///
    /// **Revised 2026-09-09, per Andy's direct request** — the four (five,
    /// counting Songs) category rows used to gray out and disable entirely
    /// the moment this was on, since combining "everything" with more
    /// inclusions was redundant. They no longer do: a pick made while this
    /// is active now means *exclude that from the whole library* instead of
    /// *include it alongside everything*, so picking is still useful here —
    /// "there are 2 ways of selecting things... selecting everything and
    /// excluding some... the faster way will be better option depending on
    /// the goal." `selectedSources` is still cleared whenever this flag
    /// *changes*, in either direction (not just when turning on, as
    /// before) — a batch of picks means something different depending on
    /// which mode they were made in (inclusions vs. exclusions), so
    /// carrying them across a mode switch would silently reinterpret what
    /// the user meant rather than just starting the new mode fresh.
    @Published var useWholeLibrary: Bool = false {
        didSet {
            guard oldValue != useWholeLibrary else { return }
            selectedSources.removeAll()
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
    /// `nil` while nothing is selected, including plain "whole library"
    /// with no exclusions yet — see `refreshPreviewSongCount`'s own doc
    /// comment for exactly when this is (and isn't) computed.
    @Published private(set) var previewSongCount: Int?

    /// **Added 2026-08-20**, per Andy's direct request — "you are planning
    /// an event for e.g. maybe 65 minutes and want to select an amount of
    /// songs to fit that event in advance... a way of adding more value to
    /// the SelectionHubView screen." Computed in the same pass as
    /// `previewSongCount` (same resolved item list, no second query) by
    /// summing each resolved item's own `playbackDuration`. `nil` under
    /// the exact same conditions as `previewSongCount`.
    @Published private(set) var previewTotalMinutes: Int?

    var hasSelection: Bool { useWholeLibrary || !selectedSources.isEmpty }

    func selectedCount(for type: SourceType) -> Int {
        selectedSources.filter { $0.type == type }.count
    }

    /// **Added 2026-09-08 (Testing 67)** — the actual fix for the
    /// Favourites badge bug described on `favoriteSongPersistentIDs`' own
    /// doc comment: counts only the currently-selected `.songs` sources
    /// whose track is a genuine favourite, not every `.songs` selection
    /// regardless of origin (that's what `selectedCount(for: .songs)`
    /// already correctly reports, and is left alone — the plain Songs row
    /// is supposed to show the shared total).
    var selectedFavoriteSongsCount: Int {
        selectedSources.filter { source in
            guard source.type == .songs, let persistentID = source.persistentID else { return false }
            return favoriteSongPersistentIDs.contains(Int64(bitPattern: persistentID))
        }.count
    }

    func isSelected(_ source: SelectedSource) -> Bool {
        selectedSources.contains(source)
    }

    /// **Revised 2026-09-09** — this used to force `useWholeLibrary = false`
    /// on every call, back when the two were strictly mutually exclusive.
    /// They no longer are: picking a source while "whole library" is active
    /// now means excluding it, a real, meaningful selection in that mode,
    /// not something that should silently cancel the mode itself. Whichever
    /// mode is active when a source is toggled determines what it means
    /// (see `useWholeLibrary`'s own doc comment for how a mode switch clears
    /// `selectedSources` instead, so the two meanings never mix within one
    /// list).
    func toggle(_ source: SelectedSource) {
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
    /// is cheap at personal-library scale. `nil` (no preview line shown)
    /// whenever there's genuinely nothing to preview yet: plain "whole
    /// library" with no exclusions (a raw library scan, same cost as
    /// `allSongs()` itself, not worth running just to restate the Songs
    /// row's own count), or no selection at all.
    ///
    /// **Extended 2026-09-09** — a whole-library pick with one or more
    /// exclusions now gets a real preview too: the full library, minus
    /// whatever the current exclusion picks resolve to, mirroring exactly
    /// what `MixBuilder.performBuild`'s own whole-library-minus-exclusions
    /// branch will do at Build Mix time.
    private func refreshPreviewSongCount() {
        guard !selectedSources.isEmpty else {
            previewSongCount = nil
            previewTotalMinutes = nil
            return
        }
        let items: [MPMediaItem]
        if useWholeLibrary {
            let excluded = MediaLibraryResolver.resolveItems(for: selectedSources, db: store?.db)
            let excludedIDs = Set(excluded.map(\.persistentID))
            items = MediaLibraryResolver.allSongs().filter { !excludedIDs.contains($0.persistentID) }
        } else {
            items = MediaLibraryResolver.resolveItems(for: selectedSources, db: store?.db)
        }
        previewSongCount = items.count
        let totalSeconds = items.reduce(0.0) { $0 + $1.playbackDuration }
        previewTotalMinutes = Int((totalSeconds / 60).rounded())
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
        songCount = MPMediaQuery.songs().items?.count ?? 0
        loadFavoriteSongsCount()
        loadWholeLibraryReadyCount()
    }

    /// See `wholeLibraryReadyCount`'s own doc comment. Best-effort: any
    /// failure (or no scan yet) just leaves it `nil`, and the Hub simply
    /// doesn't show the "ready to mix" line — no error state for a hint.
    private func loadWholeLibraryReadyCount() {
        guard LibraryScanner.hasCompletedAnyScan, let db = store?.db else {
            wholeLibraryReadyCount = nil
            return
        }
        let count: Int? = try? db.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: """
                SELECT COUNT(*) FROM tracks
                WHERE has_raw_audio_access = 1
                  AND analyzed_at IS NOT NULL
                  AND playable_duration_sec IS NOT NULL
                """)
        }
        wholeLibraryReadyCount = count
    }

    /// **Added 2026-09-07** — reads `tracks.is_favorite` directly (raw SQL,
    /// same convention as `MediaLibraryResolver`'s own `.favoriteSongs`
    /// case). Best-effort: a `nil` `store`/`db` or a query failure just
    /// leaves the count at 0 rather than surfacing a separate error state
    /// for what's a small, non-critical display number.
    private func loadFavoriteSongsCount() {
        guard let db = store?.db else { return }
        let count: Int? = try? db.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM tracks WHERE is_favorite = 1")
        }
        favoriteSongsCount = count ?? 0
        // **Added 2026-09-08** alongside the count above — see
        // `favoriteSongPersistentIDs`' own doc comment for why this is
        // needed too, not just the aggregate count.
        let ids: [Int64] = (try? db.dbQueue.read { conn in
            try Int64.fetchAll(conn, sql: "SELECT persistent_id FROM tracks WHERE is_favorite = 1")
        }) ?? []
        favoriteSongPersistentIDs = Set(ids)
    }

    // MARK: - Hub-level search

    /// **Added 2026-08-15** — the confirmed Source Selection design (see
    /// CLAUDE.md's "Search: one global field on the hub, not per-category,"
    /// revised twice and confirmed 2026-08-02) always specified exactly one
    /// search field living here on the Hub, searching across song titles,
    /// artist/album/genre/playlist names together, surfacing the matching
    /// *source*. That field was designed but never actually built until
    /// now; real-device feedback (Andy: "someone at the event had some song
    /// requests... made it easier to find") is what finally surfaced the
    /// gap. Andy separately asked for a search box inside each category
    /// picker too — a genuinely different, narrower need (filtering an
    /// already-open list) — see each picker's own `searchText`/`filtered...`
    /// addition for that half; this is only the hub-level, cross-category
    /// half of the request.
    ///
    /// **A song-title match itself became a directly selectable result
    /// 2026-08-16**, once `.songs` (individual song picks) became a real,
    /// resolvable source type via `SongPickerView` — previously a song
    /// match here could only surface its artist/album/genre, since a song
    /// was never itself a pickable source per ADR-7 at the time this was
    /// written.
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
            // The song itself, now that `.songs` (individual song picks)
            // is a real, resolvable source as of 2026-08-16 -- added
            // alongside its artist/album/genre (below), not in place of
            // them, since a song title match is still useful evidence for
            // "maybe you meant this whole artist/album/genre" too.
            add(SelectedSource(id: "songs:\(item.persistentID)", type: .songs, label: songTitle, persistentID: item.persistentID))
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
