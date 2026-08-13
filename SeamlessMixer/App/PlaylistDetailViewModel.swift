import Foundation
import PlaylistCore

/// One track row as displayed on Playlist Detail — position, title, artist,
/// formatted duration. Flattened from `PlaylistCore`'s `PlaylistTrackDetail`
/// (which carries the full `Track`) since the view only needs display
/// fields, not the whole record. `trackPersistentID`, `crossfadeStartOffsetSec`,
/// `crossfadeDurationSec`, and `playableStartSec` are the exceptions — not
/// displayed, but needed to build a real `PlaybackEngine.QueuedTrack`: which
/// file to resolve, when this track's blend into the next one should begin,
/// how long that blend lasts, and how much leading silence to skip.
struct PlaylistDetailRow: Identifiable {
    let id: Int64
    let position: Int
    let title: String
    let artist: String
    let durationText: String
    let trackPersistentID: Int64
    let crossfadeStartOffsetSec: Double
    let crossfadeDurationSec: Double
    let playableStartSec: Double
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
                    durationText: Self.formatDuration(entry.track.durationSec),
                    trackPersistentID: entry.track.persistentID,
                    crossfadeStartOffsetSec: entry.crossfadeStartOffsetSec,
                    crossfadeDurationSec: entry.crossfadeDurationSec,
                    playableStartSec: entry.track.playableStartSec ?? 0
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

    /// Manual drag-to-reorder, the other half of Tier 3's editability fix
    /// (`removeTrack` above did the first half). Reorders `rows` locally
    /// first — an instant, optimistic UI update the same instant `List`'s
    /// own `.onMove` animation completes, matching the `isFavorite`/
    /// `displayName` local-state pattern `PlaylistDetailView` already uses
    /// elsewhere — then persists the same order via `PlaylistStore` without
    /// waiting for or reloading from that write, since `rows` already
    /// reflects the intended end state.
    ///
    /// Rebuilds each row with a recomputed `position` (0...n-1 in the new
    /// order) so the displayed "1, 2, 3..." index column stays correct —
    /// `PlaylistDetailRow.position` is a `let`, so this can't just mutate
    /// the moved elements in place.
    func moveTracks(from source: IndexSet, to destination: Int, playlist: Playlist, store: PlaylistStore) {
        let previousOrder = rows.map(\.id)

        rows.move(fromOffsets: source, toOffset: destination)
        rows = rows.enumerated().map { index, row in
            PlaylistDetailRow(
                id: row.id, position: index, title: row.title, artist: row.artist,
                durationText: row.durationText, trackPersistentID: row.trackPersistentID,
                crossfadeStartOffsetSec: row.crossfadeStartOffsetSec,
                crossfadeDurationSec: row.crossfadeDurationSec,
                playableStartSec: row.playableStartSec
            )
        }

        // `.onMove` can fire for a drag that ends up back at the same final
        // order (e.g. a source row dropped immediately before/after its own
        // original position resolves to an identical sequence) -- skip the
        // write in that case rather than persisting a no-op.
        let newOrder = rows.map(\.id)
        guard newOrder != previousOrder, let playlistID = playlist.id else { return }
        store.reorderTracks(playlistID: playlistID, orderedPlaylistTrackIDs: newOrder)
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
