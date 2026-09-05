import Foundation

/// Removes genuine duplicate files from a candidate pool before sequencing —
/// added 2026-09-05, per a real Testing report: Andy found the same song
/// playing 4 times in a row in a whole-library mix. Root cause, not a
/// sequencing bug: `Sequencer`'s greedy nearest-neighbor picks the next
/// track that best fits harmonic distance/BPM jump/energy trajectory, and
/// two genuine duplicate files of the same song analyze to near-identical
/// bpm/key/energy/brightness (they're the same recording) — to the
/// algorithm, a duplicate *is* the best possible next track, so clustering
/// them together is the expected result of a similarity-based sequencer
/// once the underlying library actually contains duplicate entries, not a
/// random glitch. `Sequencer`'s own no-repeat logic never applied here
/// either — it only prevents re-selecting the same `persistentID` twice
/// within one run, and two duplicate imports are two genuinely different
/// `persistentID`s from the library's point of view.
///
/// **Match criteria: normalized title + normalized artist + duration within
/// a small tolerance.** Title+artist alone risks false positives (a live
/// version or remix can legitimately share both) — requiring near-identical
/// duration too is a strong tiebreaker, since a genuinely different
/// version/take/remix essentially never has a near-identical runtime to the
/// original, while a real duplicate file does. This is the practical signal
/// available from real library metadata alone — no audio fingerprinting or
/// new permissions needed.
public enum DuplicateFilter {
    public struct Summary: Equatable {
        /// The pool with only one track kept per detected duplicate group —
        /// what `Sequencer` should actually run against.
        public let uniqueTracks: [Track]
        /// Number of *extra* copies removed (i.e. `group.count - 1` per
        /// group, summed) — not the total number of tracks in duplicate
        /// groups.
        public let duplicateCount: Int
        /// Each inner array is one group of 2+ tracks considered duplicates
        /// of each other, in the order originally encountered. The first
        /// track in each group is the one kept in `uniqueTracks`. Exposed
        /// so a caller can show Andy exactly which songs were flagged, per
        /// his own request ("just showing that there are duplicates found
        /// is a good step") — deliberately factual, no "you should delete
        /// this" framing baked into the data itself.
        public let duplicateGroups: [[Track]]
    }

    /// `durationToleranceSec` defaults to 2.0 — generous enough to absorb
    /// small container/trim differences between two exports of the same
    /// recording, tight enough that a genuinely different edit/remix/live
    /// take (which almost never lands within 2 real seconds of the
    /// original's runtime) won't be mistaken for a duplicate.
    public static func summarize(pool: [Track], durationToleranceSec: Double = 2.0) -> Summary {
        func normalize(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        // Group by normalized title+artist first -- cheap, exact grouping
        // key. `Dictionary` iteration order isn't stable, but the order
        // *within* each group is preserved via `pool`'s own order, and the
        // groups themselves are stitched back together by re-walking `pool`
        // below rather than trusting dictionary iteration order for the
        // final `uniqueTracks` ordering.
        var byKey: [String: [Track]] = [:]
        for track in pool {
            let key = normalize(track.title) + "\u{0}" + normalize(track.artist)
            byKey[key, default: []].append(track)
        }

        var keptIDs = Set<Int64>()
        var duplicateGroups: [[Track]] = []
        var duplicateCount = 0

        for tracksForKey in byKey.values {
            guard tracksForKey.count > 1 else {
                keptIDs.insert(tracksForKey[0].persistentID)
                continue
            }
            // Cluster by duration proximity within this title+artist group
            // -- sorted first so single-linkage clustering doesn't depend
            // on the pool's own incoming order.
            let sorted = tracksForKey.sorted { $0.durationSec < $1.durationSec }
            var cluster: [Track] = [sorted[0]]
            func closeCluster() {
                keptIDs.insert(cluster[0].persistentID)
                if cluster.count > 1 {
                    duplicateGroups.append(cluster)
                    duplicateCount += cluster.count - 1
                }
            }
            for track in sorted.dropFirst() {
                if track.durationSec - cluster.last!.durationSec <= durationToleranceSec {
                    cluster.append(track)
                } else {
                    closeCluster()
                    cluster = [track]
                }
            }
            closeCluster()
        }

        // Re-walk `pool` in its original order, keeping only tracks whose ID
        // survived clustering -- preserves the caller's own ordering
        // (matters for e.g. Sequencer's initial-shuffle tie-break) instead
        // of however `byKey`'s dictionary happened to iterate.
        let uniqueTracks = pool.filter { keptIDs.contains($0.persistentID) }

        return Summary(uniqueTracks: uniqueTracks, duplicateCount: duplicateCount, duplicateGroups: duplicateGroups)
    }
}
