import Foundation

/// Real per-transition crossfade timing — a direct port of
/// `playlist_mixer.py`'s `build_mix` math (`crossfade_sec = clip(beat_len_sec
/// * 6 beats, 2.0, 12.0)`, sized to the *outgoing* track's own tempo, per
/// Rule 4), moved here from `MixBuilder` on 2026-08-14 specifically so it can
/// be unit-tested — see `CrossfadeTimingTests.swift`.
///
/// This used to live as two `private static func`s inside `MixBuilder` (the
/// app target), which has no XCTest target at all, so a real, previously-
/// shipped bug in this exact math (a flat, never-validated `duration - 5s`
/// placeholder, see CLAUDE.md Version History 0.19.0) went uncaught until
/// real-device listening surfaced it. Pure, `Track`-in/numbers-out logic has
/// no dependency on `MediaPlayer`/`AVFoundation`/SwiftUI, so there's no
/// reason it needs to live where it can't be regression-tested by
/// `PlaylistCoreTests`' already-proven `swift test` pipeline.
public enum CrossfadeTiming {
    /// Tempo-derived blend length: a slower song gets a longer, more
    /// graceful blend, a faster one a shorter/tighter one. Falls back to a
    /// 120bpm assumption if `bpm` is nil (shouldn't happen for anything
    /// `Sequencer` selected, since `Track.isAnalyzed` already requires it,
    /// but a safe default regardless) or non-positive, matching Python's
    /// `max(bpm, 1e-6)` divide-by-zero guard.
    /// - Parameter extraSec: **added 2026-08-19**, per Andy's direct request
    ///   ("can the crossfade be extended... a time setting how long this can
    ///   be"). Added *after* the tempo-derived clip, not folded into it — a
    ///   slow song still gets a longer base blend than a fast one, the user
    ///   setting just adds a flat amount on top, rather than replacing the
    ///   tempo-awareness Rule 4 already confirmed shouldn't be relitigated.
    ///   Defaults to 0 (today's exact behavior) so every existing call site
    ///   is unaffected unless it opts in.
    public static func durationSec(forBPM bpm: Double?, extraSec: Double = 0) -> Double {
        let beatLenSec = 60.0 / max(bpm ?? 120.0, 0.000001)
        let base = min(max(beatLenSec * 6.0, 2.0), 12.0)
        return max(0, base + extraSec)
    }

    /// `startOffsetSec` is measured from the track's *playable* start (after
    /// `Track.playableStartSec`'s leading silence is skipped) — `PlaybackEngine`
    /// schedules playback starting from that same offset, so its elapsed-time
    /// measurement lines up with this value without any extra translation.
    /// Falls back to `track.durationSec` when `playableDurationSec` is nil
    /// (a row analyzed before trim detection existed), and floors the offset
    /// at 0 for a track shorter than its own crossfade window rather than
    /// producing a negative offset -- this is also what keeps a large
    /// `extraSec` safe for a short track: the crossfade simply can't start
    /// any earlier than the track's own beginning, so it's implicitly capped
    /// by however much of the track actually exists, not just by
    /// `extraSec`'s own value.
    public static func timing(for track: Track, extraSec: Double = 0) -> (startOffsetSec: Double, durationSec: Double) {
        let crossfadeSec = durationSec(forBPM: track.bpm, extraSec: extraSec)
        let playableDuration = track.playableDurationSec ?? track.durationSec
        return (max(0, playableDuration - crossfadeSec), crossfadeSec)
    }
}
