import AVFoundation
import MediaPlayer

/// The AVAudioEngine mixing engine, per CLAUDE.md's "Mixing Engine —
/// AVAudioEngine Design" (first-pass design, confirmed back when Phase 2
/// architecture work happened). Built up in three slices, each pushed and
/// confirmed green on Codemagic before the next started: single-track
/// playback (0.17.0), sequential auto-advance with a hard cut between
/// tracks (0.17.1), and — this slice — actual equal-power crossfade
/// blending, which is the whole point of the app. Two `AVAudioPlayerNode`
/// chains ("A"/"B"), each through its own `AVAudioUnitTimePitch`, into the
/// engine's own `mainMixerNode` (standing in for the design's "shared
/// AVAudioMixerNode" — no need for a separate explicit mixer node when the
/// engine already provides one). The two chains alternate roles as
/// "active" (currently audible) and "standby" (silent, ready to be
/// pre-buffered into) as the playlist advances — the literal rolling-window
/// design ADR-3 called for: only two tracks' decoded audio are ever
/// scheduled at once, regardless of playlist length.
///
/// **How a transition actually works:** a repeating timer polls the active
/// chain's elapsed playback position (via `AVAudioPlayerNode.lastRenderTime`/
/// `playerTime(forNodeTime:)` — there's no simpler "notify me at position X"
/// API on `AVAudioPlayerNode`). Once elapsed time reaches the current
/// track's `crossfadeStartOffsetSec`, the next track is scheduled onto the
/// standby chain and both chains' volumes ramp against each other over
/// `crossfadeDurationSec`, using the exact same equal-power (sqrt) curve
/// `playlist_mixer.py`'s `equal_power_crossfade` already validated in
/// Phase 1 (`fade_out = sqrt(1 - t)`, `fade_in = sqrt(t)`) — carried over
/// deliberately per Rule 4, not reinvented. Once the ramp completes, the
/// chains swap roles and the old active chain is freed for the *next*
/// transition. No tempo nudge yet (`AVAudioUnitTimePitch` is wired into
/// both chains but not driven) — matching the confirmed design's "≤6%
/// tempo nudge" is a separate, not-yet-scoped follow-up.
///
/// **Stale-completion guard, extended from 0.17.1's generation counter:**
/// every time a chain gets a *new* file scheduled onto it — whether the
/// very first track, a crossfade-triggered pre-buffer of the next track, or
/// a hard-cut fallback advance — `playbackGeneration` is bumped and the new
/// value captured in that file's completion closure. A chain's completion
/// handler fires both when its file finishes playing naturally AND when
/// `.stop()` is called on it (which happens to the outgoing chain right
/// after a crossfade completes) — comparing the captured generation against
/// the current one is what tells those two cases apart, so a crossfade
/// swap doesn't also trigger a stale hard-cut advance for the track that
/// just finished blending out. `isCrossfading` is a separate, simpler guard
/// against the polling timer re-triggering a second crossfade for the same
/// transition while one is already in progress.
///
/// **Now published beyond just `isPlaying`/`nowPlayingTrackID`:**
/// `nextTrackPersistentID` (for a "blending into next" indicator),
/// `elapsedSeconds`/`currentTrackDurationSec` (for a progress bar) — added
/// alongside the Now Playing screen, the first real consumer of anything
/// beyond play/stop state. `elapsedSeconds` is read live off the active
/// chain's own render clock every tick rather than accumulated by hand;
/// `currentTrackDurationSec` comes from the decoded `AVAudioFile` itself
/// (this class never sees the analyzed `Track` record, only a
/// `trackPersistentID`).
///
/// **Highest-risk file in the app target — first use of AVAudioEngine/
/// AVAudioSession/AVAudioFile anywhere in this codebase, and this slice
/// adds real-time volume automation and elapsed-position polling on top of
/// that.** Compiles against the real AVFoundation SDK but is otherwise
/// entirely unverified: neither this environment nor Codemagic's Simulator
/// build has a real, populated media library or a way to actually listen to
/// real audio output, so there is no way to confirm the crossfade actually
/// sounds right (timing, curve, absence of clicks/gaps) short of a real
/// device. Needs a real-device listening check before this is trusted.
///
/// **Fixed 2026-08-13, after Andy's first real-device listening pass
/// surfaced real, confirmed problems ("the crossfade doesn't happen or is
/// way off balance... two songs playing... chaotic"), three separate bugs:**
/// (1) `play(queue:)` only stopped whichever chain was about to be reused,
/// never the *other* one — if a previous session had left the standby chain
/// still sounding (e.g. mid-crossfade when the user navigated away and
/// tapped Play again, see `PlaylistDetailView`'s resume-not-restart fix),
/// it kept playing at full volume right alongside the freshly started
/// track. Fixed by stopping and resetting *both* chains before every
/// `play(queue:)` call. (2) Every transition used a fixed 4.0s crossfade
/// window regardless of tempo — replaced with `QueuedTrack.crossfadeDurationSec`,
/// computed per-transition by `MixBuilder` the same way Phase 1's
/// `build_mix` does (`clip(60/bpm * 6 beats, 2s, 12s)`). (3) Playback never
/// trimmed leading silence or a trailing musical fade-out, so a crossfade
/// could ride straight into dead air or a fade-out already in progress —
/// exactly the "first song really stops, fades to nothing, then next
/// starts" symptom, and a bug Phase 1 already hit and fixed
/// (`trim_silence`/`trim_fade_tail`) but this port never carried over.
/// Fixed via `QueuedTrack.playableStartSec` (from `AudioFeatureExtractor
/// .detectTrimPoints`) and `AVAudioPlayerNode.scheduleSegment` instead of
/// `scheduleFile`, in the shared `schedule(file:on:playableStartSec:generation:)`
/// helper both `playTrackAtCurrentIndex` and `beginCrossfade` now use.
///
/// **Real transport added 2026-08-14**, after the fix above shipped but
/// real-device testing found there was no way to actually verify it — the
/// only control was a hardcoded Stop button (tearing the whole session down
/// and auto-navigating away, misread as "pause is broken"), with no seek, so
/// reaching a real crossfade meant waiting out an entire track. Added
/// `pause()`/`resume()` (via `AVAudioPlayerNode.pause()`/`.play()`, which
/// natively preserve position — no extra bookkeeping needed), `seek(toSeconds:)`,
/// and `skipToNext()`/`skipToPrevious()`. This needed `elapsedSeconds` to stop
/// being purely "seconds since this chain's current segment started
/// rendering" (which a seek would otherwise reset to 0) and become
/// `elapsedBaseSec` (the segment's own starting offset within the track) plus
/// that live render-clock reading — see `elapsedBaseSec`'s own doc comment.
/// `schedule(...)` no longer returns a duration for the caller to display —
/// that's now computed separately via `playableDuration(file:fromSec:)`
/// against the track's own `playableStartSec`, so a seek's different starting
/// frame doesn't also (wrongly) shrink the progress bar's displayed total.
@MainActor
final class PlaybackEngine: ObservableObject {
    /// One entry in a playback queue — everything `PlaybackEngine` needs to
    /// know about a track to play it and, if there's another track after
    /// it, to blend into that next one at the right moment.
    struct QueuedTrack {
        let trackPersistentID: Int64
        /// Seconds into this track's *playable* content (after
        /// `playableStartSec`'s leading silence is skipped) when the blend
        /// into the next one should begin. Meaningless for the last track in
        /// a queue (there's nothing to blend into) — `play(trackPersistentID:)`'s
        /// single-track convenience passes `.infinity` here specifically so
        /// `checkCrossfadeTrigger`'s `isFinite` guard never fires for it.
        let crossfadeStartOffsetSec: Double
        /// How long *this* transition's blend lasts, in seconds — tempo-derived
        /// per track by `MixBuilder.crossfadeDurationSec(forBPM:)`, not a
        /// fixed value. Read at `beginCrossfade()` time into
        /// `activeCrossfadeDurationSec`.
        let crossfadeDurationSec: Double
        /// Seconds of leading near-silence to skip when scheduling this
        /// track — see `AudioFeatureExtractor.detectTrimPoints`. 0 for a
        /// track with no trim data (shouldn't happen for anything the
        /// Sequencer selected, since `Track.isAnalyzed` requires it, but a
        /// safe no-op default regardless).
        let playableStartSec: Double
    }

