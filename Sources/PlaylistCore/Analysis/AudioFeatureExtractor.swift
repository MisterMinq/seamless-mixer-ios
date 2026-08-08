import Foundation
import Accelerate

/// bpm / musical key (Camelot code) / energy / brightness, extracted from a
/// mono sample buffer. Mirrors `playlist_mixer.py`'s `_compute_features_from_audio`
/// (which leans on `librosa`) with hand-written Accelerate/vDSP equivalents,
/// since librosa has no iOS port. See CLAUDE.md's "Audio Analysis Pipeline —
/// iOS DSP Design" section for the full rationale and known simplifications.
///
/// **This is the highest-risk untested file in the project so far.** It has
/// not been compiled — no Xcode/Swift toolchain is available in the
/// environment this was written in — and the FFT packing/scaling code in
/// particular (`FFTProcessor` below) is exactly the kind of thing that's easy
/// to get subtly wrong without being able to run it against a known signal.
/// Per Rule 3's spirit extended to iOS: validate this against real tracks
/// from `music_samplers/` before trusting its output, ideally by comparing
/// against the bpm/key/energy/brightness values Phase 1's Python pipeline
/// already computed for the same files.
public struct AnalysisFeatures: Equatable {
    public var bpm: Double
    public var camelotCode: String
    public var energy: Double       // RMS, unbounded (matches Python — not clamped to 0...1 here either)
    public var brightness: Double   // mean spectral centroid in Hz (matches Python's raw value)
}

public enum AudioFeatureExtractor {

    /// STFT frame size. 4096 at 22.05kHz ≈ 186ms per frame — wide enough for
    /// reasonable low-frequency resolution for chroma/bass content, same
    /// spirit as librosa's default n_fft but not tuned/validated on-device yet.
    static let fftSize = 4096
    /// Hop for the chroma/brightness pass. 75% overlap, standard for this
    /// kind of analysis. **Not used for tempo** — see `tempoHopSize`.
    static let hopSize = 1024
    /// A separate, finer hop used only for the onset-envelope/tempo pass
    /// (added 2026-08-08 — see CLAUDE.md Version History for the full
    /// investigation). Real-audio validation against all 28 tracks in
    /// `music_samplers/` found the shared `hopSize`=1024 onset envelope was
    /// the actual bottleneck for tempo accuracy, not the lag-picking logic:
    /// even feeding that envelope into `librosa`'s own proven
    /// dynamic-programming beat tracker only got ~39% of tracks within 3%
    /// of ground truth. Halving the hop to 512 (doubling onset-envelope
    /// time resolution, matching librosa's own default) raised that to
    /// ~61%, with no further gain at 256 — confirming hop resolution, not
    /// algorithm sophistication, was the limiting factor. Kept as a
    /// separate constant/pass rather than lowering `hopSize` itself so this
    /// fix doesn't also perturb the already-validated brightness/key
    /// numbers or double their compute cost for no benefit. Trade-off worth
    /// knowing: this roughly triples per-track FFT work during analysis
    /// (the existing chroma/brightness pass plus a ~2x-denser dedicated
    /// tempo pass) — acceptable for a one-time/background per-track scan,
    /// not a live-playback cost.
    static let tempoHopSize = 512

    static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// - Parameters:
    ///   - samples: mono Float32 PCM, expected at `sampleRate` (22.05kHz for
    ///     analysis, matching Phase 1's `analysis_sr`, distinct from the
    ///     44.1kHz stereo decode used for the actual mix).
    ///   - tempoDebugLog: optional diagnostic sink for `estimateTempo`'s
    ///     octave-error correction decision (candidate lags/scores) — not
    ///     used by any production caller, only by
    ///     `RealAudioValidationTests` while tuning that correction against
    ///     real tracks. Defaults to `nil` (no-op, no behavior change).
    public static func extract(samples: [Float], sampleRate: Double, tempoDebugLog: ((String) -> Void)? = nil) -> AnalysisFeatures {
        let energy = rms(samples)

        guard samples.count >= fftSize else {
            // Too short to frame at all — return safe Python-side fallback values
            // (mirrors the `except: bpm = 120.0` / `code = "8A"` fallbacks).
            return AnalysisFeatures(bpm: 120.0, camelotCode: "8A", energy: Double(energy), brightness: 2000.0)
        }

        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        let fft = FFTProcessor(fftSize: fftSize)

        var centroids: [Float] = []
        var chroma = [Float](repeating: 0, count: 12)

        var offset = 0
        while offset + fftSize <= samples.count {
            let frame = (0..<fftSize).map { samples[offset + $0] * window[$0] }
            let magnitudes = fft.magnitudeSpectrum(of: frame)

            centroids.append(spectralCentroid(magnitudes: magnitudes, sampleRate: sampleRate, fftSize: fftSize))
            accumulateChroma(magnitudes: magnitudes, sampleRate: sampleRate, fftSize: fftSize, into: &chroma)

            offset += hopSize
        }

        let brightness = centroids.isEmpty ? 2000.0 : centroids.reduce(0, +) / Float(centroids.count)
        let camelotCode = detectKey(chroma: chroma)

        // Tempo runs its own, finer-hop pass (see `tempoHopSize`'s doc
        // comment) rather than reusing the chroma/brightness loop above.
        let tempoOnsetEnvelope = computeOnsetEnvelope(samples: samples, window: window, fft: fft)
        let bpm = estimateTempo(onsetEnvelope: tempoOnsetEnvelope, sampleRate: sampleRate, hopSize: tempoHopSize, debugLog: tempoDebugLog)

        return AnalysisFeatures(bpm: bpm, camelotCode: camelotCode, energy: Double(energy), brightness: Double(brightness))
    }

