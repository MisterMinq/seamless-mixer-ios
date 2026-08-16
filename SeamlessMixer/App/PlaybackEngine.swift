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
    /// The name of the audio route currently in use (e.g. "iPhone
    /// Speaker", "Fosi Audio BT30D", "AirPods Pro") — per the confirmed
    /// Now Playing design ("show the connected Bluetooth device," per the
    /// real Apple Music reference screenshots) and directly relevant to
    /// this app's own core scenario (playing into a speaker/amp at an
    /// event). **Added 2026-08-15** alongside the route-change fix below —
    /// this class already observes route changes for that bug, so it's
    /// also the natural, single place to track this rather than a
    /// duplicate observer elsewhere. Refreshed at `init` (so it's correct
    /// before any route change ever fires) and on every subsequent route
    /// change, whether or not that change disrupted playback.
    @Published private(set) var outputRouteName: String = "This iPhone"

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

    /// True while a `resume()` call is already in flight — see `resume()`'s
    /// own doc comment. Prevents a second, overlapping trigger (interruption
    /// ending and a route change firing close together for the same
    /// real-world event) from racing a second `AVAudioSession.setActive(true)`/
    /// `engine.start()` attempt against the first.
    private var isResuming = false

    init() {
        configureGraph()
        observeInterruptions()
        observeRouteChanges()
        observeEngineConfigurationChanges()
        updateOutputRouteName()
        setupRemoteCommands()
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
    /// `resume()` itself now handles reactivating the session and, if
    /// needed, restarting the engine (fixed 2026-08-14 — see its own doc
    /// comment) -- no separate `activateSession()` call needed here anymore.
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
            resume()

        @unknown default:
            break
        }
    }

    /// **Added 2026-08-15, a real, separate gap from interruptions —
    /// confirmed on a real device switching output between the phone
    /// speaker, AirPods, and a Bluetooth speaker/amp mid-playback** (the
    /// app's own core scenario). Route changes fire a *different*
    /// notification than interruptions (`routeChangeNotification`, not
    /// `interruptionNotification`) and were never observed at all before
    /// this — the symptom looked identical either way (bars animating, Play
    /// button showing "playing," progress frozen, no sound), because the
    /// underlying cause is the same: the OS can silently stop the engine
    /// out from under this app when the active audio route changes, same as
    /// it can during an interruption.
    ///
    /// **Three separate auto-recovery attempts (removing the `!engine
    /// .isRunning` gate, then forcing a hard engine restart) all failed to
    /// reliably restore real audio — Andy's explicit call, 2026-08-16, after
    /// the third: "If I do the same thing with Apple Music, it stops
    /// playing. Period! So maybe we should just let it stop playing if
    /// there is no other solution available."** That led to always calling
    /// `stop()` on any route change.
    ///
    /// **Corrected, same day, after Andy tested Apple Music's actual
    /// behavior more carefully and found the original assumption was
    /// wrong.** Apple Music does *not* stop on an ordinary route change —
    /// switching between AirPods and a Bluetooth speaker while both stay
    /// connected, or connecting a new device while playing on the phone
    /// speaker, continues seamlessly with no gap. It only stops outright
    /// when the *currently active* device is genuinely disconnected
    /// (powered off, out of Bluetooth range, unplugged) — which makes
    /// sense, since there's nowhere left to send the audio. `AVAudioSession`
    /// reports *why* a route changed via `AVAudioSessionRouteChangeReasonKey`
    /// in the notification's `userInfo`, so this now branches on that reason
    /// instead of treating every route change the same: `.oldDeviceUnavailable`
    /// (the disconnect case) still calls `stop()`, honestly matching what
    /// even Apple Music does there; every other reason attempts the same
    /// silent `pause()`/`resume()` recovery `handleEngineConfigurationChange`
    /// already uses, since the engine's render graph can still get quietly
    /// disrupted by a route change that doesn't represent a real device
    /// disappearing.
    private func observeRouteChanges() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            Task { @MainActor in
                self?.updateOutputRouteName()
                self?.handleRouteChange(notification: notification)
            }
        }
    }

    private func handleRouteChange(notification: Notification) {
        guard isPlaying, !isPaused else { return }
        let reasonValue = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) ?? .unknown

        if reason == .oldDeviceUnavailable {
            stop()
        } else {
            pause()
            resume()
        }
    }

    /// **Added 2026-08-16, from web research done while digging into why
    /// interruption-triggered resume regressed** (see `resume()`'s own doc
    /// comment) — a third, previously-unobserved notification, distinct
    /// from both `AVAudioSession.interruptionNotification` and
    /// `.routeChangeNotification`. Per Apple's documentation and multiple
    /// independent developer write-ups: when `AVAudioEngine`'s I/O unit
    /// detects a change to the hardware's channel count or sample rate, the
    /// engine stops and uninitializes *itself*, silently, and posts this
    /// notification — described as "a side effect of events like
    /// interruption and route change" (i.e. it can fire *in addition to*
    /// those two, not instead of them, and can arrive slightly *after* an
    /// interruption's own `.ended` has already been handled). This lines up
    /// exactly with Andy's "spark of trying to resume but then stops"
    /// description: our own interruption recovery could genuinely succeed
    /// for a moment, only for this separate, never-observed notification to
    /// silently stop the engine again immediately after, with nothing in
    /// this class listening for it before now.
    ///
    /// Deliberately routed through the *same* verified `pause()`/`resume()`
    /// path interruptions already use (not `handleRouteChange`'s "just
    /// stop" outcome) — this notification is a precise, well-documented
    /// "the engine specifically needs restarting" signal, not the vaguer
    /// "something about the route changed" signal a plain route change is;
    /// recovering here is far more likely to actually succeed than the
    /// route-change case Andy already decided wasn't worth chasing further.
    private func observeEngineConfigurationChanges() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleEngineConfigurationChange()
            }
        }
    }

    private func handleEngineConfigurationChange() {
        guard isPlaying, !isPaused else { return }
        pause()
        resume()
    }

    /// Reads the current output route straight off `AVAudioSession` — the
    /// same source of truth iOS itself uses, so this always matches what
    /// Control Center shows, no separate Bluetooth/AirPlay handling needed
    /// (per the confirmed design: "iOS routes audio to a connected
    /// Bluetooth speaker/amp automatically... the app just needs proper
    /// `AVAudioSession` configuration"). `.first` mirrors what a listener
    /// actually perceives as "the output" — multi-output routes are rare
    /// and not worth a more elaborate display for a first slice.
    private func updateOutputRouteName() {
        outputRouteName = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "This iPhone"
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
            clearNowPlayingInfo()
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
            clearNowPlayingInfo()
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
            refreshNowPlayingMetadata()
        } catch {
            playbackError = "Couldn't play this track: \(error.localizedDescription)"
            isPlaying = false
            nowPlayingTrackID = nil
            nextTrackPersistentID = nil
            stopTimer()
            clearNowPlayingInfo()
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
        refreshNowPlayingMetadata()
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
        clearNowPlayingInfo()
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
        publishNowPlayingPlaybackState()
    }

    /// Resumes a paused session. See `pause()`.
    ///
    /// **Fixed 2026-08-14, after real-device testing found interruption
    /// recovery (below) still silent — animated "now playing" indicators
    /// active, no audio — even though `handleInterruption`'s `.ended` case
    /// was calling this correctly.** Root cause: this never checked
    /// `engine.isRunning`, unlike `playTrackAtCurrentIndex()` just below.
    /// A system interruption (a Timer/Alarm ringing, another app seizing the
    /// session) can stop the underlying `AVAudioEngine` itself, not just
    /// this app's player nodes — calling `.play()` on a player node attached
    /// to a *stopped* engine doesn't throw, it just silently produces no
    /// audio, so `isPaused` flipped to `false` (bars animating, transport
    /// showing "playing") while nothing was actually rendering. Now
    /// reactivates the session and restarts the engine first, matching
    /// `playTrackAtCurrentIndex()`'s own guard exactly; if either step
    /// fails, `isPaused` deliberately stays `true` and `playbackError` is
    /// set, so the UI honestly reports "still paused" rather than claiming
    /// to be playing when it isn't.
    ///
    /// **Retry added 2026-08-15** — that honest-failure path did its job
    /// (the error genuinely showed up on screen: "Couldn't resume playback:
    /// Session activation fail...") but real-device testing found a real
    /// trigger for it: resuming right after a Reminders-app alert (as
    /// opposed to a Clock alarm, already confirmed working) failed outright,
    /// with no further recovery — the Play button just stayed paused
    /// forever. `AVAudioSession.setActive(true)` can genuinely fail on the
    /// very first attempt if another app's own alert sound hasn't fully
    /// released the session yet by the moment `.ended` fires — a documented
    /// race, not a sign of a deeper bug — so a brief retry with backoff is
    /// the standard fix, not a workaround. `activateSessionWithRetry` does
    /// that; this function now hands off to it via a `Task` rather than
    /// activating synchronously, so those retries don't block the main
    /// actor.
    ///
    /// **Re-entrancy guard added 2026-08-15, same day** — real-device
    /// testing found the *retried* version still failing with the identical
    /// error on the very next round, which pointed at a second, separate
    /// cause rather than the retry window just being too short: an
    /// interruption ending and a route change can plausibly fire close
    /// together for the same real-world event (e.g. a Reminders alert can
    /// itself trigger a brief route change), and both `handleInterruption`'s
    /// `.ended` case and `handleRouteChange` call `resume()` independently —
    /// nothing stopped two overlapping `resume()` calls from both passing
    /// the `isPaused` guard and racing each other into
    /// `AVAudioSession.setActive(true)`/`engine.start()` at the same time,
    /// which is exactly the kind of call Apple's own docs warn is not
    /// reentrant-safe. `isResuming` now makes a second concurrent call a
    /// no-op instead of a second racing attempt. Also widened the retry
    /// budget itself (3 attempts/300ms → 5 attempts/500ms, ~2s total) in
    /// case a Reminders alert's own sound genuinely takes longer to release
    /// the session than a Clock alarm's, and the displayed error now
    /// includes the raw `NSError` code so a future recurrence can be
    /// diagnosed from Andy's screenshot alone, without needing Xcode.
    ///
    /// **`forceEngineRestart` (added 2026-08-15) removed again 2026-08-16**
    /// — the route change path that was its only caller now calls `stop()`
    /// instead of attempting recovery at all (per this class's own
    /// `handleRouteChange` doc comment, Andy's explicit call after three
    /// failed route-change recovery attempts). Its actual mechanism — an
    /// unconditional `engine.stop()` before restarting, rather than trusting
    /// `engine.isRunning` — wasn't wasted, though: it's now used internally
    /// by the verification retry below, on the pass where a first "success"
    /// turned out to be false.
    ///
    /// **Deep-dive investigation, 2026-08-16 — real regression, not the same
    /// bug reappearing.** Andy: "it worked before with the alarm so what
    /// changed? Go deep to look for it." Traced every change to this
    /// specific interruption-driven path since the version confirmed
    /// working twice with a real Clock alarm (see the "Retry added" note
    /// above — that's the version that worked). What's different since:
    /// `resume()` became `async` (spawns a `Task` and returns immediately,
    /// rather than completing synchronously within the notification
    /// handler), and — the real suspect — a retry loop was added that
    /// treats `activateSession()`/`engine.start()` *not throwing* as proof
    /// the resume succeeded. That's a false-positive risk specifically
    /// right after an interruption: those calls can return successfully
    /// while the underlying hardware pipeline hasn't actually stabilized
    /// yet (the interruption's own teardown on iOS's side may not be fully
    /// complete the instant `.ended` fires, even though the API contract
    /// doesn't surface that as an error) — matching exactly what Andy
    /// described: "There is a spark as if it wants to resume but then
    /// stops. Animation and everything shows playback." A spark of real
    /// audio is consistent with a genuine-but-unstable start, immediately
    /// undone by the still-settling interruption teardown, while our code
    /// had already marked `isPaused = false` on the strength of the API
    /// calls alone, with nothing verifying playback actually kept going.
    /// The original synchronous, no-retry version this project confirmed
    /// working never faced this specific failure mode, because there was
    /// only ever one attempt, made once genuinely safe to try (iOS's
    /// `.ended`/`shouldResume` signal itself, unmodified since) — the retry
    /// loop is what introduced the possibility of trusting a premature
    /// success.
    ///
    /// **Fixed**: `resume()` no longer marks itself successful just because
    /// `activateSessionWithRetry` didn't throw. It calls `.play()`, waits a
    /// brief moment, then checks whether the active chain's render clock
    /// (`computeElapsedSeconds`) is actually advancing and the engine is
    /// genuinely running — only then does it mark the session resumed. If
    /// that check fails, it retries once more, this time forcing a hard
    /// engine restart (the same mechanism `forceEngineRestart` used to
    /// expose publicly) rather than trusting `engine.isRunning`. Only after
    /// both passes fail does it report an honest error. **Known, flagged
    /// limitation**: the render clock advancing confirms the engine is
    /// genuinely rendering samples, which is the strongest signal available
    /// without private APIs — it is not an absolute guarantee sound is
    /// reaching the physical output, so this narrows the false-positive gap
    /// significantly without claiming to close it completely.
    func resume() {
        guard isPlaying, isPaused, !isResuming else { return }
        isResuming = true
        Task { @MainActor in
            defer { isResuming = false }
            guard await attemptResumeWithVerification() else { return }
            isPaused = false
            startTimerIfNeeded()
            publishNowPlayingPlaybackState()
        }
    }

    /// Two passes: the first trusts the cheaper conditional engine restart
    /// (already confirmed reliable for the ordinary case); if verification
    /// shows nothing actually started rendering, the second pass forces a
    /// hard engine restart instead — see `resume()`'s own doc comment for
    /// the full reasoning behind both the verification step and the
    /// two-pass structure.
    ///
    /// **Fixed 2026-08-17 — the verification itself was checking the wrong
    /// thing.** Andy: "The spark that stops is there again" — the exact
    /// "spark then silently stops" failure this verification step was
    /// built to catch, recurring even with it in place. Root cause:
    /// despite this function's own doc comment claiming to check whether
    /// the render clock is "actually advancing," the code only ever did
    /// `computeElapsedSeconds(for:) != nil` — a single point-in-time read.
    /// `AVAudioPlayerNode.lastRenderTime` stays non-nil and "valid" even
    /// after the engine has silently stalled; it just stops *updating*, it
    /// doesn't revert to nil. So the exact failure mode this was meant to
    /// catch — the engine genuinely starts for a moment (the "spark"),
    /// then a still-settling interruption teardown kills it again — could
    /// land its 400ms check right inside that brief real-rendering window,
    /// see a valid (but about-to-freeze) timestamp, and wrongly declare
    /// success. A single reading can never distinguish "playing" from
    /// "frozen at a real-looking value" — only two readings, compared, can.
    /// Now takes a second reading 300ms after the first and requires the
    /// render clock to have actually moved forward by a real amount
    /// between them before trusting the resume.
    ///
    /// **Revised 2026-08-17, same day — the two-reading check alone still
    /// wasn't enough.** Andy re-tested and reported the identical "spark
    /// then no sound" symptom, but with one new, decisive detail: no red
    /// error text appeared, meaning the two-reading check *did* pass — the
    /// render clock genuinely was advancing — and playback was still
    /// silent, with the progress bar/time display continuing to move.
    /// That's real evidence of a structural limit this function's own
    /// doc comment already flagged: a genuinely advancing render clock
    /// proves the *engine's internal graph* is processing samples, not
    /// that those samples are actually reaching the physical output. A
    /// bare `activeChain.player.play()` resumes an already-scheduled node
    /// exactly where it left off — fine for an ordinary manual pause/
    /// resume — but after a real interruption teardown, the underlying
    /// hardware route can apparently come back in a state where the
    /// engine's internal clock keeps ticking while the actual output path
    /// doesn't. There's no public API available to confirm audible output
    /// directly, so detecting this more precisely isn't possible — but
    /// this project already has real, empirical proof of what reliably
    /// fixes it: skipping to the next track (which fully reschedules via
    /// `schedule(file:on:playableStartSec:generation:)`, not a bare
    /// `.play()`) was the one thing Andy found by hand that consistently
    /// restored real sound after this exact kind of stall (see the Round 5
    /// tracker note this project already recorded). Pass 2 now does that
    /// same full reschedule — tearing down and rebuilding the node's
    /// buffer at the current elapsed position — instead of just forcing
    /// the engine to restart around the same, possibly still-broken
    /// schedule.
    private func attemptResumeWithVerification() async -> Bool {
        for pass in 1...2 {
            guard await activateSessionWithRetry(forceRestart: pass > 1) else { return false }
            if pass == 1 {
                activeChain.player.play()
                if isCrossfading {
                    standbyChain.player.play()
                }
            } else {
                rescheduleActiveTrack()
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let first = computeElapsedSeconds(for: activeChain.player), engine.isRunning else { continue }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let second = computeElapsedSeconds(for: activeChain.player), engine.isRunning else { continue }
            // A genuinely playing render clock advances roughly in real
            // time between the two reads; a stalled one reports the same
            // (or a non-increasing) value despite `lastRenderTime` itself
            // staying "valid" -- this comparison is what actually proves
            // advancement, which a single reading structurally cannot.
            // **Known, still-flagged limitation**: this proves the engine
            // is processing samples, not that they reach real output --
            // see this function's own 2026-08-17 revision note above.
            if second > first + 0.05 {
                return true
            }
        }
        playbackError = "Couldn't resume playback: audio didn't actually start."
        return false
    }

    /// Full reschedule of whatever's on `activeChain` right now, at its
    /// current elapsed position — the same mechanism `seek(toSeconds:)`
    /// already uses (`schedule(...)` itself calls `player.stop()` before
    /// scheduling a fresh segment, tearing down and rebuilding the node's
    /// buffer, not just resuming an existing one). Used by
    /// `attemptResumeWithVerification`'s second pass — see that function's
    /// own 2026-08-17 doc comment for why a full reschedule, not just a
    /// forced engine restart, is what this project's own real-device
    /// testing already found actually restores audible sound.
    private func rescheduleActiveTrack() {
        guard queue.indices.contains(currentIndex) else { return }
        cancelCrossfadeIfNeeded()
        let queuedTrack = queue[currentIndex]
        guard let url = resolveFileURL(trackPersistentID: queuedTrack.trackPersistentID),
              let file = try? AVAudioFile(forReading: url) else { return }
        playbackGeneration += 1
        let generation = playbackGeneration
        let resumeAtSec = elapsedSeconds
        activeChain.player.volume = 1
        elapsedBaseSec = resumeAtSec
        schedule(file: file, on: activeChain, playableStartSec: queuedTrack.playableStartSec + resumeAtSec, generation: generation)
    }

    /// Attempts `activateSession()` + an engine restart up to `attempts`
    /// times, waiting `delayNs` between tries — see `resume()`'s own doc
    /// comment for why this exists, and for `forceRestart`'s own reasoning.
    /// Sets `playbackError` only once, after the final attempt fails, so a
    /// transient first-try failure that the retry recovers from never
    /// flashes an error the user didn't need to see.
    private func activateSessionWithRetry(attempts: Int = 5, delayNs: UInt64 = 500_000_000, forceRestart: Bool = false) async -> Bool {
        for attempt in 1...attempts {
            do {
                try activateSession()
                if forceRestart {
                    engine.stop()
                }
                if !engine.isRunning {
                    try engine.start()
                }
                return true
            } catch {
                if attempt == attempts {
                    let code = (error as NSError).code
                    playbackError = "Couldn't resume playback: \(error.localizedDescription) (code \(code))"
                    return false
                }
                try? await Task.sleep(nanoseconds: delayNs)
            }
        }
        return false
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
            publishNowPlayingPlaybackState()
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

    // MARK: - Lock screen / Control Center integration

    /// **Added 2026-08-16** — a real, previously-tracked gap (no lock-screen/
    /// Control Center "Now Playing" widget existed at all), picked up
    /// specifically because it's also the leading fix candidate for the
    /// background-interruption-resume bug (see `resume()`'s own doc
    /// comment): real-device investigation found this app's resume only
    /// fails when it's backgrounded at the moment an interruption ends, and
    /// Apple's own developer support confirms that starting/resuming audio
    /// from the background is restricted for apps that haven't registered
    /// as the system's current media player. Apple Music — a fully
    /// exclusive (non-mixable) app, same as this one — reliably resumes in
    /// the identical scenario, which only makes sense if that registration
    /// (not a mixable audio session) is the real missing piece. This is the
    /// buildable half of that: `MPNowPlayingInfoCenter` publishes what's
    /// playing, `MPRemoteCommandCenter` accepts lock-screen/Control-Center/
    /// AirPods/CarPlay transport commands. Whether it actually closes the
    /// background-resume gap is unconfirmed until tested on a real device —
    /// flagged honestly, not claimed as a guaranteed fix.
    private var nowPlayingMetadata: [String: Any] = [:]

    /// Re-queries the current track's title/artist/artwork and republishes
    /// the full now-playing info — called whenever `nowPlayingTrackID`
    /// changes (a fresh track, a crossfade completing). Same synchronous
    /// single-item `MPMediaQuery` lookup pattern `resolveFileURL`/
    /// `NowPlayingView.loadArtwork` already use elsewhere in this app —
    /// cheap enough not to need a detached `Task`.
    private func refreshNowPlayingMetadata() {
        guard let trackID = nowPlayingTrackID else {
            clearNowPlayingInfo()
            return
        }
        let query = MPMediaQuery.songs()
        let mediaID = UInt64(bitPattern: trackID)
        query.addFilterPredicate(MPMediaPropertyPredicate(value: mediaID, forProperty: MPMediaItemPropertyPersistentID))
        guard let item = query.items?.first else {
            nowPlayingMetadata = [:]
            publishNowPlayingPlaybackState()
            return
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item.title
        info[MPMediaItemPropertyArtist] = item.artist
        if let artwork = item.artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        nowPlayingMetadata = info
        publishNowPlayingPlaybackState()
    }

    /// Republishes the full now-playing dictionary (cached metadata plus
    /// live playback rate/elapsed time/duration) — called on every discrete
    /// playback-state change (play, pause, resume, seek). Deliberately
    /// *not* called on every `tick()` — the system interpolates displayed
    /// elapsed time from `MPNowPlayingInfoPropertyElapsedPlaybackTime` plus
    /// `MPNowPlayingInfoPropertyPlaybackRate` on its own, so republishing at
    /// 10Hz would just be redundant, wasted work, not a way to keep it more
    /// in sync.
    private func publishNowPlayingPlaybackState() {
        guard !nowPlayingMetadata.isEmpty else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info = nowPlayingMetadata
        info[MPMediaItemPropertyPlaybackDuration] = currentTrackDurationSec
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = (isPlaying && !isPaused) ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        nowPlayingMetadata = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Registered once, in `init`. `MainActor.assumeIsolated` bridges
    /// `MPRemoteCommandCenter`'s synchronous, non-actor-isolated handler
    /// closures into this `@MainActor` class's isolated methods — safe
    /// because Apple's own documented behavior is that these handlers are
    /// always invoked on the main thread, the same discipline this file's
    /// `NotificationCenter` observers hop to explicitly via `Task { @MainActor
    /// in }`; a remote-command handler has to return its status
    /// synchronously, so that `Task`-hop pattern doesn't fit here the same
    /// way.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.isPaused ? self.resume() : self.pause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.skipToNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.skipToPrevious() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self.seek(toSeconds: event.positionTime) }
            return .success
        }
    }
}