    @Published private(set) var isPlaying = false
    /// True while playback is paused mid-session (as opposed to stopped —
    /// `isPlaying` stays true while paused, since the session is still
    /// "loaded," just not audibly advancing). Added 2026-08-14 alongside
    /// real `pause()`/`resume()` support.
    @Published private(set) var isPaused = false
    @Published var playbackError: String?
    /// The persistent ID of the track currently active (audible), or `nil`
    /// when stopped. During a crossfade this still reports the *outgoing*
    /// track until the swap completes — the incoming track becomes
    /// "now playing" only once it's the sole audible one, matching how a
    /// listener would describe what's playing mid-blend.
    @Published private(set) var nowPlayingTrackID: Int64?
    /// The `Playlist.id` whose queue is currently loaded, or `nil` when
    /// stopped. Added 2026-08-13 so `PlaylistDetailView`'s Play button can
    /// tell "this exact playlist is already playing" apart from "something
    /// else is playing" or "nothing is" — tapping Play used to always
    /// restart from track 1 regardless, which was the direct cause of the
    /// navigation dead-end Andy hit (no way back to Now Playing except
    /// re-tapping Play, which then restarted the whole session).
    @Published private(set) var currentPlaylistID: Int64?
    /// The track right after `nowPlayingTrackID` in the queue, or `nil` if
    /// there isn't one — what Now Playing's "blending into next" indicator
    /// reads from. Kept in sync alongside `nowPlayingTrackID` rather than
    /// computed on demand by a view, since only this class actually knows
    /// `currentIndex`/`queue`.
    @Published private(set) var nextTrackPersistentID: Int64?
    /// Elapsed seconds into the currently active track, refreshed every
    /// timer tick from `elapsedBaseSec` plus the active chain's own live
    /// render-clock reading (see `computeElapsedSeconds(for:)`) — not
    /// manually accumulated, so it stays correct across pauses and reflects
    /// a `seek(toSeconds:)` immediately rather than waiting for the next tick.
    @Published private(set) var elapsedSeconds: Double = 0
    /// Duration of the currently active track, read directly off the
    /// decoded `AVAudioFile` at schedule time (`length` frames / sample
    /// rate) rather than from `Track.durationSec` — this class only ever
    /// sees a `trackPersistentID`, never the analyzed `Track` record, so
    /// the file itself is the only duration source it actually has.
    @Published private(set) var currentTrackDurationSec: Double = 0

