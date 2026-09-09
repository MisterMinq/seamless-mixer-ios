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
    /// **Added 2026-09-07** — per Andy's direct request/confirmation: a
    /// pinned Hub row pulling every track marked favorite (`Track
    /// .isFavorite`, added the same session), scoped to individual songs
    /// only ("Let's limit favourites to songs for now"). Unlike
    /// `.wholeLibrary`, this is a regular, *combinable* source — you can
    /// genuinely want Favourites plus a specific genre or artist in the
    /// same mix, so it's modeled as an ordinary toggleable `SelectedSource`
    /// (like `.genre`), not an exclusive all-or-nothing flag. `sourceValue`
    /// carries no persistentID (nothing to look up — `MediaLibraryResolver`
    /// just queries `tracks.is_favorite` directly), same "value mirrors
    /// label" convention `.wholeLibrary` already uses.
    case favoriteSongs = "favorites"
    /// **Added 2026-09-07, Batch 2** — a saved `CustomPlaylist` (the new
    /// native-playlist concept, see that type's own doc comment) picked as
    /// a Build Mix source. Resolved via `MediaLibraryResolver`'s
    /// `.customPlaylist` case, which reads `custom_playlist_tracks`
    /// directly (this app's own database), not `MediaPlayer`. Modeled the
    /// same way `.playlist`/`.artist`/`.album` already are — a
    /// `SelectedSource.persistentID` carries the lookup key, here the
    /// `CustomPlaylist`'s own `Int64` row id bit-cast into the same
    /// `MPMediaEntityPersistentID` field every real Apple Music source
    /// already uses that field for (a deliberate field-reuse choice, not a
    /// new one — avoids widening `SelectedSource`/`PlaylistSource` for a
    /// single extra case). Raw value deliberately `"custom playlist"`, not
    /// the implicit camelCase `"customPlaylist"` — same reasoning as
    /// `.wholeLibrary`'s own raw-value comment: `PlaylistNaming.subtitle`'s
    /// `.rawValue.capitalized` needs real word boundaries to work with, and
    /// Foundation's `.capitalized` actually *lowercases* the rest of a
    /// single unbroken word (so the implicit raw value would have rendered
    /// as "Customplaylist," not "CustomPlaylist") — a space gives it two
    /// real words to capitalize, producing "Custom Playlist" instead.
    case customPlaylist = "custom playlist"
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
    /// **Added 2026-09-09** — per Andy's direct request: when a playlist was
    /// built with "Use your whole library" active, every *other* row picked
    /// alongside it means *leave this out*, not *also include this* — the
    /// opposite of what a normal combination of sources means. `false` for
    /// every source type other than the one synthetic `.wholeLibrary` row
    /// itself and whatever's picked alongside it in that mode; always
    /// `false` for an ordinary (non-whole-library) build, which still means
    /// exactly what it always has. See `PlaylistNaming` below for how this
    /// changes the auto-generated name/subtitle, and `MixBuilder
    /// .performBuild`'s whole-library branch for how the exclusion actually
    /// gets applied to the resolved pool.
    public var isExclusion: Bool

    public init(id: Int64? = nil, playlistID: Int64, sourceType: SourceType, sourceValue: String, sourceLabel: String, isExclusion: Bool = false) {
        self.id = id
        self.playlistID = playlistID
        self.sourceType = sourceType
        self.sourceValue = sourceValue
        self.sourceLabel = sourceLabel
        self.isExclusion = isExclusion
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
        case isExclusion = "is_exclusion"
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        playlistID = row[Columns.playlistID]
        sourceType = row[Columns.sourceType]
        sourceValue = row[Columns.sourceValue]
        sourceLabel = row[Columns.sourceLabel]
        isExclusion = row[Columns.isExclusion]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.playlistID] = playlistID
        container[Columns.sourceType] = sourceType
        container[Columns.sourceValue] = sourceValue
        container[Columns.sourceLabel] = sourceLabel
        container[Columns.isExclusion] = isExclusion
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Derives the auto-generated title/subtitle from a playlist's sources, per
/// CLAUDE.md's "Auto-naming logic": 1 source names itself directly, 2 sources
/// join as "A + B", 3+ falls back to "Custom Seamless Mix".
public enum PlaylistNaming {
    /// **Added 2026-09-09** — a whole-library build with one or more
    /// exclusion sources needs its own naming shape, since the plain
    /// count-based cases below were never designed for a "base source +
    /// N things to leave out" structure (a whole library plus 2 excluded
    /// genres has `sources.count == 3`, which would otherwise fall into the
    /// generic "3 sources" combination case below and read as if all 3 were
    /// being *included* together). Deliberately checked before, not folded
    /// into, the count-based switch — an ordinary whole-library build with
    /// *no* exclusions has exactly one source and correctly keeps falling
    /// through to `case 1` unchanged, matching every playlist already built
    /// this way before exclusions existed.
    private static func exclusionBase(in sources: [PlaylistSource]) -> (base: PlaylistSource, exclusions: [PlaylistSource])? {
        let exclusions = sources.filter(\.isExclusion)
        guard !exclusions.isEmpty, let base = sources.first(where: { $0.sourceType == .wholeLibrary }) else { return nil }
        return (base, exclusions)
    }

    public static func title(for sources: [PlaylistSource]) -> String {
        if let (base, exclusions) = exclusionBase(in: sources) {
            if exclusions.count == 1 {
                return "\(base.sourceLabel) (excluding \(exclusions[0].sourceLabel)) Seamless Mix"
            }
            return "\(base.sourceLabel) (excluding \(exclusions.count) sources) Seamless Mix"
        }
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

        if let (base, exclusions) = exclusionBase(in: sources) {
            let excludedLabels = exclusions.map(\.sourceLabel).joined(separator: ", ")
            return "\(base.sourceLabel) · excluding \(excludedLabels) · \(mode.displayName) · \(countText) · \(durationText)"
        }

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
