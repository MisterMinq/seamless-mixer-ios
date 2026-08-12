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
@MainActor
final class PlaybackEngine: ObservableObject {
    /// One entry in a playback queue — everything `PlaybackEngine` needs to
    /// know about a track to play it and, if there's another track after
    /// it, to blend into that next one at the right moment.
    struct QueuedTrack {
        let trackPersistentID: Int64
        /// Seconds into *this* track when the blend into the next one
        /// should begin. Meaningless for the last track in a queue (there's
        /// nothing to blend into) — `play(trackPersistentID:)`'s
        /// single-track convenience passes `.infinity` here specifically so
        /// `checkCrossfadeTrigger`'s `isFinite` guard never fires for it.
        let crossfadeStartOffsetSec: Double
    }

    @Published private(set) var isPlaying = false
    @Published var playbackError: String?
    /// The persistent ID of the track currently active (audible), or `nil`
    /// when stopped. During a crossfade this still reports the *outgoing*
    /// track until the swap completes — the incoming track becomes
    /// "now playing" only once it's the sole audible one, matching how a
    /// listener would describe what's playing mid-blend.
    @Published private(set) var nowPlayingTrackID: Int64?
    /// The track right after `nowPlayingTrackID` in the queue, or `nil` if
    /// there isn't one — what Now Playing's "blending into next" indicator
    /// reads from. Kept in sync alongside `nowPlayingTrackID` rather than
    /// computed on demand by a view, since only this class actually knows
    /// `currentIndex`/`queue`.
    @Published private(set) var nextTrackPersistentID: Int64?
    /// Elapsed seconds into the currently active track, refreshed every
    /// timer tick from the active chain's own render clock (see
    /// `computeElapsedSeconds(for:)`) — not manually accumulated, so it
    /// stays correct across pauses/seeks this class doesn't even support
    /// yet.
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
    /// Length of the actual blend window. Not yet derived from anything
    /// track-specific (e.g. tempo, per the confirmed design's "sized to a
    /// few beats at the current tempo") — a fixed, reasonable value for
    /// this first crossfade slice, same "smallest safe slice" spirit as
    /// everything else in this file's history. Revisit once real-device
    /// listening feedback exists to tune against.
    private let crossfadeDurationSec: Double = 4.0

    private var timer: Timer?
    private let tickIntervalSec: Double = 0.1

    /// The next (incoming) track's duration, computed and stashed the
    /// moment `beginCrossfade` schedules it, then applied to
    /// `currentTrackDurationSec` once `completeCrossfade` makes it the
    /// active track — the file's already open and decoded by then, no
    /// reason to look it up twice.
    private var pendingIncomingDurationSec: Double = 0

    init() {
        configureGraph()
    }

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
    /// entry's `crossfadeStartOffsetSec` where there's a next track to
    /// blend into. Resets both chains to a clean, full-volume state first —
    /// a previous session may have left a chain mid-fade if `stop()` wasn't
    /// called (shouldn't happen given how `PlaylistDetailView` drives this,
    /// but cheap to guarantee here rather than assume).
    func play(queue: [QueuedTrack], startIndex: Int = 0) {
        self.queue = queue
        self.currentIndex = startIndex
        activeIsA = true
        isCrossfading = false
        crossfadeProgress = 0
        chainA.player.volume = 1
        chainB.player.volume = 1

        playTrackAtCurrentIndex()
        startTimerIfNeeded()
    }

    /// Convenience for the single-track case — equivalent to
    /// `play(queue: [QueuedTrack(trackPersistentID:, crossfadeStartOffsetSec: .infinity)])`.
    /// Kept as its own entry point since "play just this one track" is
    /// still a meaningful, simpler action distinct from "play the whole
    /// set."
    func play(trackPersistentID: Int64) {
        play(queue: [QueuedTrack(trackPersistentID: trackPersistentID, crossfadeStartOffsetSec: .infinity)])
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

        let trackPersistentID = queue[currentIndex].trackPersistentID
        playbackError = nil

        guard let url = resolveFileURL(trackPersistentID: trackPersistentID) else {
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
            chain.player.stop()
            chain.player.volume = 1
            chain.player.scheduleFile(file, at: nil) { [weak self] in
                // Fires on an internal AVAudioEngine thread -- hop back to
                // the main actor before touching any `@Published`/isolated
                // state, same discipline `MixBuilder`'s GRDB `await`s
                // already established.
                Task { @MainActor in
                    self?.handleTrackFinished(generation: generation)
                }
            }
            chain.player.play()
            isPlaying = true
            nowPlayingTrackID = trackPersistentID
            currentTrackDurationSec = Double(file.length) / file.fileFormat.sampleRate
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
        guard isPlaying else { return }
        if let elapsed = computeElapsedSeconds(for: activeChain.player) {
            elapsedSeconds = elapsed
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
    /// queue to blend into.
    private func checkCrossfadeTrigger() {
        guard queue.indices.contains(currentIndex), currentIndex + 1 < queue.count else { return }
        let offset = queue[currentIndex].crossfadeStartOffsetSec
        guard offset.isFinite, offset > 0 else { return }
        guard let elapsed = computeElapsedSeconds(for: activeChain.player), elapsed >= offset else { return }
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
        let next = queue[currentIndex + 1]
        guard let url = resolveFileURL(trackPersistentID: next.trackPersistentID) else { return }

        do {
            let file = try AVAudioFile(forReading: url)
            pendingIncomingDurationSec = Double(file.length) / file.fileFormat.sampleRate

            playbackGeneration += 1
            let generation = playbackGeneration

            let chain = standbyChain
            chain.player.stop()
            chain.player.volume = 0
            chain.player.scheduleFile(file, at: nil) { [weak self] in
                Task { @MainActor in
                    self?.handleTrackFinished(generation: generation)
                }
            }
            chain.player.play()

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
        crossfadeProgress = min(1, crossfadeProgress + tickIntervalSec / crossfadeDurationSec)
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
        nowPlayingTrackID = nil
        nextTrackPersistentID = nil
        elapsedSeconds = 0
        currentTrackDurationSec = 0
    }
}
