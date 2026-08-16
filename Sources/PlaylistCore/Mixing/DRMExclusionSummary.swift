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
/// see CLAUDE.md Version History 0.25.0): `hasRawAudioAccess == false` or
/// `!isAnalyzed` (a decode/analysis failure). Keeping the two counts
/// separate internally still lets a real future recurrence of either be
/// diagnosed from the numbers alone.
///
/// **`drmCount`'s user-facing wording no longer names a subscription
/// (reworded 2026-08-17)** — see `message`'s own doc comment for why: Apple
/// Music-subscription DRM was the original, documented reason a track's raw
/// audio can be inaccessible (per ADR-7), but real-device testing proved
/// there is no reliable signal this app can check to actually confirm that's
/// the cause for a *specific* track — Andy's own, fully-owned library kept
/// triggering this exact bucket. The internal name (`drmCount`) is kept for
/// continuity with that original reasoning, not because every track counted
/// here is provably DRM-restricted.
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
    ///
    /// **`drmCount`'s wording changed 2026-08-17 — no longer names a
    /// subscription.** The original confirmed DRM-Exclusion UX design said
    /// this bucket's reason was "streamed through your Apple Music
    /// subscription," on the assumption a nil `assetURL` reliably meant
    /// real FairPlay DRM. Real-device testing disproved that: Andy owns
    /// every track on his phone (no subscription at all) and still hit
    /// this exact message, twice, even after `MixBuilder` started retrying
    /// and cross-checking Apple's own `isCloudItem` flag — that flag turned
    /// out to be true for tracks he genuinely owns and has fully
    /// downloaded too. There is no API available to a third-party app that
    /// reliably tells "real subscription stream" apart from "a local file
    /// iOS just won't hand over a URL for right now" — so this message no
    /// longer claims to know which one it is. It still tells the user
    /// something real and useful (these songs didn't make it in, here's
    /// roughly why), just without a specific, unverifiable accusation.
    public var message: String? {
        guard hasExclusions else { return nil }
        var reasons: [String] = []
        if drmCount > 0 {
            reasons.append("\(drmCount) not accessible on this device")
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
