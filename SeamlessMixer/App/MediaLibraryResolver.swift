import MediaPlayer

/// Resolves a set of selected sources (genre/artist/album/playlist) to their
/// real `MPMediaItem`s, de-duplicated across sources — moved out of
/// `MixBuilder` and into its own shared type 2026-08-14 so
/// `SourceSelectionViewModel` can reuse the exact same resolution logic for
/// a live "how many songs is this" preview on the Hub, without duplicating
/// the per-`SourceType` `MPMediaQuery` predicates in two places.
enum MediaLibraryResolver {
    /// - Parameter sources: any combination of genre/artist/album/playlist
    ///   selections — `.songs` ("whole library") is skipped, since it was
    ///   never resolved this way (it's its own `useWholeLibrary` toggle, not
    ///   a picked source).
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
                continue
            }
        }
        return items
    }
}
