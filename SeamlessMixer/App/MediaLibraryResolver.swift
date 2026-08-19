import MediaPlayer

/// Resolves a set of selected sources (genre/artist/album/playlist) to their
/// real `MPMediaItem`s, de-duplicated across sources — moved out of
/// `MixBuilder` and into its own shared type 2026-08-14 so
/// `SourceSelectionViewModel` can reuse the exact same resolution logic for
/// a live "how many songs is this" preview on the Hub, without duplicating
/// the per-`SourceType` `MPMediaQuery` predicates in two places.
enum MediaLibraryResolver {
    /// - Parameter sources: any combination of genre/artist/album/playlist/
    ///   song selections. "Whole library" itself is *not* one of these — it
    ///   stays its own separate `useWholeLibrary` toggle, never modeled as a
    ///   `SelectedSource` — but as of 2026-08-16, `.songs` genuinely does
    ///   mean "one specific song," matching ADR-7's original five source
    ///   types (Playlist/Songs/Genre/Artist/Album). It had been a dead,
    ///   defensively-skipped case until now — see `SongPickerView`'s own doc
    ///   comment for the real screen this finally builds.
    static func resolveItems(for sources: [SelectedSource]) -> [MPMediaItem] {
        var items: [MPMediaItem] = []
        var seenIDs = Set<MPMediaEntityPersistentID>()

        func add(_ newItems: [MPMediaItem]?) {
            for item in newItems ?? [] where seenIDs.insert(item.persistentID).inserted {
                items.append(item)
            }
        }

        for source in sources {
            switch source.type {
            case .genre:
                let query = MPMediaQuery.songs()
                query.addFilterPredicate(MPMediaPropertyPredicate(value: source.label, forProperty: MPMediaItemPropertyGenre))
                add(query.items)

            case .artist:
                // **Fixed 2026-08-18** -- was `MPMediaPropertyPredicate
                // (value:forProperty: MPMediaItemPropertyArtistPersistentID)`.
                // Real-device evidence: Andy's Artist picker showed real
                // artists (Herbie Mann, Abbey Lincoln, Art Blakey & The
                // Jazz Messengers -- all confirmed present in his library,
                // one via a real Apple Music screenshot of a compilation
                // album, "The No. 1 Jazz Album Ever!") as "0 songs," and
                // selecting that same artist for a build resolved nothing,
                // while selecting the *album* containing the exact same
                // track resolved every song correctly, Herbie Mann's
                // included. That rules out DRM (the album path proves the
                // file itself is fine) and points at this predicate
                // specifically -- the same class of large-UInt64-value
                // comparison unreliability already fixed for direct
                // persistentID song lookups (see `MixBuilder.requeryItem`'s
                // own doc comment), now shown to affect
                // `ArtistPersistentID` filtering too, not just plain
                // `PersistentID`. Switched to matching by artist *name*
                // instead -- exactly how `.genre` (below) already resolves,
                // which has never had this problem, since a plain string
                // `MPMediaPropertyPredicate` doesn't hit the same
                // UInt64-comparison path. `.album` deliberately stays
                // persistentID-based (unlike artist, it's confirmed
                // working, and Andy separately confirmed his library has
                // two distinct albums sharing one title -- matching by name
                // there would wrongly merge them).
                // `persistentID` itself is no longer used for resolution
                // (see above) -- still required as a presence check, since
                // it's what confirms this source came from a real picked
                // row rather than a malformed one.
                guard source.persistentID != nil else { continue }
                let query = MPMediaQuery.songs()
                query.addFilterPredicate(MPMediaPropertyPredicate(value: source.label, forProperty: MPMediaItemPropertyArtist))
                add(query.items)

            case .album:
                guard let persistentID = source.persistentID else { continue }
                let query = MPMediaQuery.songs()
                query.addFilterPredicate(MPMediaPropertyPredicate(value: persistentID, forProperty: MPMediaItemPropertyAlbumPersistentID))
                add(query.items)

            case .playlist:
                // No `MPMediaItemPropertyPlaylistPersistentID` predicate
                // exists on `MPMediaQuery.songs()` -- a playlist's tracks
                // are read off the `MPMediaPlaylist` collection itself,
                // found by matching its own `persistentID` among
                // `MPMediaQuery.playlists()`'s collections.
                guard let persistentID = source.persistentID else { continue }
                let matchingPlaylist = MPMediaQuery.playlists().collections?
                    .first { $0.persistentID == persistentID } as? MPMediaPlaylist
                add(matchingPlaylist?.items)

            case .songs:
                // **Fixed 2026-08-17** — was `MPMediaPropertyPredicate
                // (value:forProperty: MPMediaItemPropertyPersistentID)`,
                // the same pattern `MixBuilder.requeryItem` had — see that
                // function's own doc comment for the full reasoning: this
                // predicate is a real, documented MediaPlayer-framework
                // unreliability for the large, high-bit-set UInt64 values
                // `MPMediaEntityPersistentID` actually holds, and it's a
                // real, non-hypothetical suspect for individually-picked
                // songs silently failing to resolve. Filtering locally
                // with a plain Swift `==` has no such ambiguity.
                guard let persistentID = source.persistentID else { continue }
                add(MPMediaQuery.songs().items?.filter { $0.persistentID == persistentID })

            case .wholeLibrary:
                // A fresh Build Mix never constructs a `.wholeLibrary`-typed
                // `SelectedSource` here -- the Hub keeps "whole library" as
                // its own `useWholeLibrary` boolean and `MixBuilder
                // .performBuild` calls `allSongs()` directly, with its own
                // extra unanalyzed-count safety check (see that function's
                // own doc comment). This case *is* reached for real,
                // though: `MixBuilder.selectedSource(from:)` reconstructs a
                // `.wholeLibrary` source from a saved `PlaylistSource` row
                // when Refreshing an already-built whole-library playlist,
                // and that path resolves through here.
                add(allSongs())
            }
        }
        return items
    }

    /// **Added 2026-08-20** — every song in the library, with no filter at
    /// all. Used by `LibraryScanner` (the first-run scan) and, once a scan
    /// has run at least once, `MixBuilder`'s own "Use your whole library"
    /// path — see both types' own doc comments. Deliberately its own
    /// function rather than folded into `resolveItems(for:)`: "whole
    /// library" was never modeled as a `SelectedSource` (per that
    /// function's own doc comment, unchanged by this addition), and a raw
    /// `MPMediaQuery.songs()` result is already unique per item, so none of
    /// `resolveItems`'s de-duplication-across-multiple-sources machinery
    /// applies here.
    static func allSongs() -> [MPMediaItem] {
        MPMediaQuery.songs().items ?? []
    }
}
