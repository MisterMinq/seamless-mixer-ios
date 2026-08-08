import Foundation

/// Playlist ordering modes — matches CLAUDE.md's Playlist Detail / Source
/// Selection mode picker and `playlist_mixer.py --mode`.
public enum SequencingMode: String, Codable, CaseIterable {
    case energyUp = "energy_up"
    case energyWave = "energy_wave"
    case acousticToFusion = "acoustic_to_fusion"
    case stay = "stay"
}

/// Greedy nearest-neighbor playlist sequencing — direct port of
/// `playlist_mixer.py`'s `sequence_tracks` / `_transition_score` /
/// `normalize_energy_and_brightness`. Completes the core algorithmic loop
/// (data layer + analysis pipeline + this) needed before a playlist recipe
/// can actually be built on-device.
///
/// **Normalization design note — resolves a gap flagged since Version
/// History 0.14.0.** Python normalizes `energy`/`brightness` to 0...1
/// *fresh, per candidate pool*, immediately before sequencing — not once,
/// globally, at analysis time. The same track's normalized energy differs
/// depending on what other tracks are in the pool with it (relative to "my
/// whole library" vs. relative to just "Bebop Jazz" alone, say). That means
/// `tracks.energy`/`brightness` in the schema actually need to hold **raw,
/// unbounded analysis output** — matching exactly what `TrackAnalyzer`
/// already produces — not the 0...1 range the schema's original doc comment
/// assumed before this question was worked through. Normalization happens
/// here instead, ephemerally, over whichever pool is being sequenced right
/// now, mirroring Python exactly. Nothing persists a normalized value back
/// to the `tracks` table. (`Track.swift`'s doc comments should be read with
/// this in mind — worth tightening the wording there in a follow-up pass.)
public enum Sequencer {

    /// Rescales `energy`/`brightness` to 0...1 relative to the min/max
    /// *within this pool only* — direct port of `normalize_energy_and_brightness`.
    /// Returns a new array; never mutates the input or anything persisted.
    /// A track missing `energy`/`brightness` (not yet analyzed) is passed
    /// through unchanged — callers should filter to `track.isAnalyzed`
    /// first, as `sequence(tracks:...)` below does itself.
    public static func normalizeEnergyAndBrightness(_ tracks: [Track]) -> [Track] {
        guard !tracks.isEmpty else { return tracks }
        let energies = tracks.compactMap { $0.energy }
        let brightnesses = tracks.compactMap { $0.brightness }
        guard let eLo = energies.min(), let eHi = energies.max(),
              let bLo = brightnesses.min(), let bHi = brightnesses.max() else {
            return tracks
        }
        return tracks.map { track -> Track in
            var t = track
            if let e = track.energy {
                t.energy = (eHi == eLo) ? 0.5 : (e - eLo) / (eHi - eLo)
            }
            if let b = track.brightness {
                t.brightness = (bHi == bLo) ? 0.5 : (b - bLo) / (bHi - bLo)
            }
            return t
        }
    }

    /// How well `candidate` follows `last` at this point (`progress`, 0...1
    /// through the set) for `mode`'s target energy/brightness trajectory.
    /// Higher is better. Direct port of `_transition_score` — assumes
    /// already-normalized (0...1) energy/brightness, i.e. only meaningful
    /// after `normalizeEnergyAndBrightness`.
    ///
    /// Falls back to an unpickable score (rather than crashing) if either
    /// track is missing an analysis field — shouldn't happen given
    /// `sequence(tracks:...)` filters to `isAnalyzed` tracks first, but
    /// defensive here rather than force-unwrapping, since this function's
    /// safety depends on that caller-side filter continuing to hold.
    static func transitionScore(last: Track, candidate: Track, mode: SequencingMode, progress: Double) -> Double {
        guard let lastBpm = last.bpm, let lastEnergy = last.energy, let lastBrightness = last.brightness,
              let lastKey = last.musicalKey,
              let candBpm = candidate.bpm, let candEnergy = candidate.energy, let candBrightness = candidate.brightness,
              let candKey = candidate.musicalKey
        else {
            return -.greatestFiniteMagnitude
        }

        var s = 0.0
        // Harmonic compatibility: lower Camelot distance is better.
        s -= Double(CamelotKey.distance(lastKey, candKey)) * 2.0
        // Tempo continuity: penalize big BPM jumps (as % of tempo).
        let bpmJump = abs(candBpm - lastBpm) / max(lastBpm, 1e-6)
        s -= bpmJump * 6.0

        switch mode {
        case .energyUp:
            let targetEnergy = min(1.0, 0.15 + 0.85 * progress)
            s -= abs(candEnergy - targetEnergy) * 3.0
        case .energyWave:
            let targetEnergy = 0.5 + 0.4 * sin(progress * Double.pi * 2.5)
            s -= abs(candEnergy - targetEnergy) * 3.0
        case .acousticToFusion:
            let targetBrightness = min(1.0, 0.05 + 0.95 * progress)
            s -= abs(candBrightness - targetBrightness) * 3.0
            let targetEnergy = min(1.0, 0.2 + 0.7 * progress)
            s -= abs(candEnergy - targetEnergy) * 1.5
        case .stay:
            // Minimize movement in energy/brightness from the previous track.
            s -= abs(candEnergy - lastEnergy) * 3.0
            s -= abs(candBrightness - lastBrightness) * 1.0
        }
        return s
    }

