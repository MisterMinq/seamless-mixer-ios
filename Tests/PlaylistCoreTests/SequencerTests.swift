import XCTest
@testable import PlaylistCore

/// Mirrors `test_playlist_mixer.py`'s `TestSequencing`/`TestKeepAll` classes —
/// same scenarios, ported to confirm `Sequencer` behaves the same way as the
/// validated Python original (per Rule 4/CLAUDE.md: this logic is a direct
/// port, so these tests exist to catch a porting slip, not to re-litigate
/// the design).
final class SequencerTests: XCTestCase {

    private static var nextID: Int64 = 1

    /// - Parameters mirror Python's `make_track(title, bpm, camelot, energy,
    ///   brightness, duration)` test helper. `energy`/`brightness` are given
    ///   as already-"raw" values here — since the whole pool passed to a
    ///   single test usually shares a narrow, deliberately-spread range,
    ///   `Sequencer.normalizeEnergyAndBrightness`'s min/max rescaling inside
    ///   `sequence(tracks:...)` still applies to these on top, exactly as it
    ///   would to real analysis output.
    private func makeTrack(
        _ title: String, bpm: Double, key: String, energy: Double, brightness: Double, duration: Double
    ) -> Track {
        defer { Self.nextID += 1 }
        return Track(
            persistentID: Self.nextID,
            title: title, artist: "", album: "", genre: "",
            bpm: bpm, musicalKey: key, energy: energy, brightness: brightness,
            durationSec: duration
        )
    }

    // MARK: - Sequencing (target-duration mode)

    func testEmptyInputReturnsEmpty() {
        let result = Sequencer.sequence(tracks: [], targetSeconds: 600, mode: .energyUp)
        XCTAssertTrue(result.isEmpty)
    }

