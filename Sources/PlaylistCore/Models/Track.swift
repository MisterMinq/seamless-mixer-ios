import Foundation
import GRDB

/// One row per track the app has ever seen in the library.
/// Mirrors CLAUDE.md's "Data Model — SQLite Schema" `tracks` table exactly —
/// keep the two in sync; if a column changes here, update that section too
/// (per Rule 2's iOS-codebase extension).
public struct Track: Codable, Equatable, Identifiable {

    /// Apple's `MPMediaItem.persistentID`, not a locally-invented ID — chosen
    /// because Apple guarantees it stays stable even if the underlying file
    /// moves or gets renamed. Stored as Int64 since `persistentID` is a UInt64
    /// in MediaPlayer; callers must bit-cast, not truncate, when converting.
    public var persistentID: Int64
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String

    /// nil until analysis has run for this track.
    public var bpm: Double?
    /// Camelot wheel code (e.g. "8A"), same convention as Phase 1's `camelot_code`.
    public var musicalKey: String?
    /// Raw RMS energy, unbounded — matches `TrackAnalyzer`'s raw output
    /// directly, **not** rescaled to 0...1 (an earlier version of this
    /// comment assumed otherwise, before `Sequencer` was written and this
    /// got resolved — see `Sequencer.swift`'s "Normalization design note").
    /// Normalization to 0...1 happens ephemerally, per candidate pool, at
    /// sequencing time (`Sequencer.normalizeEnergyAndBrightness`) — not
    /// here, since the "right" normalized value for a track depends on
    /// which other tracks it's being sequenced alongside.
    public var energy: Double?
    /// Raw mean spectral centroid in Hz (acoustic/electric proxy), unbounded
    /// — same "raw, not pre-normalized" caveat as `energy` above.
    public var brightness: Double?
    public var durationSec: Double

    /// False for Apple Music subscription-streamed (FairPlay-protected) tracks —
    /// see "DRM-Exclusion UX" in CLAUDE.md. Checked once at analysis time.
    public var hasRawAudioAccess: Bool

    /// nil until analysis has run; drives "X of Y analyzed" first-run progress.
    public var analyzedAt: Date?

    public var id: Int64 { persistentID }

    public init(
        persistentID: Int64,
        title: String,
        artist: String,
        album: String,
        genre: String,
        bpm: Double? = nil,
        musicalKey: String? = nil,
        energy: Double? = nil,
        brightness: Double? = nil,
        durationSec: Double,
        hasRawAudioAccess: Bool = true,
        analyzedAt: Date? = nil
    ) {
        self.persistentID = persistentID
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.bpm = bpm
        self.musicalKey = musicalKey
        self.energy = energy
        self.brightness = brightness
        self.durationSec = durationSec
        self.hasRawAudioAccess = hasRawAudioAccess
        self.analyzedAt = analyzedAt
    }

    /// True once every analysis field the sequencer needs is populated.
    public var isAnalyzed: Bool {
        bpm != nil && musicalKey != nil && energy != nil && brightness != nil
    }
}

// MARK: - GRDB

extension Track: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tracks"

    public enum Columns: String, ColumnExpression {
        case persistentID = "persistent_id"
        case title
        case artist
        case album
        case genre
        case bpm
        case musicalKey = "musical_key"
        case energy
        case brightness
        case durationSec = "duration_sec"
        case hasRawAudioAccess = "has_raw_audio_access"
        case analyzedAt = "analyzed_at"
    }

    public init(row: Row) throws {
        persistentID = row[Columns.persistentID]
        title = row[Columns.title]
        artist = row[Columns.artist]
        album = row[Columns.album]
        genre = row[Columns.genre]
        bpm = row[Columns.bpm]
        musicalKey = row[Columns.musicalKey]
        energy = row[Columns.energy]
        brightness = row[Columns.brightness]
        durationSec = row[Columns.durationSec]
        hasRawAudioAccess = row[Columns.hasRawAudioAccess]
        analyzedAt = row[Columns.analyzedAt]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.persistentID] = persistentID
        container[Columns.title] = title
        container[Columns.artist] = artist
        container[Columns.album] = album
        container[Columns.genre] = genre
        container[Columns.bpm] = bpm
        container[Columns.musicalKey] = musicalKey
        container[Columns.energy] = energy
        container[Columns.brightness] = brightness
        container[Columns.durationSec] = durationSec
        container[Columns.hasRawAudioAccess] = hasRawAudioAccess
        container[Columns.analyzedAt] = analyzedAt
    }
}
