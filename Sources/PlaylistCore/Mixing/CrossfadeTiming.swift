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
    public static func durationSec(forBPM bpm: Double?) -> Double {
        let beatLenSec = 60.0 / max(bpm ?? 120.0, 0.000001)
        return min(max(beatLenSec * 6.0, 2.0), 12.0)
    }

    /// `startOffsetSec` is measured from the track's *playable* start (after
    /// `Track.playableStartSec`'s leading silence is skipped) — `PlaybackEngine`
    /// schedules playback starting from that same offset, so its elapsed-time
    /// measurement lines up with this value without any extra translation.
    /// Falls back to `track.durationSec` when `playableDurationSec` is nil
    /// (a row analyzed before trim detection existed), and floors the offset
    /// at 0 for a track shorter than its own crossfade window rather than
    /// producing a negative offset.
    public static func timing(for track: Track) -> (startOffsetSec: Double, durationSec: Double) {
        let crossfadeSec = durationSec(forBPM: track.bpm)
        let playableDuration = track.playableDurationSec ?? track.durationSec
        return (max(0, playableDuration - crossfadeSec), crossfadeSec)
    }
}
