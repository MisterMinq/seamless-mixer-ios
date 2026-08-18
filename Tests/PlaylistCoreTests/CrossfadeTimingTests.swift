import XCTest
@testable import PlaylistCore

/// Regression coverage for `CrossfadeTiming`, extracted from `MixBuilder`
/// 2026-08-14 specifically so this math could be unit-tested at all — see
/// that type's own doc comment for why. The bug this guards against already
/// shipped once (a flat `duration - 5s` placeholder, live from 0.15.5 until
/// real-device listening caught it at 0.19.0) and cost a real, confusing
/// round of "the crossfade doesn't work" reports before it was found — these
/// tests exist so a future change to this math fails loudly here first,
/// not on Andy's phone.
final class CrossfadeTimingTests: XCTestCase {

    private static var nextID: Int64 = 1

    private func makeTrack(bpm: Double?, playableDurationSec: Double?, durationSec: Double = 240) -> Track {
        defer { Self.nextID += 1 }
        return Track(
            persistentID: Self.nextID,
            title: "t", artist: "", album: "", genre: "",
            bpm: bpm, musicalKey: "8A", energy: 0.5, brightness: 0.5,
            durationSec: durationSec,
            playableStartSec: 0, playableDurationSec: playableDurationSec
        )
    }

    // MARK: - durationSec(forBPM:)

    func testDurationSecAtOrdinaryTempo() {
        // 120bpm -> beat = 0.5s -> 6 beats = 3.0s, comfortably inside [2, 12].
        XCTAssertEqual(CrossfadeTiming.durationSec(forBPM: 120), 3.0, accuracy: 0.001)
    }

    func testDurationSecClampsToUpperBoundForSlowTempo() {
        // 20bpm -> beat = 3.0s -> 6 beats = 18s, clipped to the 12s ceiling.
        XCTAssertEqual(CrossfadeTiming.durationSec(forBPM: 20), 12.0, accuracy: 0.001)
    }

    func testDurationSecClampsToLowerBoundForFastTempo() {
        // 300bpm -> beat = 0.2s -> 6 beats = 1.2s, clipped to the 2s floor.
        XCTAssertEqual(CrossfadeTiming.durationSec(forBPM: 300), 2.0, accuracy: 0.001)
    }

    func testDurationSecFallsBackTo120BPMWhenNil() {
        // Shouldn't happen in practice (Sequencer only selects isAnalyzed
        // tracks), but must not crash or divide by zero.
        XCTAssertEqual(CrossfadeTiming.durationSec(forBPM: nil), CrossfadeTiming.durationSec(forBPM: 120), accuracy: 0.001)
    }

    func testDurationSecGuardsAgainstNonPositiveBPM() {
        // Matches Python's max(bpm, 1e-6) divide-by-zero guard -- a
        // non-positive bpm must not crash or produce a negative/NaN result.
        let result = CrossfadeTiming.durationSec(forBPM: 0)
        XCTAssertTrue(result.isFinite)
        XCTAssertEqual(result, 12.0, accuracy: 0.001) // an ~0bpm beat length is huge, clipped to the ceiling
    }

    // MARK: - timing(for:)

    func testTimingStartsCrossfadeBeforePlayableEnd() {
        let track = makeTrack(bpm: 120, playableDurationSec: 200)
        let timing = CrossfadeTiming.timing(for: track)
        XCTAssertEqual(timing.durationSec, 3.0, accuracy: 0.001)
        XCTAssertEqual(timing.startOffsetSec, 197.0, accuracy: 0.001)
    }

    func testTimingFallsBackToRawDurationWhenPlayableDurationIsNil() {
        let track = makeTrack(bpm: 120, playableDurationSec: nil, durationSec: 200)
        let timing = CrossfadeTiming.timing(for: track)
        XCTAssertEqual(timing.startOffsetSec, 197.0, accuracy: 0.001)
    }

    func testTimingFloorsStartOffsetAtZeroForAVeryShortTrack() {
        // A track shorter than its own crossfade window must not produce a
        // negative start offset.
        let track = makeTrack(bpm: 120, playableDurationSec: 1.0)
        let timing = CrossfadeTiming.timing(for: track)
        XCTAssertEqual(timing.startOffsetSec, 0.0, accuracy: 0.001)
        XCTAssertEqual(timing.durationSec, 3.0, accuracy: 0.001)
    }

    // MARK: - extraSec (added 2026-08-19, per Andy's request for a
    // user-adjustable crossfade length)

    func testDurationSecAddsExtraSecOnTopOfTempoDerivedBase() {
        // 120bpm's own base is 3.0s (see testDurationSecAtOrdinaryTempo) --
        // +2s on top should land at exactly 5.0s, not just clip back to the
        // tempo-derived value.
        XCTAssertEqual(CrossfadeTiming.durationSec(forBPM: 120, extraSec: 2), 5.0, accuracy: 0.001)
    }

    func testDurationSecExtraSecAppliesAfterTheClampNotBeforeIt() {
        // A slow track's base is already clipped to the 12s ceiling --
        // extraSec must still add on top of that, not get absorbed by the
        // clip (which would make the setting silently do nothing for any
        // already-slow song).
        XCTAssertEqual(CrossfadeTiming.durationSec(forBPM: 20, extraSec: 3), 15.0, accuracy: 0.001)
    }

    func testDurationSecExtraSecDefaultsToZero() {
        // Every existing call site (and every playlist built before this
        // setting existed) must see exactly today's behavior when extraSec
        // isn't passed at all.
        XCTAssertEqual(CrossfadeTiming.durationSec(forBPM: 120), CrossfadeTiming.durationSec(forBPM: 120, extraSec: 0), accuracy: 0.001)
    }

    func testTimingThreadsExtraSecIntoBothDurationAndStartOffset() {
        let track = makeTrack(bpm: 120, playableDurationSec: 200)
        let timing = CrossfadeTiming.timing(for: track, extraSec: 2)
        XCTAssertEqual(timing.durationSec, 5.0, accuracy: 0.001) // 3.0 base + 2 extra
        XCTAssertEqual(timing.startOffsetSec, 195.0, accuracy: 0.001) // 200 - 5.0
    }
}
