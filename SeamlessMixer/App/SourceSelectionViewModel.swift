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
struct SelectedSource: Identifiable {
    let id: String
    let type: SourceType
    let label: String
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

    /// True once "Use your whole library" is picked — per the confirmed
    /// design, this clears/disables the four category rows since combining
    /// it with anything else is redundant.
    @Published var useWholeLibrary: Bool = false {
        didSet {
            if useWholeLibrary { selectedSources.removeAll() }
        }
    }

    /// Real per-category picks, populated live as checkboxes are ticked on
    /// a category picker screen — all four (Genres, Playlists, Artists,
    /// Albums) are real pickers as of `AlbumPickerView`. This is what the
    /// confirmed design's chip row reads from.
    @Published private(set) var selectedSources: [SelectedSource] = []

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
}
