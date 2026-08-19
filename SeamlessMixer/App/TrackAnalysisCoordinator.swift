import Foundation
import MediaPlayer
import PlaylistCore

/// The "resolve an `MPMediaItem` into an analyzed `tracks` row, reusing
/// whatever's already there" logic — extracted out of `MixBuilder` on
/// 2026-08-20, the same "pull a shared piece into its own type the moment a
/// second real caller needs it" move already made twice before in this
/// codebase (`MediaLibraryResolver` out of `MixBuilder`, `CrossfadeTiming`/
/// `DRMExclusionSummary` into `PlaylistCore`). The second caller here is
/// `LibraryScanner`, the first-run/whole-library scan — see its own doc
/// comment. Nothing about the logic itself changed in the move; this is a
/// relocation, not a rewrite, specifically to avoid re-introducing risk into
/// code that's already been through several real rounds of on-device fixes
/// (the DRM/`assetURL`-retry logic, the `isCloudItem` false-positive removal,
/// the not-downloaded-to-device wording).
///
/// Kept `@MainActor` (matching `MixBuilder`, the class this was extracted
/// from) rather than making it actor-agnostic — the GRDB `dbQueue.read`/
/// `.write` async overloads used inside are unchanged from how `MixBuilder`
/// already called them, so this keeps that behavior identical rather than
/// risking a subtle actor-isolation change during the move.
@MainActor
enum TrackAnalysisCoordinator {
    /// Reuses an already-analyzed `tracks` row if one exists; otherwise
    /// inserts/updates one, running `TrackAnalyzer` for tracks with usable
    /// raw audio access. The actual decode+analyze work is real CPU-bound
    /// work (seconds per track, per `RealAudioValidationTests`' own timing)
    /// so it runs off the main actor via `Task.detached`, keeping a
    /// caller's own progress updates responsive between tracks.
    static func upsertAndAnalyzeIfNeeded(item: MPMediaItem, db: DatabaseManager) async throws -> Track {
        let persistentID = Int64(bitPattern: item.persistentID)

        // GRDB resolves `dbQueue.read`/`.write` to their async overloads
        // inside this `async` function (vs. the sync overloads `MixBuilder
        // .persist` uses, since that function isn't `async`) -- both need
        // an explicit `await`, not just `try`.
        let existing: Track? = try await db.dbQueue.read { conn in
            try Track.fetchOne(conn, key: persistentID)
        }
        if let existing, existing.isAnalyzed {
            return existing
        }

        let resolvedURL = await resolveAudioAccess(for: item)
        let hasAccess = resolvedURL != nil
        var track = existing ?? Track(
            persistentID: persistentID,
            title: item.title ?? "Unknown",
            artist: item.artist ?? "Unknown",
            album: item.albumTitle ?? "Unknown",
            genre: item.genre ?? "Unknown",
            durationSec: item.playbackDuration,
            hasRawAudioAccess: hasAccess
        )
        track.hasRawAudioAccess = hasAccess

        if hasAccess, let url = resolvedURL {
            do {
                let features = try await Task.detached(priority: .userInitiated) {
                    try TrackAnalyzer.analyze(fileAt: url)
                }.value
                track.bpm = features.bpm
                track.musicalKey = features.camelotCode
                track.energy = features.energy
                track.brightness = features.brightness
                track.playableStartSec = features.playableStartSec
                track.playableDurationSec = features.playableDurationSec
                track.analyzedAt = Date()
            } catch {
                // Leave unanalyzed -- Sequencer's own isAnalyzed filter
                // silently excludes it later, the same "set aside, don't
                // block" behavior as DRM-Exclusion UX, just triggered by a
                // decode failure instead of a DRM check.
            }
        }

        // `track` is captured as an immutable `let` copy here rather than
        // the closure capturing the outer `var` directly -- GRDB's async
        // `write` runs its closure in a concurrent context, and capturing a
        // mutable var across that boundary is a Swift 6 language-mode
        // error (already flagged as a warning under Swift 5), not just a
        // style preference.
        let finalTrack = track
        try await db.dbQueue.write { conn in
            try finalTrack.save(conn)
        }
        return finalTrack
    }

