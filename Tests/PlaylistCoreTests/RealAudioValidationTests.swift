import XCTest
@testable import PlaylistCore

/// Cross-checks `TrackAnalyzer`'s real-file decode + DSP output against
/// Phase 1's already-validated Python pipeline (`playlist_mixer.py`), on
/// the same real tracks — the check flagged as still outstanding in
/// CLAUDE.md's "Audio Analysis Pipeline — iOS DSP Design" section.
/// `AudioFeatureExtractorTests` only proves the DSP math is internally
/// self-consistent on synthetic signals; this is the first check against
/// real music, and the first real exercise of `TrackAnalyzer`'s
/// `AVAudioConverter` decode path (also previously unverified).
///
/// The eight fixture tracks in `Fixtures/` are a small, deliberate
/// exception to keeping this repo free of audio-sample clutter — see the
/// comment on the test target's `resources:` in `Package.swift`. They're
/// real tracks from `music_samplers/`, chosen to span a real range of
/// tempo/key/genre (funk/soul, bebop jazz, a slow jazz standard, reggae, a
/// pop ballad, an up-tempo etude) rather than being three similar-sounding
/// songs, and renamed to drop spaces/punctuation that can trip up
/// Xcode/SPM resource bundling.
///
/// Reference values below came from running `playlist_mixer.py
/// --analyze-only` fresh against these exact files (2026-08-08) and
/// reading the raw per-track cache output — i.e. the *pre*-normalization
/// values `_compute_features_from_audio` actually returns. This matters:
/// the energy/brightness numbers in `debug_sample_playlist/*.json` are
/// NOT usable as reference values here, because those went through
/// `normalize_energy_and_brightness`, a separate library-wide min-max
/// step applied later, across a whole candidate pool — not something
/// either `AudioFeatureExtractor` or `TrackAnalyzer` do today. (Worth
/// noting for whoever ports the sequencing engine next: that
/// normalization step doesn't have a Swift home yet.)
final class RealAudioValidationTests: XCTestCase {

    private struct Reference {
        let resourceName: String
        let bpm: Double
        let camelotCode: String
        /// Raw RMS, unbounded — matches Python's raw `energy` before
        /// library-wide normalization.
        let energy: Double
        /// Raw mean spectral centroid in Hz — matches Python's raw
        /// `brightness_raw` before normalization.
        let brightness: Double
        let durationSec: Double
    }

    private let references: [Reference] = [
        Reference(
            resourceName: "All_Night_Long",
            bpm: 95.7, camelotCode: "3A",
            energy: 0.1328313797712326, brightness: 1718.6228516983554,
            durationSec: 320.155283446712
        ),
        Reference(
            resourceName: "Aint_Nobody",
            bpm: 103.4, camelotCode: "3A",
            energy: 0.1653030663728714, brightness: 2267.040046962599,
            durationSec: 280.8671201814059
        ),
        Reference(
            resourceName: "Lets_Go_All_The_Way",
            bpm: 99.4, camelotCode: "3A",
            energy: 0.10262800008058548, brightness: 2407.64668793609,
            durationSec: 291.06068027210887
        ),
        // Bebop, fast — a genuinely different rhythmic character than the
        // funk/soul tracks above, good for catching a tempo-estimator bug
        // that only shows up outside a narrow ~95-105 BPM band.
        Reference(
            resourceName: "A_Night_In_Tunisia",
            bpm: 172.3, camelotCode: "9B",
            energy: 0.1566379815340042, brightness: 2170.3181219479557,
            durationSec: 204.21804988662132
        ),
        // Slow 12-bar blues, ~11.6 minutes — longest fixture by far, both a
        // tempo-range check (much slower than everything else here) and a
        // decode-path check on an unusually long real file.
        Reference(
            resourceName: "All_Blues",
            bpm: 136.0, camelotCode: "7A",
            energy: 0.07906904816627502, brightness: 2553.356049337377,
            durationSec: 695.7844897959184
        ),
        // Reggae — different rhythmic emphasis than jazz/funk, useful key-
        // detection diversity.
        Reference(
            resourceName: "Africa_Unite",
            bpm: 129.2, camelotCode: "9A",
            energy: 0.18948139250278473, brightness: 1845.2512154394817,
            durationSec: 175.6342857142857
        ),
        // Slow pop ballad.
        Reference(
            resourceName: "Against_All_Odds",
            bpm: 117.5, camelotCode: "4B",
            energy: 0.10456230491399765, brightness: 1877.5371260697157,
            durationSec: 204.0801814058957
        ),
        // Up-tempo instrumental/etude — the fastest fixture, tests the
        // opposite tempo extreme from All_Blues.
        Reference(
            resourceName: "A_Twisted_Little_Etude",
            bpm: 184.6, camelotCode: "5A",
            energy: 0.19085794687271118, brightness: 1721.24024885788,
            durationSec: 149.0938775510204
        ),
    ]

