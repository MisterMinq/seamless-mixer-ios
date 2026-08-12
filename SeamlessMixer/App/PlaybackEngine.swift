import AVFoundation
import MediaPlayer

/// First real slice of the AVAudioEngine mixing engine, per CLAUDE.md's
/// "Mixing Engine — AVAudioEngine Design" (first-pass design, confirmed
/// back when Phase 2 architecture work happened, but never implemented
/// until now — every screen through Playlist Detail exists, but nothing
/// could actually *play* a saved recipe before this).
///
/// Builds the full two-player-node graph the confirmed design calls for —
/// current/next `AVAudioPlayerNode`s, each through its own
/// `AVAudioUnitTimePitch`, into one shared mixer (the engine's own
/// `mainMixerNode` stands in for the design's "shared AVAudioMixerNode" —
/// no need for a separate explicit mixer node when the engine already
/// provides one) — but this slice only *uses* the "current" side: tracks
/// play back-to-back, start to finish, in playlist order, with no
/// crossfade/blending between them. That's one small step up from the
/// previous slice (single-track playback only) and deliberately still not
/// the whole design — the same "smallest safe slice first" approach used
/// for every other big piece of this app (Genres before the other 3
/// category pickers, remove-track before reorder, genre-only Build Mix
/// before all four source types, single-track playback before this).
/// The equal-power crossfade and pre-buffering timed to
/// `crossfade_start_offset_sec` are the next slice — `nextPlayer`/
/// `nextTimePitch` are wired into the graph now specifically so that
/// follow-up work doesn't need to redo graph setup, even though nothing
/// schedules audio on them yet.
///
/// **Highest-risk file in the app target right now — first use of
/// AVAudioEngine/AVAudioSession/AVAudioFile anywhere in this codebase.**
/// Compiles against the real AVFoundation SDK but is otherwise entirely
/// unverified: neither this environment nor Codemagic's Simulator build
/// has a real, populated media library or a way to actually listen to real
/// audio output. Needs a real-device check before this is trusted — same
/// category of gap as everything else `MediaPlayer`-touching in this app,
/// just with real-time audio playback layered on top, which is a
/// meaningfully bigger unknown than a database write or a compile check.
@MainActor
final class PlaybackEngine: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var playbackError: String?
    /// The persistent ID of the track currently scheduled/playing on
    /// `currentPlayer`, or `nil` when stopped. Exposed so a screen can show
    /// "now playing" state without needing its own separate bookkeeping of
    /// where the queue is — `PlaylistDetailView` uses this to highlight the
    /// active row.
    @Published private(set) var nowPlayingTrackID: Int64?

    private let engine = AVAudioEngine()
    private let currentPlayer = AVAudioPlayerNode()
    private let currentTimePitch = AVAudioUnitTimePitch()
    // Attached/connected now, unused this slice either — see this file's
    // own doc comment. Still reserved for the crossfade slice, not
    // repurposed for sequential advance: back-to-back playback only ever
    // needs one player node, since nothing plays simultaneously yet.
    private let nextPlayer = AVAudioPlayerNode()
    private let nextTimePitch = AVAudioUnitTimePitch()

    /// The full playback queue for the current session — every row's
    /// `trackPersistentID`, in playlist order. Set once by `play(queue:)`
    /// and walked forward by `advanceToNext()` as each track finishes.
    private var queue: [Int64] = []
    /// Index into `queue` of the track currently scheduled/playing.
    private var currentIndex = 0

    init() {
        configureGraph()
    }

    /// Attaches and connects both player-node chains into the engine's
    /// main mixer, per the confirmed design's "shared AVAudioMixerNode,
    /// which is where the actual blend happens". Called once from `init`.
    private func configureGraph() {
        engine.attach(currentPlayer)
        engine.attach(currentTimePitch)
        engine.attach(nextPlayer)
        engine.attach(nextTimePitch)

        engine.connect(currentPlayer, to: currentTimePitch, format: nil)
        engine.connect(currentTimePitch, to: engine.mainMixerNode, format: nil)
        engine.connect(nextPlayer, to: nextTimePitch, format: nil)
        engine.connect(nextTimePitch, to: engine.mainMixerNode, format: nil)
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
    /// path/URL), so re-querying is the correct, single source of truth
    /// for "what file does this track actually point to right now" —
    /// consistent with `MixBuilder.upsertAndAnalyzeIfNeeded`'s own
    /// `item.assetURL` access pattern.
    ///
    /// Requires media-library authorization to already be granted — true
    /// in the normal flow, since reaching Playlist Detail means Build Mix
    /// already ran, which means `SourceSelectionViewModel`'s authorization
    /// request already succeeded. A cold-launch-straight-into-an-existing-
    /// playlist path that skipped that flow could theoretically hit this
    /// unauthorized, in which case `query.items` comes back empty rather
    /// than throwing — surfaces as the same "couldn't find a playable
    /// file" error `play(trackPersistentID:)` already handles, not a crash.
    private func resolveFileURL(trackPersistentID: Int64) -> URL? {
        let query = MPMediaQuery.songs()
        let mediaID = UInt64(bitPattern: trackPersistentID)
        query.addFilterPredicate(MPMediaPropertyPredicate(value: mediaID, forProperty: MPMediaItemPropertyPersistentID))
        guard let item = query.items?.first else { return nil }
        // `assetURL` comes back nil for Apple Music subscription-streamed
        // (FairPlay-protected) tracks, per the DRM-Exclusion UX — the
        // Sequencer already filters these out of any pool before a
        // playlist is even built, so a nil URL here would mean the
        // track's access status changed since the playlist was built
        // (e.g. a download was removed), not a bug in this function.
        return item.assetURL
    }

    /// Plays a whole ordered set of tracks back-to-back — when one finishes
    /// naturally, the next one starts automatically, until the queue runs
    /// out. Still no crossfade/overlap between tracks (see this class's own
    /// doc comment); this is the "sequential auto-advance" slice, one step
    /// up from playing just a single track.
    func play(queue: [Int64], startIndex: Int = 0) {
        self.queue = queue
        self.currentIndex = startIndex
        playTrackAtCurrentIndex()
    }

    /// Convenience for the single-track case — equivalent to
    /// `play(queue: [trackPersistentID])`. Kept as its own entry point
    /// since "play just this one track" is still a meaningful, simpler
    /// action distinct from "play the whole set."
    func play(trackPersistentID: Int64) {
        play(queue: [trackPersistentID])
    }

    /// Schedules and plays `queue[currentIndex]`, or stops cleanly if
    /// `currentIndex` has walked off the end of the queue (the whole set
    /// finished playing).
    private func playTrackAtCurrentIndex() {
        guard queue.indices.contains(currentIndex) else {
            isPlaying = false
            nowPlayingTrackID = nil
            return
        }

        let trackPersistentID = queue[currentIndex]
        playbackError = nil

        guard let url = resolveFileURL(trackPersistentID: trackPersistentID) else {
            playbackError = "Couldn't find a playable file for this track."
            isPlaying = false
            nowPlayingTrackID = nil
            return
        }

        do {
            try activateSession()
            let file = try AVAudioFile(forReading: url)

            if !engine.isRunning {
                try engine.start()
            }

            // Every scheduled file gets its own generation number so
            // `handleTrackFinished` can tell "this track finished playing
            // naturally" apart from "this file's completion handler fired
            // because something else superseded it" (an explicit `stop()`,
            // or `currentPlayer.stop()` below when advancing to the next
            // track — both also fire the *previous* file's completion
            // handler, which must NOT be allowed to trigger a second,
            // stale advance).
            playbackGeneration += 1
            let generation = playbackGeneration

            currentPlayer.stop()
            currentPlayer.scheduleFile(file, at: nil) { [weak self] in
                // `scheduleFile`'s completion handler fires on an internal
                // AVAudioEngine thread, not necessarily the main actor —
                // hop back explicitly before touching a `@Published`
                // property, same "don't assume isolation" discipline
                // `MixBuilder`'s GRDB `await`s already established.
                Task { @MainActor in
                    self?.handleTrackFinished(generation: generation)
                }
            }
            currentPlayer.play()
            isPlaying = true
            nowPlayingTrackID = trackPersistentID
        } catch {
            playbackError = "Couldn't play this track: \(error.localizedDescription)"
            isPlaying = false
            nowPlayingTrackID = nil
        }
    }

    /// Generation counter backing the stale-completion guard described in
    /// `playTrackAtCurrentIndex`'s doc comment above.
    private var playbackGeneration = 0

    private func handleTrackFinished(generation: Int) {
        guard generation == playbackGeneration else { return }
        currentIndex += 1
        playTrackAtCurrentIndex()
    }

    /// Stops playback outright and clears the queue — a stopped session
    /// doesn't resume from where it left off, it starts over from a fresh
    /// `play(queue:)` call. Bumps `playbackGeneration` so the just-stopped
    /// track's completion handler (which `currentPlayer.stop()` also
    /// fires) is correctly ignored as stale rather than triggering an
    /// unwanted advance.
    func stop() {
        playbackGeneration += 1
        currentPlayer.stop()
        queue = []
        currentIndex = 0
        isPlaying = false
        nowPlayingTrackID = nil
    }
}