    private struct PlayerChain {
        let player: AVAudioPlayerNode
        let timePitch: AVAudioUnitTimePitch
    }

    private let engine = AVAudioEngine()
    private let chainA = PlayerChain(player: AVAudioPlayerNode(), timePitch: AVAudioUnitTimePitch())
    private let chainB = PlayerChain(player: AVAudioPlayerNode(), timePitch: AVAudioUnitTimePitch())

    /// Which chain is currently "active" (audible / about to become
    /// audible). Toggles once per completed crossfade. The two computed
    /// properties below are the only places the rest of this class should
    /// reference a chain by role rather than by name.
    private var activeIsA = true
    private var activeChain: PlayerChain { activeIsA ? chainA : chainB }
    private var standbyChain: PlayerChain { activeIsA ? chainB : chainA }

    /// The full playback queue for the current session, in playlist order.
    /// Set once by `play(queue:)` and walked forward by `currentIndex` as
    /// each track finishes or crossfades into the next.
    private var queue: [QueuedTrack] = []
    private var currentIndex = 0

    /// Bumped every time a *new* file is scheduled onto either chain — see
    /// this class's own doc comment for why this is what lets a stale
    /// completion handler be told apart from a real one.
    private var playbackGeneration = 0

    /// A crossfade transition's progress, 0...1, only meaningful while
    /// `isCrossfading` is true.
    private var isCrossfading = false
    private var crossfadeProgress: Double = 0
    /// Length of the *current* transition's blend window — set for real at
    /// `beginCrossfade()` time from that transition's own
    /// `QueuedTrack.crossfadeDurationSec` (tempo-derived, per the confirmed
    /// design's "sized to a few beats at the current tempo"). The 4.0
    /// default here only matters before the first crossfade of a session
    /// ever runs.
    private var activeCrossfadeDurationSec: Double = 4.0

    private var timer: Timer?
    private let tickIntervalSec: Double = 0.1

    /// The next (incoming) track's duration, computed and stashed the
    /// moment `beginCrossfade` schedules it, then applied to
    /// `currentTrackDurationSec` once `completeCrossfade` makes it the
    /// active track — the file's already open and decoded by then, no
    /// reason to look it up twice.
    private var pendingIncomingDurationSec: Double = 0

    /// Seconds into the *track's own playable content* (from
    /// `playableStartSec`, not raw frame 0) at which the currently active
    /// chain's scheduled segment begins. Normally 0 — a fresh track or a
    /// crossfade's incoming track both start at their own playable
    /// beginning. `seek(toSeconds:)` sets this to the seeked-to position,
    /// since it reschedules a segment starting partway through. `tick()`
    /// adds this to the chain's own live render-clock reading
    /// (`computeElapsedSeconds`, which restarts at 0 every time a new
    /// segment is scheduled) to get `elapsedSeconds`, so seeking doesn't
    /// need to fight the render clock's own reset-on-reschedule behavior.
    private var elapsedBaseSec: Double = 0

    /// True while a session was paused *by an interruption* (a phone call,
    /// another app taking over audio, an alarm) rather than by the user
    /// tapping Pause themselves — see `handleInterruption`. Distinguishing
    /// the two matters: only an interruption-caused pause should ever
    /// auto-resume once the interruption ends; a manual pause must stay
    /// paused until the user resumes it themselves.
    private var pausedByInterruption = false