    func testRealTracksDecodeWithoutThrowing() throws {
        // The most basic real-world question this whole file exists to
        // answer: does AVAudioConverter's downmix/resample path actually
        // work on real, full-length, real-world-encoded m4a files, not
        // just the short synthetic buffers AudioFeatureExtractorTests
        // constructs in memory? If this throws, nothing below matters.
        for ref in references {
            let url = try fixtureURL(ref.resourceName)
            XCTAssertNoThrow(try TrackAnalyzer.analyze(fileAt: url), "\(ref.resourceName): decode/analyze threw")
            XCTAssertNoThrow(try TrackAnalyzer.duration(ofFileAt: url), "\(ref.resourceName): duration threw")
        }
    }

    func testDurationMatchesPythonReference() throws {
        // Duration is a metadata read, not a DSP heuristic — this should
        // match Python's ffprobe-based reading almost exactly, unlike
        // bpm/key/energy/brightness below.
        for ref in references {
            let url = try fixtureURL(ref.resourceName)
            let duration = try TrackAnalyzer.duration(ofFileAt: url)
            XCTAssertEqual(duration, ref.durationSec, accuracy: 1.0, "\(ref.resourceName): duration mismatch")
        }
    }

    func testAnalysisOutputIsSane() throws {
        // Sanity bounds that should hold regardless of exactly how much
        // the Swift DSP simplifications (STFT chroma vs. CQT, autocorrelation
        // vs. full beat-tracking — see CLAUDE.md) diverge from Python's.
        for ref in references {
            let url = try fixtureURL(ref.resourceName)
            let features = try TrackAnalyzer.analyze(fileAt: url)

            XCTAssertGreaterThan(features.bpm, 0, "\(ref.resourceName): bpm should be positive")
            XCTAssertTrue((40...220).contains(features.bpm), "\(ref.resourceName): bpm outside plausible range")
            XCTAssertGreaterThan(features.energy, 0, "\(ref.resourceName): energy should be positive for real audio")
            XCTAssertGreaterThan(features.brightness, 0, "\(ref.resourceName): brightness (Hz) should be positive")
            XCTAssertFalse(features.camelotCode.isEmpty, "\(ref.resourceName): camelot code should not be empty")
        }
    }

    /// Not a pass/fail gate — prints the Swift vs. Python numbers side by
    /// side so they can be reviewed by eye. Real accuracy comparison isn't
    /// a fixed threshold to assert against yet; see the class doc comment.
    ///
    /// Also passes `tempoDebugLog` so `estimateTempo`'s octave-error
    /// correction prints its candidate lags/scores/decision for every
    /// track — added 2026-08-08 after the first version of that
    /// correction fixed 3 tracks but regressed a 4th, and hand-deriving
    /// lags from printed bpm values (to diagnose why) turned out to be
    /// possible but slow and error-prone. This gives that visibility
    /// directly instead, for whenever the correction needs tuning again.
    func testPrintComparisonAgainstPythonReference() throws {
        for ref in references {
            let url = try fixtureURL(ref.resourceName)
            let features = try TrackAnalyzer.analyze(fileAt: url) { logLine in
                print("[\(ref.resourceName) tempo] \(logLine)")
            }
            let duration = try TrackAnalyzer.duration(ofFileAt: url)

            print("""

                --- \(ref.resourceName) ---
                Python:  bpm=\(ref.bpm)  key=\(ref.camelotCode)  energy=\(ref.energy)  brightness=\(ref.brightness)  duration=\(ref.durationSec)
                Swift:   bpm=\(features.bpm)  key=\(features.camelotCode)  energy=\(features.energy)  brightness=\(features.brightness)  duration=\(duration)
                """)
        }
    }

    private func fixtureURL(_ resourceName: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "m4a", subdirectory: "Fixtures") else {
            XCTFail("Fixture not found: \(resourceName).m4a — check Package.swift's resources: and Tests/PlaylistCoreTests/Fixtures/")
            throw TrackAnalyzer.AnalysisError.couldNotOpenFile
        }
        return url
    }
}
