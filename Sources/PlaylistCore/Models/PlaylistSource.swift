import Foundation
import GRDB

/// One row per source selected for a playlist — replaces a single
/// `source_type`/`source_identifier` pair on `playlists` per CLAUDE.md's
/// 2026-08-02 revision: a playlist can combine multiple sources (e.g. two
/// genres, or a genre + an artist), not just one. Row count is what
/// distinguishes a "continuous" (1 source) mix from a "combination" mix.
public enum SourceType: String, Codable, CaseIterable, Hashable, DatabaseValueConvertible {
    case playlist
    case songs
    case genre
    case artist
    case album
    /// **Added 2026-08-20** — "Use your whole library," previously modeled
    /// only as `SourceSelectionViewModel.useWholeLibrary`, a boolean never
    /// persisted anywhere (per every other case's own doc comments, which
    /// used to say "whole library... was never modeled as a `SelectedSource`
    /// at all"). Getting a real `Playlist` built from it, and later
    /// refreshed, needs a real stored source to reconstruct from — this is
    /// that. `sourceValue` carries no persistentID (there's nothing to
    /// look up; `MediaLibraryResolver.allSongs()` takes no filter), so it
    /// just mirrors `sourceLabel` ("Whole Library"), same as `.genre`'s
    /// name-is-the-key convention. Raw value deliberately `"library"`, not
    /// `"wholeLibrary"` — `PlaylistNaming.subtitle`'s `.rawValue.capitalized`
    /// only capitalizes the first letter, so a camelCase raw value would
    /// have rendered as the awkward "Wholelibrary" in a real subtitle.
    case wholeLibrary = "library"
}

public struct PlaylistSource: Codable, Equatable, Identifiable {
    public var id: Int64?
    public var playlistID: Int64
    public var sourceType: SourceType
    /// A genre name, or an artist's/playlist's/album's persistent ID as a string.
    public var sourceValue: String
    /// Human-readable display form (e.g. an artist's name, not their raw ID) —
    /// stored so subtitles and "Refresh" don't need a separate lookup.
    public var sourceLabel: String

    public init(id: Int64? = nil, playlistID: Int64, sourceType: SourceType, sourceValue: String, sourceLabel: String) {
        self.id = id
        self.playlistID = playlistID
        self.sourceType = sourceType
        self.sourceValue = sourceValue
        self.sourceLabel = sourceLabel
    }
}

extension PlaylistSource: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlist_sources"

    public enum Columns: String, ColumnExpression {
        case id
        case playlistID = "playlist_id"
        case sourceType = "source_type"
        case sourceValue = "source_value"
        case sourceLabel = "source_label"
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        playlistID = row[Columns.playlistID]
        sourceType = row[Columns.sourceType]
        sourceValue = row[Columns.sourceValue]
        sourceLabel = row[Columns.sourceLabel]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.playlistID] = playlistID
        container[Columns.sourceType] = sourceType
        container[Columns.sourceValue] = sourceValue
        container[Columns.sourceLabel] = sourceLabel
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Derives the auto-generated title/subtitle from a playlist's sources, per
/// CLAUDE.md's "Auto-naming logic": 1 source names itself directly, 2 sources
/// join as "A + B", 3+ falls back to "Custom Seamless Mix".
public enum PlaylistNaming {
    public static func title(for sources: [PlaylistSource]) -> String {
        switch sources.count {
        case 0:
            return "Seamless Mix"
        case 1:
            return "\(sources[0].sourceLabel) Seamless Mix"
        case 2:
            return "\(sources[0].sourceLabel) + \(sources[1].sourceLabel) Seamless Mix"
        default:
            return "Custom Seamless Mix"
        }
    }

    /// - Parameters:
    ///   - songCount: final count after sequencing — only known post-build.
    ///   - durationSec: final duration after sequencing — only known post-build.
    public static func subtitle(for sources: [PlaylistSource], mode: PlaylistMode, songCount: Int, durationSec: Double) -> String {
        let minutes = Int((durationSec / 60).rounded())
        let durationText = "\(minutes) min"
        let countText = "\(songCount) songs"

        switch sources.count {
        case 1:
            let typeLabel = sources[0].sourceType.rawValue.capitalized
            return "\(typeLabel) · \(sources[0].sourceLabel) · \(mode.displayName) · \(countText) · \(durationText)"
        case 2:
            let values = sources.map(\.sourceLabel).joined(separator: ", ")
            return "\(sources[0].sourceType.rawValue.capitalized)s · \(values) · \(mode.displayName) · \(countText) · \(durationText)"
        default:
            return "\(sources.count) sources · \(mode.displayName) · \(countText) · \(durationText)"
        }
    }
}