    /// Runs an independent STFT pass at `tempoHopSize` (finer than the
    /// `hopSize` used for chroma/brightness above) purely to build the
    /// onset-strength envelope tempo estimation needs. Kept separate from
    /// the main loop in `extract` rather than just lowering `hopSize`
    /// itself, so the already-validated brightness/key numbers aren't
    /// perturbed and don't pay the cost of the denser hop for no benefit.
    /// See `tempoHopSize`'s doc comment for why this exists.
    static func computeOnsetEnvelope(samples: [Float], window: [Float], fft: FFTProcessor) -> [Float] {
        var onsetEnvelope: [Float] = []
        var previousMagnitudes: [Float]? = nil

        var offset = 0
        while offset + fftSize <= samples.count {
            let frame = (0..<fftSize).map { samples[offset + $0] * window[$0] }
            let magnitudes = fft.magnitudeSpectrum(of: frame)

            if let previous = previousMagnitudes {
                onsetEnvelope.append(spectralFlux(current: magnitudes, previous: previous))
            }
            previousMagnitudes = magnitudes

            offset += tempoHopSize
        }
        return onsetEnvelope
    }

    // MARK: - Energy (RMS)

    /// Matches Python's `rms = sqrt(mean(y ** 2))` over the whole signal.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0.05 } // Python's except-fallback
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return sqrt(meanSquare)
    }

    // MARK: - Brightness (spectral centroid)

    /// Σ(f_k · |X_k|) / Σ|X_k| for one frame's magnitude spectrum.
    static func spectralCentroid(magnitudes: [Float], sampleRate: Double, fftSize: Int) -> Float {
        var weightedSum: Float = 0
        var magnitudeSum: Float = 0
        let binHz = Float(sampleRate) / Float(fftSize)
        for (bin, mag) in magnitudes.enumerated() {
            let freq = Float(bin) * binHz
            weightedSum += freq * mag
            magnitudeSum += mag
        }
        return magnitudeSum > 0 ? weightedSum / magnitudeSum : 0
    }

    // MARK: - Key (chroma + Krumhansl-Schmuckler)

    /// Bins a frame's magnitude spectrum into a 12-element chroma vector,
    /// accumulating into `chroma`. Simplified relative to Python's
    /// `librosa.feature.chroma_cqt` — this uses plain STFT bins mapped to
    /// their nearest pitch class rather than a full Constant-Q Transform, a
    /// deliberate first-pass simplification (CQT is a substantially bigger
    /// port). Expect this to be less accurate at low bass frequencies than
    /// the Python version; revisit if real-track key detection proves poor.
    static func accumulateChroma(magnitudes: [Float], sampleRate: Double, fftSize: Int, into chroma: inout [Float]) {
        let binHz = Float(sampleRate) / Float(fftSize)
        // Ignore content outside the musically-relevant range — very low bins
        // are mostly DC/rumble, very high bins are harmonics that muddy key
        // detection more than they help it.
        let minFreq: Float = 40, maxFreq: Float = 5000
        for (bin, mag) in magnitudes.enumerated() {
            let freq = Float(bin) * binHz
            guard freq >= minFreq, freq <= maxFreq, mag > 0 else { continue }
            let midi = 69 + 12 * log2(freq / 440)
            let pitchClass = ((Int(midi.rounded()) % 12) + 12) % 12
            chroma[pitchClass] += mag
        }
    }

    /// Correlates the accumulated chroma vector against all 24 rolled
    /// Krumhansl-Schmuckler profiles (12 major + 12 minor) and returns the
    /// best-matching Camelot code — direct port of the Python correlation
    /// loop, same profile constants.
    static func detectKey(chroma: [Float]) -> String {
        let total = chroma.reduce(0, +)
        guard total > 0 else { return "8A" }
        let chromaMean = chroma.map { $0 / total }

        var bestScore: Float = -.greatestFiniteMagnitude
        var bestPitchClass = 0
        var bestIsMinor = false

        for pc in 0..<12 {
            let rolledMajor = roll(majorProfile, by: pc)
            let rolledMinor = roll(minorProfile, by: pc)
            let scoreMajor = pearsonCorrelation(chromaMean, rolledMajor)
            let scoreMinor = pearsonCorrelation(chromaMean, rolledMinor)
            if scoreMajor > bestScore { bestScore = scoreMajor; bestPitchClass = pc; bestIsMinor = false }
            if scoreMinor > bestScore { bestScore = scoreMinor; bestPitchClass = pc; bestIsMinor = true }
        }

        return CamelotKey.code(pitchClassIndex: bestPitchClass, isMinor: bestIsMinor)
    }

    /// numpy.roll equivalent (circular shift, positive = right/forward).
    static func roll(_ array: [Float], by shift: Int) -> [Float] {
        guard !array.isEmpty else { return array }
        let n = array.count
        let s = ((shift % n) + n) % n
        return Array(array[(n - s)...] + array[..<(n - s)])
    }

    /// numpy.corrcoef(...)[0, 1] equivalent — Pearson correlation coefficient.
    static func pearsonCorrelation(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        let n = Float(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var covariance: Float = 0, varA: Float = 0, varB: Float = 0
        for i in 0..<a.count {
            let da = a[i] - meanA, db = b[i] - meanB
            covariance += da * db
            varA += da * da
            varB += db * db
        }
        let denom = sqrt(varA * varB)
        return denom > 0 ? covariance / denom : -1
    }

    // MARK: - Tempo (BPM)

    /// Half-wave-rectified spectral flux between two consecutive frames —
    /// standard, simple onset-strength measure (Dixon's "spectral flux"),
    /// substituting for librosa's mel-spectrogram-based onset envelope.
    static func spectralFlux(current: [Float], previous: [Float]) -> Float {
        var flux: Float = 0
        for i in 0..<current.count {
            let diff = current[i] - previous[i]
            if diff > 0 { flux += diff }
        }
        return flux
    }

    /// Estimates tempo via autocorrelation of the onset-strength envelope —
    /// find the lag (converted to BPM) with the strongest periodicity within
    /// a plausible tempo range. This is a simplified stand-in for librosa's
    /// dynamic-programming beat tracker: it estimates a tempo, not actual
    /// beat positions, which is all the schema needs (`tracks.bpm`).
    ///
    /// Includes an octave-error correction step (added 2026-08-08, after
    /// `RealAudioValidationTests` found 5 of 8 real tracks had tempo off by
    /// an exact factor of 2 from Python's reference — 4 detected at half
    /// the true tempo, 1 at double). Plain autocorrelation is prone to
    /// locking onto a harmonic of the true beat period rather than the
    /// period itself, and the 4-vs-1 split observed matches the
    /// well-documented tendency for backbeat-heavy music (funk/soul/pop —
    /// what those 4 failing tracks were) to produce a *stronger*
    /// autocorrelation peak at twice the true beat period than at the true
    /// period, since a strong accent on every other beat looks like its own
    /// periodicity.
    ///
    /// **Revised same day** after the first version of this correction,
    /// re-validated against the same 8 fixtures, fixed 3 tracks but
    /// regressed a 4th (`Africa_Unite`, previously an exact match, became
    /// wrong) and overcorrected a 5th. Both bad outcomes landed their
    /// half-lag candidate right at or next to `minLag` (lag 5 and 7, vs.
    /// `minLag`=5) — short lags very close to the search floor appear to
    /// have inflated autocorrelation scores unrelated to real periodicity,
    /// likely bleed from the STFT window's own ~4-hop (`fftSize`/`hopSize`)
    /// smoothing footprint, not true short-period rhythm. The three tracks
    /// that *did* correct cleanly all had half-lag candidates comfortably
    /// clear of that zone (lag 11–13). Added a margin requiring the
    /// half-lag candidate to clear `minLag` by more than that footprint
    /// before it's eligible, which — checked against the same 8 tracks by
    /// hand — excludes exactly the two bad cases while keeping the three
    /// genuine fixes. See CLAUDE.md Version History for the exact
    /// before/after numbers both times — this is now a twice-revised,
    /// evidence-based correction, still tuned against only 8 tracks;
    /// re-check against the same fixtures after any further tuning, and
    /// don't assume it's fully correct without doing so (`All_Night_Long`
    /// is still a known-unfixed case as of this revision).
    static func estimateTempo(onsetEnvelope: [Float], sampleRate: Double, hopSize: Int, debugLog: ((String) -> Void)? = nil) -> Double {
        guard onsetEnvelope.count > 4 else { return 120.0 } // Python's except-fallback

        let framesPerSecond = sampleRate / Double(hopSize)
        // 40...220 BPM, matching the range Python's post-processing "if bpm < 40: bpm *= 2"
        // implies as the plausible floor, with a generous ceiling for uptempo material.
        let minLag = max(1, Int((60.0 / 220.0) * framesPerSecond))
        let maxLag = min(onsetEnvelope.count - 1, Int((60.0 / 40.0) * framesPerSecond))
        guard minLag < maxLag else { return 120.0 }

        func autocorrelation(atLag lag: Int) -> Float {
            var score: Float = 0
            for i in 0..<(onsetEnvelope.count - lag) {
                score += onsetEnvelope[i] * onsetEnvelope[i + lag]
            }
            return score
        }

        var bestLag = minLag
        var bestScore: Float = -.greatestFiniteMagnitude
        for lag in minLag...maxLag {
            let score = autocorrelation(atLag: lag)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        // Octave-error correction. Check the half- and double-lag candidates
        // against the *original* winning lag (not chained against each
        // other, which would let the two checks fight and reverse one
        // another in marginal cases). Bias toward the halved-lag (faster)
        // reading, since that was the dominant failure mode observed
        // (4 of 5 octave errors): switch there if its score clears a modest
        // bar AND the candidate lag is comfortably clear of the search
        // floor (see doc comment above — near-floor lags are unreliable).
        // Only consider the doubled-lag (slower) reading if we didn't
        // already switch to halved, and require a clearer margin — the
        // reverse failure was rarer in the evidence available.
        let originalLag = bestLag
        let originalScore = bestScore
        let halfLag = originalLag / 2
        let doubleLag = originalLag * 2
        // Lags within roughly one STFT window's worth of hops from the
        // floor are where the window's own overlap-smoothing can inflate
        // autocorrelation independent of real periodicity — require
        // clearing that zone before trusting a halved-lag candidate.
        let minReliableLag = minLag + (fftSize / hopSize)

        var decision = "kept original"
        var halfScoreForLog: Float?
        var doubleScoreForLog: Float?

        if halfLag >= minReliableLag {
            let halfScore = autocorrelation(atLag: halfLag)
            halfScoreForLog = halfScore
            if halfScore >= originalScore * 0.7 {
                bestLag = halfLag
                bestScore = halfScore
                decision = "switched to half-lag"
            }
        }
        if bestLag == originalLag, doubleLag <= maxLag {
            let doubleScore = autocorrelation(atLag: doubleLag)
            doubleScoreForLog = doubleScore
            if doubleScore > originalScore * 1.15 {
                bestLag = doubleLag
                bestScore = doubleScore
                decision = "switched to double-lag"
            }
        }

        if let debugLog {
            // Built from plain pre-computed String locals, not one big
            // multi-interpolation literal — a first version of this with
            // several `\(...)` substitutions plus inline `.map()`/ternaries
            // in a single string literal made the Swift 5.10 type checker
            // crash outright ("failed to produce diagnostic for expression")
            // on Codemagic. Mechanical fix, not a logic change.
            let origBpmText = String(60.0 * framesPerSecond / Double(originalLag))
            let halfBpmText: String
            if halfLag >= 1 {
                halfBpmText = String(60.0 * framesPerSecond / Double(halfLag))
            } else {
                halfBpmText = "n/a"
            }
            let doubleBpmText = String(60.0 * framesPerSecond / Double(doubleLag))
            let halfScoreText = halfScoreForLog != nil ? String(halfScoreForLog!) : "not checked (below minReliableLag)"
            let doubleScoreText = doubleScoreForLog != nil ? String(doubleScoreForLog!) : "not checked"

            var lines: [String] = []
            lines.append("minLag=\(minLag) minReliableLag=\(minReliableLag) maxLag=\(maxLag)")
            lines.append("original: lag=\(originalLag) bpm=\(origBpmText) score=\(originalScore)")
            lines.append("half:     lag=\(halfLag) bpm=\(halfBpmText) score=\(halfScoreText)")
            lines.append("double:   lag=\(doubleLag) bpm=\(doubleBpmText) score=\(doubleScoreText)")
            lines.append("decision: \(decision) -> chosen lag=\(bestLag)")
            debugLog(lines.joined(separator: "\n"))
        }

        var bpm = 60.0 * framesPerSecond / Double(bestLag)
        if bpm < 40 { bpm *= 2 } // carried over directly from the Python post-processing step
        return (bpm * 10).rounded() / 10 // matches Python's round(bpm, 1)
    }
}
