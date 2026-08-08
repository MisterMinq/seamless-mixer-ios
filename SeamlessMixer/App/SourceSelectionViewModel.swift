import Foundation
import MediaPlayer
import PlaylistCore

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
    /// it with anything else is redundant. Real per-category multi-select
    /// (the chip row) is the Category Picker slice's job, not this one's;
    /// this Hub-only pass only needs to represent "whole library" vs. "none
    /// selected yet" to make the sticky Build Mix bar behave correctly.
    @Published var useWholeLibrary: Bool = false

    var hasSelection: Bool { useWholeLibrary }

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