    func testSingleTrackPool() {
        let tracks = [makeTrack("A", bpm: 120, key: "8A", energy: 0.5, brightness: 0.5, duration: 200)]
        let result = Sequencer.sequence(tracks: tracks, targetSeconds: 600, mode: .energyUp)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "A")
    }

    func testNoRepeatedTracks() {
        let tracks = (0..<15).map { i in
            makeTrack("T\(i)", bpm: 100 + Double(i), key: "8A", energy: Double(i) / 10, brightness: 0.5, duration: 180)
        }
        let result = Sequencer.sequence(tracks: tracks, targetSeconds: 1800, mode: .energyWave, seed: 1)
        let ids = result.map { $0.persistentID }
        XCTAssertEqual(ids.count, Set(ids).count, "sequencer repeated a track")
    }

    func testRespectsDurationTolerance() {
        // 20 tracks of 3 minutes each; target 30 minutes -> roughly 10 tracks,
        // landing within the documented tolerance (max(30s, 8% of target)).
        let tracks = (0..<20).map { i in makeTrack("T\(i)", bpm: 120, key: "8A", energy: 0.5, brightness: 0.5, duration: 180) }
        let target = 30.0 * 60
        let result = Sequencer.sequence(tracks: tracks, targetSeconds: target, mode: .energyUp, seed: 3)
        let total = result.reduce(0.0) { $0 + $1.durationSec }
        let tolerance = max(30.0, target * 0.08)
        XCTAssertLessThanOrEqual(total, target + tolerance + 180) // + one song's worth of slack for the "floor" case
        XCTAssertGreaterThan(total, 0)
    }

    func testDoesNotWildlyOvershootWhenAlreadyInWindow() {
        // Regression check for the duration-overshoot bug Phase 1 hit: once
        // within the tolerance window, a single huge remaining track should
        // not get pulled in.
        let tracks = [
            makeTrack("short1", bpm: 120, key: "8A", energy: 0.5, brightness: 0.5, duration: 290),
            makeTrack("short2", bpm: 120, key: "8A", energy: 0.5, brightness: 0.5, duration: 290),
            makeTrack("huge", bpm: 120, key: "8A", energy: 0.5, brightness: 0.5, duration: 3000), // 50 min
        ]
        let target = 600.0 // 10 minutes
        let result = Sequencer.sequence(tracks: tracks, targetSeconds: target, mode: .energyUp, seed: 0)
        let total = result.reduce(0.0) { $0 + $1.durationSec }
        XCTAssertLessThan(total, target + 600, "overshot badly: \(total)s for a \(target)s target")
    }

    func testEnergyUpTrendsUpward() {
        // Wide spread of energies so the trend is unambiguous despite harmonic/tempo scoring.
        let tracks = (0..<20).map { i in makeTrack("T\(i)", bpm: 120, key: "8A", energy: Double(i) / 19, brightness: 0.5, duration: 60) }
        let result = Sequencer.sequence(tracks: tracks, targetSeconds: 1200, mode: .energyUp, seed: 5)
        let energies = result.compactMap { $0.energy }
        let half = energies.count / 2
        let firstHalfAvg = energies[0..<half].reduce(0, +) / Double(half)
        let secondHalfAvg = energies[half...].reduce(0, +) / Double(energies.count - half)
        XCTAssertLessThan(firstHalfAvg, secondHalfAvg)
    }

    // MARK: - keepAll mode

    func testKeepAllIncludesEveryTrackRegardlessOfTarget() {
        // target is deliberately tiny -- keepAll must ignore it entirely.
        let tracks = (0..<10).map { i in makeTrack("T\(i)", bpm: 100 + Double(i), key: "8A", energy: Double(i) / 9, brightness: 0.5, duration: 240) }
        let result = Sequencer.sequence(tracks: tracks, targetSeconds: 60, mode: .energyUp, seed: 2, keepAll: true)
        XCTAssertEqual(result.count, tracks.count)
        XCTAssertEqual(Set(result.map { $0.persistentID }), Set(tracks.map { $0.persistentID }))
    }

    func testKeepAllNoRepeats() {
        let tracks = (0..<12).map { i in makeTrack("T\(i)", bpm: 120, key: "8A", energy: 0.5, brightness: 0.5, duration: 180) }
        let result = Sequencer.sequence(tracks: tracks, targetSeconds: 1, mode: .energyWave, seed: 9, keepAll: true)
        let ids = result.map { $0.persistentID }
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testKeepAllEmptyInput() {
        let result = Sequencer.sequence(tracks: [], targetSeconds: 600, mode: .energyUp, keepAll: true)
        XCTAssertTrue(result.isEmpty)
    }

    func testKeepAllStillOrdersByTransitionScore() {
        // Even with keepAll, ordering should still prefer harmonic/tempo
        // continuity over an arbitrary order -- sanity check it's not just
        // returning tracks in shuffle order untouched.
        let start = makeTrack("start", bpm: 120, key: "8A", energy: 0.5, brightness: 0.5, duration: 180)
        let close = makeTrack("close", bpm: 121, key: "8A", energy: 0.5, brightness: 0.5, duration: 180)
        let far = makeTrack("far", bpm: 200, key: "3B", energy: 0.5, brightness: 0.5, duration: 180)
        let tracks = [start, far, close]
        let result = Sequencer.sequence(tracks: tracks, targetSeconds: 1, mode: .stay, seed: 0, keepAll: true)
        XCTAssertEqual(result.count, 3)
        let titles = result.map { $0.title }
        let closeIndex = titles.firstIndex(of: "close")!
        let farIndex = titles.firstIndex(of: "far")!
        XCTAssertLessThan(closeIndex, farIndex, "harmonically/tempo-closer track should sequence before the far one")
    }

    // MARK: - Normalization

    func testNormalizeEnergyAndBrightnessRescalesToUnitRange() throws {
        let tracks = [
            makeTrack("low", bpm: 120, key: "8A", energy: 10, brightness: 1000, duration: 180),
            makeTrack("mid", bpm: 120, key: "8A", energy: 20, brightness: 2000, duration: 180),
            makeTrack("high", bpm: 120, key: "8A", energy: 30, brightness: 3000, duration: 180),
        ]
        let normalized = Sequencer.normalizeEnergyAndBrightness(tracks)
        XCTAssertEqual(try XCTUnwrap(normalized[0].energy), 0.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(normalized[1].energy), 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(normalized[2].energy), 1.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(normalized[0].brightness), 0.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(normalized[2].brightness), 1.0, accuracy: 0.0001)
    }

    func testNormalizeEnergyAndBrightnessHandlesFlatPool() throws {
        // All identical -> Python's tie-break is 0.5 for every track (e_hi == e_lo).
        let tracks = (0..<4).map { i in makeTrack("T\(i)", bpm: 120, key: "8A", energy: 5, brightness: 500, duration: 180) }
        let normalized = Sequencer.normalizeEnergyAndBrightness(tracks)
        for t in normalized {
            XCTAssertEqual(try XCTUnwrap(t.energy), 0.5, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(t.brightness), 0.5, accuracy: 0.0001)
        }
    }

    // MARK: - DRM / unanalyzed exclusion

    func testExcludesUnanalyzedAndDRMTracksSilently() {
        let good = makeTrack("good", bpm: 120, key: "8A", energy: 0.5, brightness: 0.5, duration: 180)
        var unanalyzed = makeTrack("unanalyzed", bpm: 120, key: "8A", energy: 0.5, brightness: 0.5, duration: 180)
        unanalyzed.bpm = nil // not yet analyzed
        let drmTrack = Track(
            persistentID: 9999, title: "drm", artist: "", album: "", genre: "",
            bpm: 120, musicalKey: "8A", energy: 0.5, brightness: 0.5, durationSec: 180,
            hasRawAudioAccess: false
        )
        let result = Sequencer.sequence(tracks: [good, unanalyzed, drmTrack], targetSeconds: 600, mode: .energyUp, keepAll: true)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "good")
    }
}