    /// **Added 2026-08-17, revised the same day.** Andy owns every track on
    /// his phone outright (no Apple Music subscription at all, told
    /// directly, more than once) — yet the DRM-exclusion message kept
    /// telling him real songs were "streamed through your Apple Music
    /// subscription" (10 of 11, then 12 of 16, then still the same message
    /// on a fresh 16-song test after the first attempt at this fix). The
    /// original code trusted a single, un-retried `item.assetURL != nil`
    /// read as proof of real FairPlay DRM — genuinely unsafe, since
    /// `assetURL` is documented as unreliable for a plain local, owned file
    /// (e.g. a transient `nil` right when a bulk `MPMediaQuery` result is
    /// read). The retries below fix that part.
    ///
    /// **The first attempt at this fix also tried to use `item.isCloudItem`
    /// as a second signal** — the idea being that only a track iOS itself
    /// flags as a "cloud item" would be treated as real DRM, with a
    /// stubborn local nil reported as a harmless analysis failure instead.
    /// Andy's own real-device evidence disproved that: the exclusion
    /// message was still showing the identical "streamed through your
    /// Apple Music subscription" wording after that fix shipped, meaning
    /// `isCloudItem` is *also* true for tracks he genuinely owns and has
    /// fully downloaded — a well-documented Apple quirk where a purchased
    /// or catalog-matched track can carry that flag despite being real,
    /// local, playable audio. There is no reliable API available to a
    /// third-party app that can actually distinguish "real, FairPlay-locked
    /// subscription stream" from "a local file iOS happens to flag this
    /// way" — so this app no longer tries to guess. `hasRawAudioAccess`
    /// is back to meaning exactly one thing: "did a real, playable URL
    /// resolve, after retrying." The *reason* it didn't is no longer
    /// claimed anywhere in the UI — see `DRMExclusionSummary.message`'s own
    /// doc comment for the resulting copy change.
    ///
    /// **2026-08-20 — the real, confirmed reason found, by Andy directly.**
    /// A track can be listed and fully playable in the library via
    /// on-demand cloud streaming without ever being downloaded to the
    /// device — which is exactly the state this function's retries can
    /// never resolve past, since there genuinely is no local file yet.
    /// This doesn't change anything about the retry logic itself (still
    /// correct, still worth doing for the transient-nil case it does fix);
    /// it just means the resulting `nil` here is now honestly understood
    /// and explained, not just tolerated. See `DRMExclusionSummary`'s own
    /// doc comment for the full writeup and the updated user-facing copy.
    private static func resolveAudioAccess(for item: MPMediaItem) async -> URL? {
        if let url = item.assetURL {
            return url
        }
        if let refetched = requeryItem(persistentID: item.persistentID), let url = refetched.assetURL {
            return url
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let refetched = requeryItem(persistentID: item.persistentID), let url = refetched.assetURL {
            return url
        }
        return nil
    }

    /// **Rewritten 2026-08-17 — a real, separate bug from the file itself.**
    /// Andy correctly pushed back on treating the stale-Hub-selection fix
    /// as the whole story: multiple different, genuinely playable songs
    /// (not just "Games"/"Galaxy") have been excluded as "not accessible
    /// on this device" across several rounds of testing, which the
    /// selection-state bug doesn't explain at all — that bug explains
    /// *which* songs end up in a pool, not whether a specific song's audio
    /// resolves. `ffprobe`'d the actual "Games" file Andy sent: a
    /// completely ordinary, unprotected AAC file with full metadata — no
    /// DRM markers whatsoever. So the failure has to be in this app's own
    /// resolution code, not the file.
    ///
    /// Previously used `MPMediaPropertyPredicate(value:forProperty:
    /// MPMediaItemPropertyPersistentID)`, the exact same pattern several
    /// other places in this codebase also use. `MPMediaEntityPersistentID`
    /// is `UInt64`, and its real values are large 64-bit hashes that
    /// routinely have the high bit set (i.e. they'd be negative if
    /// reinterpreted as a signed `Int64`) — comparing such values via
    /// `MPMediaPropertyPredicate` against `MPMediaItemPropertyPersistentID`
    /// is a real, widely-reported MediaPlayer-framework unreliability, not
    /// a hypothetical: the predicate's internal `NSNumber` comparison can
    /// silently fail to match for exactly these large/high-bit-set values,
    /// returning zero items even though the target genuinely exists in
    /// the library.
    ///
    /// Fixed by removing the predicate entirely: fetches every song and
    /// filters with a plain Swift `==` on `MPMediaEntityPersistentID`
    /// (`UInt64`), which has no bridging ambiguity at all — a linear scan
    /// costs nothing meaningful at personal-library scale, and this is
    /// only called as a retry when the fast path (`item.assetURL` on an
    /// already-resolved item, no predicate involved) has already failed.
    private static func requeryItem(persistentID: MPMediaEntityPersistentID) -> MPMediaItem? {
        MPMediaQuery.songs().items?.first { $0.persistentID == persistentID }
    }
}
