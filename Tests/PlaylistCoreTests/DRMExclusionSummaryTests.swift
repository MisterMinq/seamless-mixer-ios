import XCTest
@testable import PlaylistCore

/// Regression coverage for `DRMExclusionSummary`, extracted from
/// `MixBuilder` 2026-08-14 so this logic could be unit-tested at all — see
/// that type's own doc comment for why. Directly guards against the class of
/// bug found the same round: an implausible exclusion count (e.g. "14 of 18")
/// that turned out to be caused by something other than genuine DRM
/// exclusion (a database-connection storm producing spurious analysis
/// failures) — these tests pin down what the counts and message *should* say
/// for a known pool, independent of whatever produced that pool.
final class DRMExclusionSummaryTests: XCTestCase {

    private static var nextID: Int64 = 1

    /// - Parameters: `analyzed` controls whether every analysis field is
    ///   populated (mirrors `Track.isAnalyzed`'s own six-field check) —
    ///   `false` synthesizes a track that failed analysis, independent of
    ///   `hasRawAudioAccess`.
    private func makeTrack(analyzed: Bool, hasRawAudioAccess: Bool) -> Track {
        defer { Self.nextID += 1 }
        return Track(
            persistentID: Self.nextID,
            title: "t", artist: "", album: "", genre: "",
            bpm: analyzed ? 120 : nil,
            musicalKey: analyzed ? "8A" : nil,
            energy: analyzed ? 0.5 : nil,
            brightness: analyzed ? 0.5 : nil,
            durationSec: 200,
            hasRawAudioAccess: hasRawAudioAccess,
            playableStartSec: analyzed ? 0 : nil,
            playableDurationSec: analyzed ? 200 : nil
        )
    }

    func testEmptyPoolHasNoExclusions() {
        let summary = DRMExclusionSummary.summarize(pool: [])
        XCTAssertFalse(summary.hasExclusions)
        XCTAssertFalse(summary.isAllExcluded)
        XCTAssertNil(summary.message)
    }

    func testFullyIncludedPoolProducesNoMessage() {
        let pool = (0..<5).map { _ in makeTrack(analyzed: true, hasRawAudioAccess: true) }
        let summary = DRMExclusionSummary.summarize(pool: pool)
        XCTAssertEqual(summary.includedCount, 5)
        XCTAssertEqual(summary.excludedCount, 0)
        XCTAssertFalse(summary.hasExclusions)
        XCTAssertNil(summary.message)
    }

    /// **Wording changed 2026-08-17** — see `DRMExclusionSummary.message`'s
    /// own doc comment: this bucket no longer names a subscription, since
    /// real-device testing proved this app has no reliable way to confirm
    /// that's actually the cause for a given track.
    func testDRMOnlyExclusionMentionsNotAccessibleNotAnalysisFailure() throws {
        var pool = (0..<4).map { _ in makeTrack(analyzed: true, hasRawAudioAccess: true) }
        pool.append(makeTrack(analyzed: false, hasRawAudioAccess: false)) // no raw audio access: never gets analyzed either
        let summary = DRMExclusionSummary.summarize(pool: pool)
        XCTAssertEqual(summary.includedCount, 4)
        XCTAssertEqual(summary.drmCount, 1)
        XCTAssertEqual(summary.analysisFailedCount, 0)
        let message = try XCTUnwrap(summary.message)
        XCTAssertTrue(message.contains("not accessible on this device"))
        XCTAssertFalse(message.contains("Apple Music subscription"))
        XCTAssertFalse(message.contains("couldn't be analyzed"))
    }

    func testAnalysisFailureOnlyExclusionMentionsAnalysisNotAccessDenial() throws {
        var pool = (0..<4).map { _ in makeTrack(analyzed: true, hasRawAudioAccess: true) }
        pool.append(makeTrack(analyzed: false, hasRawAudioAccess: true)) // has audio access, but decode/analysis failed
        let summary = DRMExclusionSummary.summarize(pool: pool)
        XCTAssertEqual(summary.includedCount, 4)
        XCTAssertEqual(summary.drmCount, 0)
        XCTAssertEqual(summary.analysisFailedCount, 1)
        let message = try XCTUnwrap(summary.message)
        XCTAssertTrue(message.contains("couldn't be analyzed"))
        XCTAssertFalse(message.contains("not accessible on this device"))
    }

    func testMixedExclusionReasonsAreBothReportedSeparately() throws {
        var pool = [makeTrack(analyzed: true, hasRawAudioAccess: true)]
        pool.append(makeTrack(analyzed: false, hasRawAudioAccess: false)) // no raw audio access
        pool.append(makeTrack(analyzed: false, hasRawAudioAccess: true))  // analysis failure
        let summary = DRMExclusionSummary.summarize(pool: pool)
        XCTAssertEqual(summary.totalCount, 3)
        XCTAssertEqual(summary.includedCount, 1)
        XCTAssertEqual(summary.drmCount, 1)
        XCTAssertEqual(summary.analysisFailedCount, 1)
        let message = try XCTUnwrap(summary.message)
        XCTAssertTrue(message.contains("not accessible on this device"))
        XCTAssertTrue(message.contains("couldn't be analyzed"))
        XCTAssertTrue(message.hasPrefix("1 of 3 songs included"))
    }

    func testAllExcludedIsFlaggedDistinctlyFromPartialExclusion() {
        let pool = (0..<3).map { _ in makeTrack(analyzed: false, hasRawAudioAccess: false) }
        let summary = DRMExclusionSummary.summarize(pool: pool)
        XCTAssertTrue(summary.isAllExcluded)
        XCTAssertEqual(summary.includedCount, 0)
        // `isAllExcluded` is what a caller should check first (MixBuilder
        // throws `.allExcluded` and never surfaces `message` in that case) --
        // still verify `message` itself stays well-formed rather than nil or
        // a "0 of 3" that reads like a bug.
        XCTAssertEqual(summary.message, "0 of 3 songs included — 3 aren't available for seamless mixing (3 not accessible on this device).")
    }
}
