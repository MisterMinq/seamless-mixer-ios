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
    /// 75% overlap between frames, standard for onset-detection use cases.
    static let hopSize = 1024

    static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// - Parameters:
    ///   - samples: mono Float32 PCM, expected at `sampleRate` (22.05kHz for
    ///     analysis, matching Phase 1's `analysis_sr`, distinct from the
    ///     44.1kHz stereo decode used for the actual mix).
    public static func extract(samples: [Float], sampleRate: Double) -> AnalysisFeatures {
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
        var onsetEnvelope: [Float] = []
        var previousMagnitudes: [Float]? = nil

        var offset = 0
        while offset + fftSize <= samples.count {
            let frame = (0..<fftSize).map { samples[offset + $0] * window[$0] }
            let magnitudes = fft.magnitudeSpectrum(of: frame)

            centroids.append(spectralCentroid(magnitudes: magnitudes, sampleRate: sampleRate, fftSize: fftSize))
            accumulateChroma(magnitudes: magnitudes, sampleRate: sampleRate, fftSize: fftSize, into: &chroma)

            if let previous = previousMagnitudes {
                onsetEnvelope.append(spectralFlux(current: magnitudes, previous: previous))
            }
            previousMagnitudes = magnitudes

            offset += hopSize
        }

        let brightness = centroids.isEmpty ? 2000.0 : centroids.reduce(0, +) / Float(centroids.count)
        let camelotCode = detectKey(chroma: chroma)
        let bpm = estimateTempo(onsetEnvelope: onsetEnvelope, sampleRate: sampleRate, hopSize: hopSize)

        return AnalysisFeatures(bpm: bpm, camelotCode: camelotCode, energy: Double(energy), brightness: Double(brightness))
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
    static func estimateTempo(onsetEnvelope: [Float], sampleRate: Double, hopSize: Int) -> Double {
        guard onsetEnvelope.count > 4 else { return 120.0 } // Python's except-fallback

        let framesPerSecond = sampleRate / Double(hopSize)
        // 40...220 BPM, matching the range Python's post-processing "if bpm < 40: bpm *= 2"
        // implies as the plausible floor, with a generous ceiling for uptempo material.
        let minLag = max(1, Int((60.0 / 220.0) * framesPerSecond))
        let maxLag = min(onsetEnvelope.count - 1, Int((60.0 / 40.0) * framesPerSecond))
        guard minLag < maxLag else { return 120.0 }

        var bestLag = minLag
        var bestScore: Float = -.greatestFiniteMagnitude
        for lag in minLag...maxLag {
            var score: Float = 0
            for i in 0..<(onsetEnvelope.count - lag) {
                score += onsetEnvelope[i] * onsetEnvelope[i + lag]
            }
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        var bpm = 60.0 * framesPerSecond / Double(bestLag)
        if bpm < 40 { bpm *= 2 } // carried over directly from the Python post-processing step
        return (bpm * 10).rounded() / 10 // matches Python's round(bpm, 1)
    }
}
