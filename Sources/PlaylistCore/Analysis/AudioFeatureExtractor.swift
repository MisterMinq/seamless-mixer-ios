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

    /// Number of mel-scale triangular filters used for the tempo-only onset
    /// envelope (added 2026-08-08, replacing the earlier linear-magnitude
    /// flux — see the doc comment on `estimateTempo` below for the full
    /// investigation and why this alone wasn't the fix). Chosen to match the
    /// count used when this was Python-validated. The filter construction in
    /// `melFilterbank` below is a simplified HTK-formula approximation, not
    /// librosa's exact Slaney-normalized one — flagged the same way the
    /// STFT-vs-CQT chroma simplification is, expect some numeric drift from
    /// the Python figures until cross-checked against real tracks.
    static let melFilterCount = 40
    /// Tempogram local-autocorrelation window length, in seconds — matches
    /// `librosa.feature.tempo`'s own default (`ac_size=8.0`).
    static let tempoAutocorrelationWindowSeconds = 8.0
    /// Spacing between successive tempogram windows, in seconds. librosa's
    /// own tempogram evaluates a window at *every* onset-envelope frame
    /// (hop=1); Python validation (see `estimateTempo`'s doc comment) found
    /// striding once per second instead gives identical accuracy on the same
    /// 28-track pool while cutting per-track compute by roughly two orders
    /// of magnitude and avoiding a second FFT-based autocorrelation
    /// primitive in this file.
    static let tempoWindowStrideSeconds = 1.0
    /// Log-normal tempo prior center (BPM) and width (octaves) — same
    /// defaults `librosa.feature.tempo` uses. Biases candidate lags toward
    /// plausible tempos *before* picking a winner, rather than picking the
    /// single strongest autocorrelation peak and patching it after the fact
    /// (what the earlier, superseded approach did).
    static let tempoPriorStartBpm = 120.0
    static let tempoPriorStdOctaves = 1.0
    /// Upper tempo bound considered, matching librosa's own default — mostly
    /// excludes near-zero-lag noise, not a realistic ceiling for this library.
    static let tempoMaxBpm = 320.0

    static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// - Parameters:
    ///   - samples: mono Float32 PCM, expected at `sampleRate` (22.05kHz for
    ///     analysis, matching Phase 1's `analysis_sr`, distinct from the
    ///     44.1kHz stereo decode used for the actual mix).
    ///   - tempoDebugLog: optional diagnostic sink for `estimateTempo`'s
    ///     chosen tempogram window count/lag/score — not used by any
    ///     production caller, only by `RealAudioValidationTests` while
    ///     validating tempo accuracy against real tracks. Defaults to `nil`
    ///     (no-op, no behavior change).
    public static func extract(samples: [Float], sampleRate: Double, tempoDebugLog: ((String) -> Void)? = nil) -> AnalysisFeatures {
        let energy = rms(samples)

        guard samples.count >= fftSize else {
            // Too short to frame at all — return safe Python-side fallback values
            // (mirrors the `except: bpm = 120.0` / `code = "8A"` fallbacks).
            return AnalysisFeatures(bpm: 120.0, camelotCode: "8A", energy: Double(energy), brightness: 2000.0)
        }

        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        let fft = FFTProcessor(fftSize: fftSize)
        let chromaFB = chromaFilterbank(sampleRate: sampleRate, fftSize: fftSize)

        var centroids: [Float] = []
        var chroma = [Float](repeating: 0, count: 12)

        var offset = 0
        while offset + fftSize <= samples.count {
            let frame = (0..<fftSize).map { samples[offset + $0] * window[$0] }
            let magnitudes = fft.magnitudeSpectrum(of: frame)

            centroids.append(spectralCentroid(magnitudes: magnitudes, sampleRate: sampleRate, fftSize: fftSize))
            accumulateChroma(magnitudes: magnitudes, filterbank: chromaFB, into: &chroma)

            offset += hopSize
        }

        let brightness = centroids.isEmpty ? 2000.0 : centroids.reduce(0, +) / Float(centroids.count)
        let camelotCode = detectKey(chroma: chroma)

        // Tempo runs its own, finer-hop, mel-scaled pass (see `tempoHopSize`
        // and `melFilterCount`'s doc comments) rather than reusing the
        // chroma/brightness loop above.
        let tempoOnsetEnvelope = computeMelOnsetEnvelope(samples: samples, window: window, fft: fft, sampleRate: sampleRate)
        let bpm = estimateTempo(onsetEnvelope: tempoOnsetEnvelope, sampleRate: sampleRate, hopSize: tempoHopSize, debugLog: tempoDebugLog)

        return AnalysisFeatures(bpm: bpm, camelotCode: camelotCode, energy: Double(energy), brightness: Double(brightness))
    }

    /// Runs an independent STFT pass at `tempoHopSize` (finer than the
    /// `hopSize` used for chroma/brightness above) purely to build the
    /// onset-strength envelope tempo estimation needs. Kept separate from
    /// the main loop in `extract` rather than just lowering `hopSize`
    /// itself, so the already-validated brightness/key numbers aren't
    /// perturbed and don't pay the cost of the denser hop for no benefit.
    ///
    /// Converts each frame's power spectrum through the mel filterbank and
    /// log-compresses it before taking frame-to-frame flux — replaces an
    /// earlier plain linear-magnitude version (2026-08-08). Mel-scaling
    /// alone wasn't the fix (tested in isolation against the old tempo
    /// heuristic, no better than linear); it only pays off combined with
    /// `estimateTempo`'s tempogram approach below — see that function's doc
    /// comment for the full validation trail.
    static func computeMelOnsetEnvelope(samples: [Float], window: [Float], fft: FFTProcessor, sampleRate: Double) -> [Float] {
        let filterbank = melFilterbank(sampleRate: sampleRate, fftSize: fftSize, melBins: melFilterCount)

        var onsetEnvelope: [Float] = []
        var previousMelDb: [Float]? = nil

        var offset = 0
        while offset + fftSize <= samples.count {
            let frame = (0..<fftSize).map { samples[offset + $0] * window[$0] }
            let magnitudes = fft.magnitudeSpectrum(of: frame)
            var power = [Float](repeating: 0, count: magnitudes.count)
            vDSP_vsq(magnitudes, 1, &power, 1, vDSP_Length(magnitudes.count))

            var melDb = [Float](repeating: 0, count: melFilterCount)
            power.withUnsafeBufferPointer { powerPtr in
                guard let base = powerPtr.baseAddress else { return }
                for m in 0..<filterbank.count {
                    let (start, weights) = filterbank[m]
                    guard !weights.isEmpty, start >= 0, start + weights.count <= powerPtr.count else { continue }
                    var sum: Float = 0
                    vDSP_dotpr(base + start, 1, weights, 1, &sum, vDSP_Length(weights.count))
                    melDb[m] = 10.0 * log10(sum + 1e-10)
                }
            }

            if let previous = previousMelDb {
                onsetEnvelope.append(spectralFlux(current: melDb, previous: previous))
            }
            previousMelDb = melDb

            offset += tempoHopSize
        }
        return onsetEnvelope
    }

    /// A simplified triangular mel filterbank: `melBins` overlapping
    /// triangles spanning 0Hz to Nyquist, spaced evenly on the mel scale
    /// (classic HTK formula: `mel = 2595·log10(1 + f/700)`). Returned as
    /// `(startBin, weights)` pairs rather than full-width sparse arrays,
    /// since a triangular filter's support is only a small fraction of the
    /// full spectrum — `computeMelOnsetEnvelope` only needs to sum over that
    /// narrow range per filter, not a full `melBins × fftSize/2` matrix
    /// multiply per frame.
    static func melFilterbank(sampleRate: Double, fftSize: Int, melBins: Int) -> [(startBin: Int, weights: [Float])] {
        func hzToMel(_ hz: Double) -> Double { 2595.0 * log10(1.0 + hz / 700.0) }
        func melToHz(_ mel: Double) -> Double { 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }

        let nyquist = sampleRate / 2.0
        let melMin = hzToMel(0)
        let melMax = hzToMel(nyquist)
        let fftBinCount = fftSize / 2

        let edgeMels = (0...(melBins + 1)).map { melMin + (melMax - melMin) * Double($0) / Double(melBins + 1) }
        let edgeBins = edgeMels.map { melHz -> Int in
            let hz = melToHz(melHz)
            return Int((hz * Double(fftSize) / sampleRate).rounded())
        }

        var filters: [(startBin: Int, weights: [Float])] = []
        filters.reserveCapacity(melBins)
        for m in 0..<melBins {
            let lower = edgeBins[m]
            let center = edgeBins[m + 1]
            let upper = edgeBins[m + 2]
            guard upper > lower, center > lower, upper > center else {
                filters.append((startBin: max(0, min(lower, fftBinCount - 1)), weights: []))
                continue
            }
            let start = max(0, lower)
            let end = min(fftBinCount - 1, upper)
            guard end >= start else {
                filters.append((startBin: start, weights: []))
                continue
            }
            var weights: [Float] = []
            weights.reserveCapacity(end - start + 1)
            for bin in start...end {
                let w: Float
                if bin < center {
                    w = center > lower ? Float(bin - lower) / Float(center - lower) : 0
                } else {
                    w = upper > center ? Float(upper - bin) / Float(upper - center) : 0
                }
                weights.append(max(0, w))
            }
            filters.append((startBin: start, weights: weights))
        }
        return filters
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

    /// Gaussian-bump, log-frequency chroma filterbank — replaces an earlier
    /// "round each FFT bin to its nearest semitone" approach (2026-08-08,
    /// same investigation session as the tempo rework above). That earlier
    /// approach was flagged as a deliberate STFT-vs-CQT simplification but
    /// turned out to have more room in it than the CQT gap alone accounted
    /// for: it scored 8/28 exact-key matches (mean Camelot distance 1.50)
    /// against the real `music_samplers/` pool. Testing librosa's own
    /// CQT-based `chroma_cqt` wasn't a valid comparison (Python's reference
    /// values *are* `chroma_cqt` output, so it trivially matches 28/28) —
    /// but librosa's own **STFT-based** `chroma_stft` (still no CQT) scored
    /// 13/28, meaningfully better than the hand-rolled version despite using
    /// the same underlying STFT. The difference: a smooth Gaussian weighting
    /// of each FFT bin's log-frequency position toward each of the 12 pitch
    /// classes (with the Gaussian's width adapting to local frequency
    /// resolution, and a broad "octave dominance" window de-emphasizing very
    /// low/high content), not a hard round-to-nearest-bin assignment. A
    /// from-scratch Python port of that exact construction (`librosa.filters.chroma`'s
    /// real formula, no librosa dependency, verified to match librosa's own
    /// filterbank to floating-point precision) combined with per-frame
    /// max-normalization before averaging scored 18/28 exact (mean distance
    /// 0.71) — better than librosa's own default pipeline, likely because
    /// this skips librosa's automatic per-track tuning estimation (a
    /// deliberate simplification here, not yet isolated on its own — see
    /// below). This function is a direct Swift port of that validated
    /// Python replica.
    ///
    /// Deliberate simplification: assumes exact A440 tuning (`tuning=0`) —
    /// librosa's default `chroma_stft` estimates a per-track tuning offset
    /// and corrects for it; skipping that is the same category of caveat as
    /// the mel filterbank's HTK-vs-Slaney gap. The Python validation above
    /// used the same assumption and still beat librosa's own
    /// tuning-corrected pipeline, so this isn't expected to be the dominant
    /// remaining error source — but hasn't been isolated on its own, and
    /// real-track key detection is still not "solved," just meaningfully
    /// better. Needs the same real-audio cross-check via
    /// `RealAudioValidationTests` before trusting the improvement holds.
    ///
    /// Returns a `(chromaBin, fftBin)`-shaped matrix — `12 × fftSize/2`,
    /// matching `FFTProcessor.magnitudeSpectrum`'s bin count (bins
    /// 0..<Nyquist; no separate Nyquist bin, a minor, deliberate difference
    /// from librosa's `fftSize/2 + 1`).
    static func chromaFilterbank(sampleRate: Double, fftSize: Int) -> [[Float]] {
        let chromaBins = 12
        let tuning = 0.0
        let a440 = 440.0 * pow(2.0, tuning / Double(chromaBins))

        var frqbins = [Double](repeating: 0, count: fftSize)
        for j in 1..<fftSize {
            let freq = Double(j) * sampleRate / Double(fftSize)
            frqbins[j] = Double(chromaBins) * log2(freq / (a440 / 16.0))
        }
        frqbins[0] = frqbins[1] - 1.5 * Double(chromaBins)

        var binwidthbins = [Double](repeating: 1.0, count: fftSize)
        for j in 0..<(fftSize - 1) {
            binwidthbins[j] = max(frqbins[j + 1] - frqbins[j], 1.0)
        }

        let chromaBins2 = (Double(chromaBins) / 2).rounded()
        var wts = [[Double]](repeating: [Double](repeating: 0, count: fftSize), count: chromaBins)
        for c in 0..<chromaBins {
            for j in 0..<fftSize {
                var d = frqbins[j] - Double(c) + chromaBins2 + 10.0 * Double(chromaBins)
                d = d.truncatingRemainder(dividingBy: Double(chromaBins)) - chromaBins2
                let bw = binwidthbins[j]
                wts[c][j] = exp(-0.5 * pow(2.0 * d / bw, 2))
            }
        }

        // Per-FFT-bin (column) L2 normalization.
        for j in 0..<fftSize {
            var sumSq = 0.0
            for c in 0..<chromaBins { sumSq += wts[c][j] * wts[c][j] }
            let norm = sumSq > 0 ? sqrt(sumSq) : 1.0
            for c in 0..<chromaBins { wts[c][j] /= norm }
        }

        // Octave-dominance window: a broad Gaussian centered ~5 octaves above
        // A0 (27.5Hz), i.e. roughly the middle of a typical instrument's
        // range, de-emphasizing very low (bass rumble) and very high
        // (harmonic-heavy) content without a hard cutoff.
        let octaveCenter = 5.0
        let octaveWidth = 2.0
        for j in 0..<fftSize {
            let octPosition = frqbins[j] / Double(chromaBins)
            let dominance = exp(-0.5 * pow((octPosition - octaveCenter) / octaveWidth, 2))
            for c in 0..<chromaBins { wts[c][j] *= dominance }
        }

        // Roll rows so chroma bin 0 aligns with pitch class C (matches
        // librosa's `base_c=True` default).
        var rolled = [[Double]](repeating: [Double](repeating: 0, count: fftSize), count: chromaBins)
        for c in 0..<chromaBins {
            rolled[c] = wts[(c + 3) % chromaBins]
        }

        let binCount = fftSize / 2
        return rolled.map { row in row[0..<binCount].map { Float($0) } }
    }

    /// Projects one frame's power spectrum through the chroma filterbank,
    /// max-normalizes the resulting 12-element frame chroma vector, and
    /// accumulates it into the running `chroma` total. Per-frame
    /// normalization (rather than accumulating raw magnitude, as the
    /// earlier version did) matches what librosa's own `chroma_stft` does
    /// and was part of what the Python validation above confirmed mattered.
    static func accumulateChroma(magnitudes: [Float], filterbank: [[Float]], into chroma: inout [Float]) {
        var power = [Float](repeating: 0, count: magnitudes.count)
        vDSP_vsq(magnitudes, 1, &power, 1, vDSP_Length(magnitudes.count))

        var frameChroma = [Float](repeating: 0, count: chroma.count)
        power.withUnsafeBufferPointer { powerPtr in
            guard let base = powerPtr.baseAddress else { return }
            for c in 0..<chroma.count {
                let filterRow = filterbank[c]
                let n = min(powerPtr.count, filterRow.count)
                guard n > 0 else { continue }
                var sum: Float = 0
                vDSP_dotpr(base, 1, filterRow, 1, &sum, vDSP_Length(n))
                frameChroma[c] = sum
            }
        }

        let maxVal = frameChroma.max() ?? 0
        if maxVal > 0 {
            for c in 0..<frameChroma.count { frameChroma[c] /= maxVal }
        }
        for c in 0..<chroma.count { chroma[c] += frameChroma[c] }
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

    /// Estimates tempo using a windowed-autocorrelation "tempogram" (Grosche/
    /// Müller/Kurth 2010 — the same technique `librosa.feature.tempo` uses
    /// internally) weighted by a log-normal prior toward common tempos,
    /// rather than picking a single global autocorrelation peak.
    ///
    /// **Replaces an earlier single-global-autocorrelation + half/double-lag
    /// octave-error-correction approach**, superseded the same day it was
    /// tuned (2026-08-08 — see CLAUDE.md Version History for the full trail;
    /// this doc comment summarizes the reasoning, not the blow-by-blow).
    /// That correction, after two rounds of threshold tuning against 8 real
    /// fixtures, plateaued at 6/8 correct with two failures neither round
    /// could resolve — a single-lag score-ratio guard structurally can't
    /// tell a legitimate near-floor correction from a spurious one using
    /// only the evidence available to it. Root-caused from there, per
    /// Andy's explicit instruction to solve this properly rather than defer
    /// it: feeding that same onset envelope into `librosa`'s own proven beat
    /// tracker only got 39-61% of the full 28-track `music_samplers/` pool
    /// right (depending on onset-envelope hop size) — meaning the ceiling
    /// was never really in the octave-correction heuristic. It was in "pick
    /// the single strongest peak, then patch it after the fact" as a
    /// strategy. Testing librosa's actual tempo-estimation algorithm (a
    /// dense tempogram + log-normal prior, weighting candidates *before*
    /// picking a winner) got 24/28 (86%) on the same pool. A from-scratch
    /// Python reimplementation of that algorithm, combined with
    /// `computeMelOnsetEnvelope` above (no librosa dependency, fully
    /// portable), matched it at 25-26/28 (89-93%) — that reimplementation is
    /// what this function ports.
    ///
    /// One deliberate deviation from librosa's own implementation: librosa
    /// evaluates a local autocorrelation window at *every single* onset-
    /// envelope frame (dense, hop=1) before averaging. Python validation
    /// found striding those windows once per second instead
    /// (`tempoWindowStrideSeconds`) gives identical accuracy on the same
    /// 28-track pool while cutting per-track compute by roughly two orders
    /// of magnitude — and, just as importantly, lets this reuse the same
    /// plain per-lag dot-product autocorrelation already validated and
    /// shipped (see `FFTProcessor`'s own doc comment on this being the
    /// highest-risk file in the project), rather than needing a second,
    /// FFT-based Wiener-Khinchin autocorrelation primitive that would have
    /// been genuinely new, higher-risk, unvalidated code.
    ///
    /// As with the STFT-vs-CQT chroma simplification, this depends on
    /// `melFilterbank`'s simplified (non-Slaney) filter construction — the
    /// Python figures above are the ceiling this is aiming for, not a
    /// guarantee. Needs the same real-audio cross-check via
    /// `RealAudioValidationTests` before being trusted.
    static func estimateTempo(onsetEnvelope: [Float], sampleRate: Double, hopSize: Int, debugLog: ((String) -> Void)? = nil) -> Double {
        guard onsetEnvelope.count > 8 else { return 120.0 } // Python's except-fallback

        let fps = sampleRate / Double(hopSize)
        let winLength = max(Int((tempoAutocorrelationWindowSeconds * fps).rounded()), 8)
        let strideFrames = max(Int((tempoWindowStrideSeconds * fps).rounded()), 1)

        // Center-pad with a linear ramp toward 0 at each end (matches the
        // Python-validated reference algorithm) so the first/last windows
        // aren't biased by an abrupt edge discontinuity.
        let padCount = winLength / 2
        var padded = [Float]()
        padded.reserveCapacity(onsetEnvelope.count + 2 * padCount)
        if padCount > 0, let first = onsetEnvelope.first {
            for i in 0..<padCount { padded.append(first * Float(i) / Float(padCount)) }
        }
        padded.append(contentsOf: onsetEnvelope)
        if padCount > 0, let last = onsetEnvelope.last {
            for i in 0..<padCount { padded.append(last * Float(padCount - i) / Float(padCount)) }
        }
        guard padded.count >= winLength else { return 120.0 }

        let hannWindow = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: winLength, isHalfWindow: false)
        var tgSum = [Float](repeating: 0, count: winLength - 1) // tgSum[i] corresponds to lag (i+1)
        var windowCount = 0

        var pos = 0
        while pos + winLength <= padded.count {
            var segment = [Float](repeating: 0, count: winLength)
            for i in 0..<winLength { segment[i] = padded[pos + i] * hannWindow[i] }

            // Direct per-lag dot-product autocorrelation — the same simple,
            // already-shipped approach the earlier global-autocorrelation
            // version used, just evaluated within one short local window
            // instead of across the whole track.
            var ac = [Float](repeating: 0, count: winLength - 1)
            segment.withUnsafeBufferPointer { segPtr in
                guard let base = segPtr.baseAddress else { return }
                for lag in 1..<winLength {
                    var score: Float = 0
                    vDSP_dotpr(base, 1, base + lag, 1, &score, vDSP_Length(winLength - lag))
                    ac[lag - 1] = score
                }
            }

            // Per-window max-normalize (librosa's norm=inf) so louder
            // windows don't dominate the cross-track average.
            var maxAbs: Float = 0
            for v in ac { maxAbs = max(maxAbs, abs(v)) }
            if maxAbs > 0 {
                for i in 0..<ac.count { ac[i] /= maxAbs }
            }
            for i in 0..<tgSum.count { tgSum[i] += ac[i] }

            windowCount += 1
            pos += strideFrames
        }
        guard windowCount > 0 else { return 120.0 }
        let tgMean = tgSum.map { $0 / Float(windowCount) }

        // Pick the lag maximizing log-compressed tempogram strength plus a
        // log-normal prior centered on a common tempo — the actual fix for
        // octave errors, replacing the old "pick strongest, then patch"
        // heuristic entirely.
        let logStartBpm = log2(Float(tempoPriorStartBpm))
        var bestLag = 1
        var bestScore: Float = -.greatestFiniteMagnitude
        for lag in 1..<winLength {
            let bpm = 60.0 * fps / Double(lag)
            guard bpm >= 20, bpm < tempoMaxBpm else { continue }
            let logPrior = -0.5 * pow((log2(Float(bpm)) - logStartBpm) / Float(tempoPriorStdOctaves), 2)
            let tgVal = max(0, tgMean[lag - 1])
            let score = log1p(1_000_000 * tgVal) + logPrior
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        if let debugLog {
            let bpmText = String(60.0 * fps / Double(bestLag))
            var lines: [String] = []
            lines.append("winLength=\(winLength) strideFrames=\(strideFrames) windowCount=\(windowCount)")
            lines.append("chosen: lag=\(bestLag) bpm=\(bpmText) score=\(bestScore)")
            debugLog(lines.joined(separator: "\n"))
        }

        var bpm = 60.0 * fps / Double(bestLag)
        if bpm < 40 { bpm *= 2 } // carried over directly from the Python post-processing step
        return (bpm * 10).rounded() / 10 // matches Python's round(bpm, 1)
    }
}
