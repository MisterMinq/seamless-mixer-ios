import Foundation

/// Counts and describes how many tracks in a candidate pool couldn't be used
/// for seamless mixing — the confirmed DRM-Exclusion UX's "quiet, factual
/// line" (e.g. "44 of 47 songs included — 3 aren't available for seamless
/// mixing"). Moved here from `MixBuilder` on 2026-08-14, alongside
/// `CrossfadeTiming`, for the same reason: pure `[Track]`-in logic with no
/// `MediaPlayer`/UI dependency has no reason to live somewhere it can't be
/// unit-tested — see `DRMExclusionSummaryTests.swift`.
///
/// A track is "unavailable" for exactly one of two reasons, kept as separate
/// counts (split 2026-08-14, after a real-device report of an implausibly
/// high exclusion count that turned out to be a separate bug — a database-
/// connection-storm write failure mid-analysis, not genuine DRM exclusion —
/// see CLAUDE.md Version History 0.25.0): `hasRawAudioAccess == false`
/// (Apple Music subscription-streamed, FairPlay-protected) or `!isAnalyzed`
/// (a decode/analysis failure). Reporting which bucket is responsible, rather
/// than one vague combined phrase, makes a real future recurrence of either
/// immediately diagnosable from the message alone.
public struct DRMExclusionSummary: Equatable {
    public let totalCount: Int
    public let includedCount: Int
    public let drmCount: Int
    public let analysisFailedCount: Int

    public var excludedCount: Int { totalCount - includedCount }
    public var hasExclusions: Bool { excludedCount > 0 }
    /// True when every track in the pool was excluded — the confirmed
    /// "none of these songs can be used" edge case, which needs an explicit
    /// message rather than silently producing an empty/broken playlist.
    public var isAllExcluded: Bool { totalCount > 0 && includedCount == 0 }

    /// The confirmed DRM-Exclusion UX's transparency line, or `nil` when
    /// nothing was excluded — `nil` lets a caller treat "show this message"
    /// and "don't" with a single optional check, same as
    /// `MixBuilder.lastBuildExclusionMessage`'s own doc comment already
    /// described before this type existed.
    public var message: String? {
        guard hasExclusions else { return nil }
        var reasons: [String] = []
        if drmCount > 0 {
            reasons.append("\(drmCount) streamed through your Apple Music subscription")
        }
        if analysisFailedCount > 0 {
            reasons.append("\(analysisFailedCount) couldn't be analyzed")
        }
        return "\(includedCount) of \(totalCount) songs included — \(excludedCount) aren't available for seamless mixing (\(reasons.joined(separator: ", ")))."
    }

    public static func summarize(pool: [Track]) -> DRMExclusionSummary {
        let unavailable = pool.filter { !($0.isAnalyzed && $0.hasRawAudioAccess) }
        let drmCount = unavailable.filter { !$0.hasRawAudioAccess }.count
        let analysisFailedCount = unavailable.count - drmCount
        return DRMExclusionSummary(
            totalCount: pool.count,
            includedCount: pool.count - unavailable.count,
            drmCount: drmCount,
            analysisFailedCount: analysisFailedCount
        )
    }
}
