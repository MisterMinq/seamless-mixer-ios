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
    /// Seconds the blend is nudged *earlier* than "just long enough to reach
    /// the outgoing track's playable end" — so the whole blend runs its full
    /// equal-power curve and completes with real audio still under it, with
    /// margin to spare, rather than the blend window ending exactly at the
    /// outgoing track's end where the smallest timing slip leaves the last
    /// stretch of the fade playing against silence.
    ///
    /// **Added 2026-09-10 — Andy: "The next song sometimes just starts
    /// without enough blend. It just feels like crossfade and blending get
    /// weaker with time."** Root cause, traced through `PlaybackEngine`: the
    /// old offset (`playableDuration - crossfadeSec`) left the blend ending
    /// exactly at the outgoing track's natural end, so a crossfade that
    /// triggered even slightly late (a `Timer` tick coalesced/delayed under
    /// accumulated main-thread load over a long session — the "weaker with
    /// time" part) ran out of outgoing audio partway through, and the
    /// incoming track then finished fading in against nothing. Starting the
    /// blend `leadMarginSec` earlier gives every transition that much slack
    /// before it can degrade. Costs the last ~`leadMarginSec` of each
    /// outgoing track (already near-silent under the fade by then, and
    /// exactly the tail a DJ would drop anyway).
    public static let leadMarginSec: Double = 2.0

    /// Tempo-derived blend length: a slower song gets a longer, more
    /// graceful blend, a faster one a shorter/tighter one. Falls back to a
    /// 120bpm assumption if `bpm` is nil (shouldn't happen for anything
    /// `Sequencer` selected, since `Track.isAnalyzed` already requires it,
    /// but a safe default regardless) or non-positive, matching Python's
    /// `max(bpm, 1e-6)` divide-by-zero guard.
    ///
    /// **Base lengthened 2026-09-10** — same round as `leadMarginSec` above,
    /// per Andy's standing "blends feel too short" feedback. The tempo
    /// multiplier went from 6 beats to 8, and the clamp from `[2, 12]` to
    /// `[3, 16]`, so an ordinary-tempo blend is now ~4s rather than ~3s and
    /// a slow ballad can run up to 16s. Still tempo-scaled per Rule 4 — a
    /// fast track still gets a shorter blend than a slow one — just longer
    /// across the board.
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
        let base = min(max(beatLenSec * 8.0, 3.0), 16.0)
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
    ///
    /// **`leadMarginSec` subtracted 2026-09-10** — the blend now starts (and
    /// therefore finishes) that much earlier than the outgoing track's
    /// playable end, so the full curve completes with audio still under it.
    /// See `leadMarginSec`'s own doc comment. The `max(0, ...)` floor already
    /// covers a track too short to absorb the extra margin.
    public static func timing(for track: Track, extraSec: Double = 0) -> (startOffsetSec: Double, durationSec: Double) {
        let crossfadeSec = durationSec(forBPM: track.bpm, extraSec: extraSec)
        let playableDuration = track.playableDurationSec ?? track.durationSec
        return (max(0, playableDuration - crossfadeSec - leadMarginSec), crossfadeSec)
    }
}