    /// Greedy nearest-neighbor sequencing — direct port of `sequence_tracks`.
    ///
    /// - Parameters:
    ///   - tracks: candidate pool. Tracks that aren't fully analyzed
    ///     (`track.isAnalyzed == false`) or lack raw audio access (DRM —
    ///     see "DRM-Exclusion UX" in CLAUDE.md) are silently excluded before
    ///     sequencing, matching that section's confirmed default behavior.
    ///     Counting how many were excluded for the "44 of 47 songs included"
    ///     UI message is the caller's responsibility (compare `tracks.count`
    ///     against how many came back analyzed+accessible) — not returned
    ///     here, to keep this function's contract simple until a real caller
    ///     exists to shape that API around.
    ///   - targetSeconds: desired total duration; ignored when `keepAll` is true.
    ///   - mode: energy/brightness trajectory to aim for.
    ///   - seed: seeds the initial tie-breaking shuffle for reproducible
    ///     output. Not a cross-language-identical shuffle vs. Python's
    ///     `random.Random(seed)` (a from-scratch splitmix64 generator here,
    ///     not Python's Mersenne Twister) — just internally deterministic,
    ///     which is all the original shuffle was ever for (avoiding
    ///     alphabetical bias among score ties), not cross-language parity.
    ///   - keepAll: if true, every analyzed/accessible track in `tracks` is
    ///     included — only order/blending is decided; `targetSeconds` and
    ///     its tolerance are ignored, matching `--keep-all`.
    /// - Returns: the sequenced subset (or full set, if `keepAll`), each
    ///   track's `energy`/`brightness` rescaled relative to the *filtered
    ///   candidate pool*, not raw — ready for the mixing engine to read the
    ///   trajectory directly. Empty if nothing in `tracks` is usable.
    public static func sequence(
        tracks: [Track],
        targetSeconds: Double,
        mode: SequencingMode,
        seed: UInt64 = 42,
        keepAll: Bool = false
    ) -> [Track] {
        let usable = tracks.filter { $0.isAnalyzed && $0.hasRawAudioAccess }
        guard !usable.isEmpty else { return [] }

        var remaining = normalizeEnergyAndBrightness(usable)
        var rng = SeededGenerator(seed: seed)
        remaining.shuffle(using: &rng) // avoid ordering bias among score ties

        // Start with a mid-energy track for a natural build-up start.
        remaining.sort { abs(($0.energy ?? 0.5) - 0.3) < abs(($1.energy ?? 0.5) - 0.3) }
        var playlist = [remaining.removeFirst()]
        var total = playlist[0].durationSec

        var step = 0
        let nStart = remaining.count + 1

        func sortByScoreDescending(last: Track, progress: Double) {
            let scored = remaining.map { ($0, transitionScore(last: last, candidate: $0, mode: mode, progress: progress)) }
                .sorted { $0.1 > $1.1 }
            remaining = scored.map { $0.0 }
        }

        if keepAll {
            while !remaining.isEmpty {
                let progress = Double(step) / Double(max(1, nStart - 1))
                sortByScoreDescending(last: playlist[playlist.count - 1], progress: progress)
                let next = remaining.removeFirst()
                playlist.append(next)
                total += next.durationSec
                step += 1
            }
            return playlist
        }

        let tolerance = max(30.0, targetSeconds * 0.08) // ~8% or 30s, whichever is larger

        while !remaining.isEmpty {
            if total > targetSeconds + tolerance { break } // safety net; look-ahead below normally catches this first

            let progress = Double(step) / Double(max(1, nStart - 1))
            sortByScoreDescending(last: playlist[playlist.count - 1], progress: progress)

            // Prefer the best-scored candidate that actually fits within
            // tolerance. Only fall back to a candidate that overshoots if
            // literally nothing remaining would fit — and in that fallback
            // case, pick the smallest remaining track to minimize how badly
            // it overshoots, rather than blindly taking the top-scored one
            // regardless of length. Guards against a single disproportionately
            // long track getting pulled in just because it scored well
            // harmonically, while the pool is still well under target.
            let fits = remaining.filter { total + $0.durationSec <= targetSeconds + tolerance }
            let next = fits.first ?? remaining.min(by: { $0.durationSec < $1.durationSec })!
            let nextIndex = remaining.firstIndex(of: next)!

            // Once already within the acceptable window, don't add another
            // track if it would blow past the ceiling — stop here instead.
            let withinWindow = (targetSeconds - tolerance) <= total && total <= (targetSeconds + tolerance)
            if withinWindow && (total + next.durationSec) > targetSeconds + tolerance {
                break
            }

            remaining.remove(at: nextIndex)
            playlist.append(next)
            total += next.durationSec
            step += 1
        }

        return playlist
    }
}

/// A small deterministic PRNG (splitmix64) so `Sequencer.sequence(...)`'s
/// tie-breaking shuffle is reproducible given the same `seed`. Not intended
/// to match Python's `random.Random` bit-for-bit — a different algorithm
/// entirely — just internally deterministic. Conforms to
/// `RandomNumberGenerator` so it works directly with `shuffle(using:)`.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
