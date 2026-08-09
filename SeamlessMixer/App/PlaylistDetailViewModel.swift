import Foundation
import PlaylistCore

/// One track row as displayed on Playlist Detail — position, title, artist,
/// formatted duration. Flattened from `PlaylistCore`'s `PlaylistTrackDetail`
/// (which carries the full `Track`) since the view only needs display
/// fields, not the whole record.
struct PlaylistDetailRow: Identifiable {
    let id: Int64
    let position: Int
    let title: String
    let artist: String
    let durationText: String
}

@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    @Published private(set) var rows: [PlaylistDetailRow] = []
    @Published private(set) var subtitle: String = ""
    @Published private(set) var footerText: String = ""
    @Published private(set) var isLoading = true

    /// Local SQLite reads through GRDB are fast enough that this runs
    /// synchronously on the main actor, same pattern `PlaylistStore.refresh()`
    /// already uses — no need for a detached `Task` the way `MixBuilder`'s
    /// real decode/analyze work needs one.
    func load(playlist: Playlist, store: PlaylistStore) {
        guard let db = store.db, let playlistID = playlist.id else {
            isLoading = false
            return
        }

        do {
            let detail = try db.loadPlaylistDetail(playlistID: playlistID)

            rows = detail.tracks.map { entry in
                PlaylistDetailRow(
                    id: entry.id,
                    position: entry.position,
                    title: entry.track.title,
                    artist: entry.track.artist,
                    durationText: Self.formatDuration(entry.track.durationSec)
                )
            }

            let totalDuration = detail.tracks.reduce(0) { $0 + $1.track.durationSec }
            subtitle = PlaylistNaming.subtitle(
                for: detail.sources, mode: playlist.mode,
                songCount: rows.count, durationSec: totalDuration
            )

            let sourceLabel = detail.sources.map(\.sourceLabel).joined(separator: ", ")
            let dateText = Self.dateFormatter.string(from: playlist.createdAt)
            footerText = sourceLabel.isEmpty
                ? "Created \(dateText)"
                : "Created \(dateText) · refreshes from \(sourceLabel)"
        } catch {
            // Leave rows empty -- the view's own "no tracks yet" state
            // covers this case too; a load failure and a genuinely empty
            // playlist look the same to the user here, which is an
            // acceptable simplification for this first pass (no distinct
            // error state on this screen yet, unlike My Mixes' errorState).
        }

        isLoading = false
    }

    /// Tier 3 editability fix — removes one track via `PlaylistStore`, then
    /// reloads so the track list, subtitle (song count/duration), and
    /// footer all reflect the change immediately. Mirrors the sheet's
    /// `onDismiss: { viewModel.load(...) }` pattern already used for
    /// Rename/Refresh, just triggered directly instead of via a sheet.
    func removeTrack(row: PlaylistDetailRow, playlist: Playlist, store: PlaylistStore) {
        guard let playlistID = playlist.id else { return }
        store.removeTrack(playlistTrackID: row.id, fromPlaylistID: playlistID)
        load(playlist: playlist, store: store)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()
}
