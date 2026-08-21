import XCTest
@testable import PlaylistCore

/// Regression coverage for `TempoNudge`, the last piece of the confirmed
/// mixing engine design that had never been driven (`AVAudioUnitTimePitch`
/// wired since 0.17.0, `.rate` never set). Ported directly from Python's
/// `time_stretch_towards` ratio math -- see that file's own doc comment.
final class TempoNudgeTests: XCTestCase {

    func testRateNudgesTowardOutgoingTempo() {
        // Incoming track at 120bpm, outgoing (still-playing) track at
        // 126bpm -- desired ratio is 126/120 = 1.05, well inside ±6%, so
        // the incoming track should speed up by exactly that ratio.
        let rate = TempoNudge.rate(incomingBPM: 120, outgoingBPM: 126)
        XCTAssertEqual(rate, 1.05, accuracy: 0.0001)
    }

    func testRateNudgesDownwardWhenOutgoingIsSlower() {
        // Incoming at 120bpm, outgoing at 114bpm -- ratio is 114/120 = 0.95,
        // the incoming track should slow down.
        let rate = TempoNudge.rate(incomingBPM: 120, outgoingBPM: 114)
        XCTAssertEqual(rate, 0.95, accuracy: 0.0001)
    }

    func testRateClampsToUpperBoundForALargeTempoGap() {
        // Incoming at 100bpm, outgoing at 200bpm -- a full beatmatch would be
        // rate=2.0, but the nudge is deliberately limited to ≤6%, not a full
        // beatmatch.
        let rate = TempoNudge.rate(incomingBPM: 100, outgoingBPM: 200)
        XCTAssertEqual(rate, 1.06, accuracy: 0.0001)
    }

    func testRateClampsToLowerBoundForALargeTempoGap() {
        let rate = TempoNudge.rate(incomingBPM: 200, outgoingBPM: 100)
        XCTAssertEqual(rate, 0.94, accuracy: 0.0001)
    }

    func testRateIsExactlyOneWhenTemposAlreadyMatch() {
        XCTAssertEqual(TempoNudge.rate(incomingBPM: 120, outgoingBPM: 120), 1.0, accuracy: 0.0001)
    }

    func testRateFallsBackToNoNudgeWhenEitherBPMIsMissing() {
        XCTAssertEqual(TempoNudge.rate(incomingBPM: nil, outgoingBPM: 120), 1.0)
        XCTAssertEqual(TempoNudge.rate(incomingBPM: 120, outgoingBPM: nil), 1.0)
        XCTAssertEqual(TempoNudge.rate(incomingBPM: nil, outgoingBPM: nil), 1.0)
    }

    func testRateGuardsAgainstNonPositiveBPM() {
        // Matches Python's `if from_bpm <= 0 or to_bpm <= 0: return y` guard
        // -- must not crash or divide by zero.
        XCTAssertEqual(TempoNudge.rate(incomingBPM: 0, outgoingBPM: 120), 1.0)
        XCTAssertEqual(TempoNudge.rate(incomingBPM: 120, outgoingBPM: -5), 1.0)
    }

    func testRateRespectsACustomMaxPct() {
        let rate = TempoNudge.rate(incomingBPM: 100, outgoingBPM: 200, maxPct: 0.10)
        XCTAssertEqual(rate, 1.10, accuracy: 0.0001)
    }
}