    init() {
        configureGraph()
        observeInterruptions()
    }
    // No `deinit`/observer teardown -- `PlaybackEngine` is created exactly
    // once, as `SeamlessMixerApp`'s own `@StateObject`, and lives for the
    // app's entire process lifetime (never deallocated while running), so
    // there's no real leak to guard against here. Also sidesteps a real
    // Swift-concurrency footgun: reading this `@MainActor` class's stored
    // properties from a `deinit` (which runs nonisolated) is exactly the
    // kind of thing this project has been bitten by before (see CLAUDE.md's
    // 0.15.6/0.24.1 entries) -- not worth the risk for cleanup that would
    // never actually run.

    /// Attaches and connects both chains into the engine's main mixer, per
    /// the confirmed design's "shared AVAudioMixerNode, which is where the
    /// actual blend happens". Called once from `init`.
    private func configureGraph() {
        for chain in [chainA, chainB] {
            engine.attach(chain.player)
            engine.attach(chain.timePitch)
            engine.connect(chain.player, to: chain.timePitch, format: nil)
            engine.connect(chain.timePitch, to: engine.mainMixerNode, format: nil)
        }
    }

    /// Background-audio-capable session, per the confirmed design ("the
    /// whole graph runs inside an `AVAudioSession` configured for
    /// background audio") — `UIBackgroundModes: audio` is already declared
    /// in `project.yml`'s Info.plist (added back in 0.15.0, well ahead of
    /// any real engine code existing, specifically so this wouldn't need a
    /// separate Info.plist change once the engine actually landed).
    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    /// **Added 2026-08-14, closing a real gap flagged across three separate
    /// real-device reports** (a phone call, another app taking over audio,
    /// and an alarm all reported the identical symptom: playback stopped
    /// and never resumed). All three trigger the exact same
    /// `AVAudioSession.interruptionNotification` — a phone call and an
    /// alarm both count as "another app/system service took the audio
    /// session," from `AVAudioSession`'s point of view, regardless of how
    /// different they feel to a listener. This had never been observed at
    /// all before now; nothing paused this engine when an interruption
    /// began, so the two chains kept trying to render into an audio session
    /// that had just been seized by something else.
    ///
    /// Registered once, in `init`, using the block-based API rather than
    /// `self`-as-observer/`#selector` — this class has no Objective-C
    /// runtime dependency anywhere else, no reason to introduce one just for
    /// this. The closure hops onto the main actor before touching any
    /// `@Published`/isolated state, the same discipline every other
    /// AVFoundation completion handler in this file already follows.
    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleInterruption(notification: notification)
            }
        }
    }

    /// `.began`: pause in place (both chains, if a crossfade happens to be
    /// mid-blend) and remember that *this* pause was interruption-caused,
    /// not a user tap, via `pausedByInterruption` -- otherwise `.ended`
    /// couldn't tell "resume this, the user didn't mean to stop" apart from
    /// "leave this alone, the user paused on purpose right before the
    /// interruption arrived."
    ///
    /// `.ended`: only acts if `pausedByInterruption` is still true (guards
    /// against a stray `.ended` with nothing to resume). Checks
    /// `AVAudioSessionInterruptionOptionKey`'s `.shouldResume` flag, which
    /// iOS sets when it's telling apps it's safe to resume audio on their
    /// own (true for a phone call ending or an alarm being dismissed/
    /// snoozed; iOS does *not* set this for some interruptions, e.g. another
    /// app that's still actively playing audio itself) -- resuming only
    /// when iOS actually says to is what keeps this from fighting another
    /// app that intends to keep the audio session for itself.
    /// Re-activates the session before calling `resume()` since the
    /// interruption may have deactivated it out from under this engine.
    private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            guard isPlaying, !isPaused else { return }
            pause()
            pausedByInterruption = true

        case .ended:
            guard pausedByInterruption else { return }
            pausedByInterruption = false
            let shouldResume = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume)
            } ?? false
            guard shouldResume else { return }
            try? activateSession()
            resume()

        @unknown default:
            break
        }
    }

    /// Resolves a track's real, playable file via `MPMediaQuery`, filtered
    /// by its own `persistentID` — the same identity `tracks.persistent_id`
    /// already uses everywhere else in this app. Not stored redundantly
    /// anywhere (the `tracks` table holds analysis results, not a file
    /// path/URL), so re-querying is the correct, single source of truth for
    /// "what file does this track actually point to right now" — consistent
    /// with `MixBuilder.upsertAndAnalyzeIfNeeded`'s own `item.assetURL`
    /// access pattern.
    ///
    /// Requires media-library authorization to already be granted — true in
    /// the normal flow, since reaching Playlist Detail means Build Mix
    /// already ran, which means `SourceSelectionViewModel`'s authorization
    /// request already succeeded. A cold-launch-straight-into-an-existing-
    /// playlist path that skipped that flow could theoretically hit this
    /// unauthorized, in which case `query.items` comes back empty rather
    /// than throwing — surfaces as the same "couldn't find a playable file"
    /// error `playTrackAtCurrentIndex` already handles, not a crash.
    private func resolveFileURL(trackPersistentID: Int64) -> URL? {
        let query = MPMediaQuery.songs()
        let mediaID = UInt64(bitPattern: trackPersistentID)
        query.addFilterPredicate(MPMediaPropertyPredicate(value: mediaID, forProperty: MPMediaItemPropertyPersistentID))
        guard let item = query.items?.first else { return nil }
        // `assetURL` comes back nil for Apple Music subscription-streamed
        // (FairPlay-protected) tracks, per the DRM-Exclusion UX — the
        // Sequencer already filters these out of any pool before a
        // playlist is even built, so a nil URL here would mean the track's
        // access status changed since the playlist was built (e.g. a
        // download was removed), not a bug in this function.
        return item.assetURL
    }

    /// Elapsed playback seconds for a given player, computed from its own
    /// render clock rather than tracked manually — accounts correctly for
    /// however long the engine has actually been rendering audio for this
    /// node. Returns `nil` before the node has started rendering (no valid
    /// render time yet).
    private func computeElapsedSeconds(for player: AVAudioPlayerNode) -> Double? {
        guard let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    /// Plays a whole ordered queue, blending between tracks per each
    /// entry's `crossfadeStartOffsetSec`/`crossfadeDurationSec` where
    /// there's a next track to blend into. Always fully stops *both* chains
    /// first, not just resets volumes — a previous session may genuinely
    /// still be playing (e.g. the standby chain mid-crossfade when the user
    /// navigated away and is now re-tapping Play), and starting a new
    /// session without silencing that one is exactly the "two songs
    /// playing, chaotic" bug found 2026-08-13 (see this class's own doc
    /// comment). Bumping `playbackGeneration` here too ensures any
    /// completion handler still in flight from that previous session is
    /// recognized as stale and ignored.
    ///
    /// - Parameter playlistID: the `Playlist.id` this queue came from, if
    ///   any — stored as `currentPlaylistID` so a caller (`PlaylistDetailView`)
    ///   can tell whether tapping Play again should resume viewing this same
    ///   session or start a genuinely new one. `nil` for the single-track
    ///   convenience below, which has no playlist to associate with.
    func play(queue: [QueuedTrack], startIndex: Int = 0, playlistID: Int64? = nil) {
        stopTimer()
        playbackGeneration += 1
        chainA.player.stop()
        chainB.player.stop()
        chainA.player.volume = 1
        chainB.player.volume = 1

        self.queue = queue
        self.currentIndex = startIndex
        self.currentPlaylistID = playlistID
        activeIsA = true
        isCrossfading = false
        crossfadeProgress = 0

        playTrackAtCurrentIndex()
        startTimerIfNeeded()
    }

    /// Convenience for the single-track case. Kept as its own entry point
    /// since "play just this one track" is still a meaningful, simpler
    /// action distinct from "play the whole set." `crossfadeDurationSec`'s
    /// value here is unused (`crossfadeStartOffsetSec: .infinity` means the
    /// crossfade trigger never fires for a single-track queue).
    func play(trackPersistentID: Int64) {
        play(queue: [QueuedTrack(
            trackPersistentID: trackPersistentID, crossfadeStartOffsetSec: .infinity,
            crossfadeDurationSec: 4.0, playableStartSec: 0
        )])
    }

    /// Schedules `file` onto `chain`, starting `playableStartSec` seconds in
    /// rather than always at frame 0 — skips a track's leading near-silence
    /// (per `AudioFeatureExtractor.detectTrimPoints`) so a crossfade blends
    /// into real audio, not dead air. Shared by both `playTrackAtCurrentIndex`
    /// (a fresh start or hard-cut advance) and `beginCrossfade` (the incoming
    /// track) — both need the identical stop/trim/schedule/play sequence,
    /// just onto a different chain with a different starting volume, which
    /// the caller sets before calling this.
    ///
    /// Uses `AVAudioPlayerNode.scheduleSegment` instead of `scheduleFile` so
    /// the skipped lead-in never gets decoded/rendered at all, not just
    /// muted. Elapsed time measured afterward via `computeElapsedSeconds`
    /// (`playerTime(forNodeTime:)`) is relative to when *this scheduled
    /// segment* starts sounding — i.e. already relative to the playable
    /// start, matching how `MixBuilder.crossfadeTiming` computed
    /// `crossfadeStartOffsetSec` in the first place, no extra translation
    /// needed at either end.
    ///
    /// Pure scheduling, no return value — see `playableDuration(file:fromSec:)`
    /// for the separate, seek-independent duration calculation used for
    /// display.
    private func schedule(file: AVAudioFile, on chain: PlayerChain, playableStartSec: Double, generation: Int) {
        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let startFrame = min(max(0, AVAudioFramePosition(playableStartSec * sampleRate)), max(0, totalFrames - 1))
        let remainingFrames = AVAudioFrameCount(max(0, totalFrames - startFrame))

        let completion: () -> Void = { [weak self] in
            // Fires on an internal AVAudioEngine thread -- hop back to
            // the main actor before touching any `@Published`/isolated
            // state, same discipline `MixBuilder`'s GRDB `await`s
            // already established.
            Task { @MainActor in
                self?.handleTrackFinished(generation: generation)
            }
        }

        chain.player.stop()
        if remainingFrames > 0 {
            chain.player.scheduleSegment(file, startingFrame: startFrame, frameCount: remainingFrames, at: nil, completionHandler: completion)
        } else {
            // Degenerate case (playableStartSec >= file length) shouldn't
            // happen for real audio, but falling back to the whole file is
            // safer than scheduling a zero-frame segment.
            chain.player.scheduleFile(file, at: nil, completionHandler: completion)
        }
        chain.player.play()
    }

    /// The track's *total* playable duration from `fromSec` (normally a
    /// track's own `playableStartSec`) to the end of the file — used to set
    /// `currentTrackDurationSec`. Deliberately separate from `schedule(...)`'s
    /// own start-frame math: a `seek(toSeconds:)` reschedules from a
    /// different, later starting point than the track's own playable start,
    /// but the progress bar's displayed *total* shouldn't shrink just
    /// because playback resumed partway through — only `elapsedSeconds`
    /// should move.
    private func playableDuration(file: AVAudioFile, fromSec: Double) -> Double {
        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let startFrame = min(max(0, AVAudioFramePosition(fromSec * sampleRate)), max(0, totalFrames - 1))
        return Double(totalFrames - startFrame) / sampleRate
    }

    /// Schedules and plays `queue[currentIndex]` onto the *active* chain, or
    /// stops cleanly if `currentIndex` has walked off the end of the queue
    /// (the whole set finished playing with no crossfade left to do). This
    /// is both the initial-play path and the hard-cut fallback path (used
    /// when a track finishes naturally with no crossfade having taken over
    /// — see `handleTrackFinished`).
    private func playTrackAtCurrentIndex() {
        guard queue.indices.contains(currentIndex) else {
            isPlaying = false
            nowPlayingTrackID = nil
            nextTrackPersistentID = nil
            elapsedSeconds = 0
            currentTrackDurationSec = 0
            stopTimer()
            return
        }

        let queuedTrack = queue[currentIndex]
        playbackError = nil

        guard let url = resolveFileURL(trackPersistentID: queuedTrack.trackPersistentID) else {
            playbackError = "Couldn't find a playable file for this track."
            isPlaying = false
            nowPlayingTrackID = nil
            nextTrackPersistentID = nil
            stopTimer()
            return
        }

        do {
            try activateSession()
            let file = try AVAudioFile(forReading: url)

            if !engine.isRunning {
                try engine.start()
            }

            playbackGeneration += 1
            let generation = playbackGeneration

            let chain = activeChain
            chain.player.volume = 1
            currentTrackDurationSec = playableDuration(file: file, fromSec: queuedTrack.playableStartSec)
            elapsedBaseSec = 0
            schedule(file: file, on: chain, playableStartSec: queuedTrack.playableStartSec, generation: generation)
            isPlaying = true
            isPaused = false
            nowPlayingTrackID = queuedTrack.trackPersistentID
            elapsedSeconds = 0
            updateNextTrackID()
        } catch {
            playbackError = "Couldn't play this track: \(error.localizedDescription)"
            isPlaying = false
            nowPlayingTrackID = nil
            nextTrackPersistentID = nil
            stopTimer()
        }
    }

    /// Refreshes `nextTrackPersistentID` from `queue`/`currentIndex` — called
    /// any time either changes so a view never has to compute this itself.
    private func updateNextTrackID() {
        nextTrackPersistentID = queue.indices.contains(currentIndex + 1) ? queue[currentIndex + 1].trackPersistentID : nil
    }

    /// Fires when a *scheduled file* finishes or is superseded. Only acts
    /// if `generation` still matches the current `playbackGeneration` — see
    /// this class's own doc comment for why a stale match must be ignored.
    /// When it does match, it always means "the active track ended with no
    /// crossfade having taken over for this transition" (a genuine crossfade
    /// always bumps `playbackGeneration` itself when it schedules the next
    /// track, which is what makes a *later* stale completion fail this
    /// check) — so the correct response is always the same hard-cut
    /// advance regardless of *why* no crossfade happened (last track in the
    /// queue, a crossfade offset that was never reached, or the next
    /// track's file failing to resolve at crossfade time).
    private func handleTrackFinished(generation: Int) {
        guard generation == playbackGeneration else { return }
        currentIndex += 1
        playTrackAtCurrentIndex()
    }

    // MARK: - Crossfade timing

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: tickIntervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isPlaying, !isPaused else { return }
        if let elapsed = computeElapsedSeconds(for: activeChain.player) {
            elapsedSeconds = elapsedBaseSec + elapsed
        }
        if isCrossfading {
            advanceCrossfade()
        } else {
            checkCrossfadeTrigger()
        }
    }

    /// Polled every tick while not already crossfading — starts one the
    /// moment the active track's elapsed playback time reaches its own
    /// `crossfadeStartOffsetSec`, provided there's a next track in the
    /// queue to blend into. Compares against `elapsedSeconds` (already
    /// includes `elapsedBaseSec`, just set by `tick()` above this same
    /// call) rather than a fresh raw render-clock read, since both are
    /// measured relative to the track's playable start either way.
    private func checkCrossfadeTrigger() {
        guard queue.indices.contains(currentIndex), currentIndex + 1 < queue.count else { return }
        let offset = queue[currentIndex].crossfadeStartOffsetSec
        guard offset.isFinite, offset > 0, elapsedSeconds >= offset else { return }
        beginCrossfade()
    }

    /// Schedules the next track onto the standby chain at silence (volume
    /// 0) and starts it playing alongside the still-audible active chain —
    /// both tracks are genuinely sounding at once during the blend window,
    /// per the confirmed design ("both tracks play simultaneously for the
    /// crossfade window"), not a pre-rendered blended file. If the next
    /// track's file can't be resolved or opened, this simply doesn't start
    /// a crossfade — the active track keeps playing and will eventually
    /// finish naturally, falling back to `handleTrackFinished`'s hard-cut
    /// advance instead of a blend for this one transition.
    private func beginCrossfade() {
        let outgoing = queue[currentIndex]
        let next = queue[currentIndex + 1]
        guard let url = resolveFileURL(trackPersistentID: next.trackPersistentID) else { return }

        do {
            let file = try AVAudioFile(forReading: url)

            playbackGeneration += 1
            let generation = playbackGeneration

            let chain = standbyChain
            chain.player.volume = 0
            pendingIncomingDurationSec = playableDuration(file: file, fromSec: next.playableStartSec)
            schedule(file: file, on: chain, playableStartSec: next.playableStartSec, generation: generation)

            // The blend's length is the *outgoing* track's own tempo-derived
            // duration (per `MixBuilder.crossfadeTiming`, mirroring Python's
            // `build_mix`, which sizes each crossfade off the track that's
            // fading out) — not a fixed constant. `max(0.5, ...)` guards
            // against a degenerate/zero value ever causing a division blow-up
            // in `advanceCrossfade`'s `tickIntervalSec / activeCrossfadeDurationSec`.
            activeCrossfadeDurationSec = max(0.5, outgoing.crossfadeDurationSec)
            crossfadeProgress = 0
            isCrossfading = true
        } catch {
            // Leave everything as-is -- the active track keeps playing
            // uninterrupted and will hit its own natural completion later.
        }
    }

    /// Advances the blend by one tick using the same equal-power (sqrt)
    /// curve `playlist_mixer.py`'s `equal_power_crossfade` already
    /// validated in Phase 1: outgoing volume follows `sqrt(1 - t)`,
    /// incoming follows `sqrt(t)` — their squares always sum to 1, which is
    /// what avoids the audible loudness dip a linear fade produces at the
    /// midpoint.
    private func advanceCrossfade() {
        crossfadeProgress = min(1, crossfadeProgress + tickIntervalSec / activeCrossfadeDurationSec)
        let t = crossfadeProgress
        activeChain.player.volume = Float(sqrt(1 - t))
        standbyChain.player.volume = Float(sqrt(t))

        if crossfadeProgress >= 1 {
            completeCrossfade()
        }
    }

    /// Stops the outgoing chain (now faded to silence) and swaps roles so
    /// the chain that was standby is active going forward. Captured as
    /// local `let`s before `activeIsA` flips so there's no ambiguity about
    /// which chain is "old" vs "new" mid-swap.
    private func completeCrossfade() {
        let outgoing = activeChain
        let incoming = standbyChain

        outgoing.player.stop()
        outgoing.player.volume = 1
        incoming.player.volume = 1

        activeIsA.toggle()
        currentIndex += 1
        nowPlayingTrackID = queue[currentIndex].trackPersistentID
        currentTrackDurationSec = pendingIncomingDurationSec
        // The newly-active chain's segment started at its own playable
        // beginning (0), not a seeked position -- `elapsedSeconds` will
        // naturally read as the real seconds elapsed since `beginCrossfade`
        // scheduled it, via the render clock `tick()` already reads.
        elapsedBaseSec = 0
        updateNextTrackID()
        isCrossfading = false
        crossfadeProgress = 0
    }

    /// Stops playback outright and clears all session state — a stopped
    /// session doesn't resume from where it left off, it starts over from a
    /// fresh `play(queue:)` call. Bumps `playbackGeneration` so any
    /// in-flight completion handler on either chain is correctly ignored as
    /// stale rather than triggering an unwanted advance.
    func stop() {
        stopTimer()
        playbackGeneration += 1

        chainA.player.stop()
        chainB.player.stop()
        chainA.player.volume = 1
        chainB.player.volume = 1

        activeIsA = true
        isCrossfading = false
        crossfadeProgress = 0
        queue = []
        currentIndex = 0
        isPlaying = false
        isPaused = false
        nowPlayingTrackID = nil
        nextTrackPersistentID = nil
        currentPlaylistID = nil
        elapsedSeconds = 0
        elapsedBaseSec = 0
        currentTrackDurationSec = 0
    }

    // MARK: - Transport

    /// Pauses playback in place — both chains if a crossfade is currently in
    /// progress, so the blend doesn't silently keep advancing while
    /// "paused." `AVAudioPlayerNode.pause()` natively preserves the node's
    /// scheduled-buffer read position, so `resume()` continues from exactly
    /// where this left off with no extra bookkeeping needed.
    func pause() {
        guard isPlaying, !isPaused else { return }
        activeChain.player.pause()
        if isCrossfading {
            standbyChain.player.pause()
        }
        isPaused = true
        stopTimer()
    }

    /// Resumes a paused session. See `pause()`.
    func resume() {
        guard isPlaying, isPaused else { return }
        activeChain.player.play()
        if isCrossfading {
            standbyChain.player.play()
        }
        isPaused = false
        startTimerIfNeeded()
    }

    /// Jumps to `targetSeconds` within the current track's playable content
    /// (0 = the track's own playable start, matching what `elapsedSeconds`/
    /// the progress bar already display — not raw frame 0 of the file).
    /// Cancels any in-progress crossfade first (`cancelCrossfadeIfNeeded`) —
    /// seeking mid-blend is rare enough that landing back in a clean,
    /// single-chain state at the new position is a reasonable simplification
    /// over trying to preserve an arbitrary jump's effect on an active blend.
    /// Seeking past a transition's `crossfadeStartOffsetSec` correctly
    /// triggers that crossfade on the very next tick, same as reaching it
    /// through normal playback — this is what makes it possible to actually
    /// test a transition without waiting out a whole track.
    func seek(toSeconds targetSeconds: Double) {
        guard isPlaying, queue.indices.contains(currentIndex) else { return }
        cancelCrossfadeIfNeeded()

        let queuedTrack = queue[currentIndex]
        guard let url = resolveFileURL(trackPersistentID: queuedTrack.trackPersistentID) else { return }

        do {
            let file = try AVAudioFile(forReading: url)
            playbackGeneration += 1
            let generation = playbackGeneration

            let clamped = max(0, min(targetSeconds, currentTrackDurationSec))
            let chain = activeChain
            chain.player.volume = 1
            elapsedBaseSec = clamped
            schedule(file: file, on: chain, playableStartSec: queuedTrack.playableStartSec + clamped, generation: generation)
            elapsedSeconds = clamped
            if isPaused {
                // `schedule(...)` always calls `.play()` internally --
                // immediately re-pausing lands back in the paused state at
                // the new position rather than audibly resuming.
                chain.player.pause()
            }
        } catch {
            playbackError = "Couldn't seek: \(error.localizedDescription)"
        }
    }

    /// Skips to the next track in the queue, or stops cleanly if this was
    /// the last one — same end-of-queue handling `handleTrackFinished`
    /// already uses for a track that finishes naturally.
    func skipToNext() {
        guard isPlaying else { return }
        cancelCrossfadeIfNeeded()
        currentIndex += 1
        playTrackAtCurrentIndex()
    }

    /// Skips to the previous track, or restarts the current one from its
    /// own beginning if already more than a few seconds into it — the
    /// standard media-player convention (an early tap goes back a track, a
    /// later one just restarts what's playing).
    func skipToPrevious() {
        guard isPlaying else { return }
        cancelCrossfadeIfNeeded()
        if elapsedSeconds <= 3, currentIndex > 0 {
            currentIndex -= 1
        }
        playTrackAtCurrentIndex()
    }

    /// Shared by `seek`/`skipToNext`/`skipToPrevious` — silences and stops
    /// the standby chain and resets crossfade state if a blend was in
    /// progress, so a manual jump always lands in a clean, single-chain
    /// state instead of leaving a second chain audible underneath it.
    private func cancelCrossfadeIfNeeded() {
        guard isCrossfading else { return }
        standbyChain.player.stop()
        standbyChain.player.volume = 1
        activeChain.player.volume = 1
        isCrossfading = false
        crossfadeProgress = 0
    }
}
