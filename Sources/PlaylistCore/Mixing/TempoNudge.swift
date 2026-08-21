import Foundation

/// The real-time playback-rate nudge applied to a crossfade's *incoming*
/// track — the last remaining piece of the confirmed mixing engine design
/// that's never been driven. `AVAudioUnitTimePitch` has been wired into
/// both player chains since the very first playback slice (0.17.0), but
/// nothing has ever set `.rate` on it; every crossfade has blended two
/// tracks at their own native tempos with no nudge at all.
///
/// Direct port of `playlist_mixer.py`'s `time_stretch_towards` ratio math
/// (`desired_ratio = to_bpm / from_bpm`, clamped to `±max_pct`) — carried
/// over deliberately per Rule 4, not reinvented. Phase 1 pre-processed the
/// *whole* incoming track's audio via an offline pitch-preserving
/// time-stretch (`librosa.effects.time_stretch(y, rate=ratio)`) before ever
/// mixing it in; the iOS equivalent achieves the same audible effect in
/// real time via `AVAudioUnitTimePitch.rate` on the incoming chain, set
/// once when a crossfade begins (`PlaybackEngine.beginCrossfade`) and left
/// in place for the rest of that track's playback — matching how Python's
/// stretch applied to the entire incoming track, not just the blend
/// window, and reset back to 1.0 (no nudge) whenever a chain starts a
/// fresh track with no crossfade partner to nudge toward
/// (`PlaybackEngine.playTrackAtCurrentIndex`, used for the first track of a
/// session and any hard-cut skip). `AVAudioUnitTimePitch.rate`'s own
/// semantics (`1.0` = normal speed, pitch held constant, tempo scales
/// linearly with the value) match librosa's `rate` parameter exactly, so
/// the same computed ratio applies directly with no translation.
public enum TempoNudge {
    /// `maxPct` matches Python's `time_stretch_towards`'s own default
    /// (`max_pct: float = 0.06`) — a ≤6% nudge, subtle enough to smooth a
    /// transition without fully beatmatching, per the confirmed mixing
    /// engine design's own "≤6% tempo nudge" wording.
    /// - Parameters:
    ///   - incomingBPM: the track about to crossfade in's own tempo
    ///     (`nxt.bpm` in Python).
    ///   - outgoingBPM: the tempo being nudged *toward* — the still-playing
    ///     track's own tempo (`current_bpm` in Python).
    /// - Returns: `1.0` (no nudge) if either bpm is missing or non-positive
    ///   — matching Python's `if from_bpm <= 0 or to_bpm <= 0: return y`
    ///   early-out — otherwise the clamped ratio to set directly on
    ///   `AVAudioUnitTimePitch.rate`.
    public static func rate(incomingBPM: Double?, outgoingBPM: Double?, maxPct: Double = 0.06) -> Double {
        guard let incomingBPM, let outgoingBPM, incomingBPM > 0, outgoingBPM > 0 else { return 1.0 }
        let desiredRatio = outgoingBPM / incomingBPM
        return min(max(desiredRatio, 1 - maxPct), 1 + maxPct)
    }
}
