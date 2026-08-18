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
                guard let persistentID = source.persistentID else { continue }
                let query = MPMediaQuery.songs()
                query.addFilterPredicate(MPMediaPropertyPredicate(value: persistentID, forProperty: MPMediaItemPropertyArtistPersistentID))
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
            }
        }
        return items
    }
}
