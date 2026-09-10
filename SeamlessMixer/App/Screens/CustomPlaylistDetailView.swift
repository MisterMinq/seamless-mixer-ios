import SwiftUI
import MediaPlayer
import PlaylistCore

/// The "view/edit a native playlist's songs" screen — new for Batch 2
/// (2026-09-07), closing the last piece of Andy's own original suggestion
/// #3 ("I could also envision being able to see the songs in an already
/// scanned playlist... and add or remove songs to it"), confirmed in
/// CLAUDE.md's "Add to Playlist" design as "Remove from this List."
///
/// **Rebuilt 2026-09-08 (Testing 67) — copy-on-edit moved from "the moment
/// you open this to look" to "the moment you actually change something,"
/// closing a real, confirmed bug, not a design change.** The confirmed
/// design (0.25.68) always said a native copy gets made "the moment editing
/// starts" — the first build of this screen instead ran
/// `PlaylistStore.copyAppleMusicPlaylist` the instant `PlaylistPickerView`'s
/// pencil was tapped, before any actual edit. Andy hit this directly during
/// real-device testing: tapping the pencil on every Apple Music playlist
/// "just to test it" silently converted every single one into a diverging,
/// "SM"-badged native copy with its real album art gone (`MergedRow.artwork`
/// returns `nil` for every `.custom` row) — his own words, "Does that make
/// sense - just by clicking on the pencil? All Playlist now have a badge
/// just because I clicked on pencil to test it," confirmed directly by his
/// screenshots. Real Apple Music playlists were never touched by any of
/// this (there's no write API to them at all — see `PlaylistStore
/// .copyAppleMusicPlaylist`'s own doc comment) — only this app's own
/// Playlists picker was showing the wrong thing.
///
/// **The fix**: this screen now accepts a `Target` — either a real,
/// already-persisted `CustomPlaylist` (`.existing`), or a not-yet-copied
/// Apple Music playlist (`.appleOrigin`), shown here read-only, straight
/// from `MediaPlayer`, until a genuine mutation is attempted. `ensureEditable()`
/// is the one place copy-on-edit actually runs now — called lazily, only
/// from inside Rename/Remove, the first time either is actually used. Once
/// that copy exists, this screen (and `PlaylistPickerView`'s grid, via
/// `onCopyCreated`) switches over to the real, persisted playlist for good —
/// re-opening this same Apple Music playlist later re-finds that same copy
/// (`DatabaseManager.customPlaylist(originApplePlaylistPersistentID:)`,
/// unchanged, already idempotent) rather than creating a second one.
///
/// Deliberately plain either way, not a re-skin of Playlist Detail: a
/// `CustomPlaylist` is raw, unsequenced material (per its own doc comment) —
/// no crossfade connector lines, no Play button, no collage artwork. Just
/// the song list and a way to trim it. Reached from `PlaylistPickerView`'s
/// small edit affordance on each cell.
struct CustomPlaylistDetailView: View {
    /// Which playlist this screen is showing. See this file's own top-of-
    /// doc comment for why `.appleOrigin` no longer means "already copied."
    enum Target: Hashable {
        case existing(Int64)
        case appleOrigin(MPMediaEntityPersistentID)
    }

    let target: Target
    let store: PlaylistStore
    /// Called once, the moment a lazy copy-on-first-edit actually creates a
    /// real `CustomPlaylist` from an `.appleOrigin` target — lets
    /// `PlaylistPickerView` refresh its own grid and migrate any existing
    /// Build-Mix selection from the old Apple row to the new native one
    /// (`migrateSelectionIfNeeded`, unchanged in spirit, just triggered from
    /// a real edit now instead of from opening the screen). Never called
    /// for an `.existing` target — that's already a real playlist.
    var onCopyCreated: ((CustomPlaylist) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    /// Non-nil once this screen is genuinely editing a real, persisted
    /// `CustomPlaylist` — either because `target` started as `.existing`, or
    /// because `ensureEditable()` already ran. Drives `isReadOnly` below.
    @State private var customPlaylistID: Int64?
    @State private var playlist: CustomPlaylist?
    @State private var rows: [CustomPlaylistTrackDetail] = []

    /// Only populated while still read-only (`.appleOrigin`, no copy made
    /// yet) — the real Apple Music playlist's own songs, read straight from
    /// `MediaPlayer`, never touching this app's database.
    @State private var appleRows: [AppleRow] = []
    @State private var appleName: String = ""

    @State private var loadError: String?
    @State private var showRenameAlert = false
    @State private var newName = ""
    @State private var showDeleteConfirm = false
    @State private var pendingRemoval: RemovalTarget?
    /// **Added 2026-09-10** — "Duplicate" makes an independent standalone
    /// copy under a new name (`duplicateName`), leaving this playlist (or,
    /// for a still-read-only Apple Music playlist, the real Apple original)
    /// untouched. The confirmed alternative to auto-forking on every edit.
    @State private var showDuplicateAlert = false
    @State private var duplicateName = ""

    /// A row of a not-yet-copied Apple Music playlist — display only, no
    /// database id to key off of yet.
    struct AppleRow: Identifiable {
        let persistentID: MPMediaEntityPersistentID
        let title: String
        let artist: String
        var id: MPMediaEntityPersistentID { persistentID }
    }

    /// One removal pending confirmation — **added 2026-09-08**, per Andy's
    /// direct request: removing a song here couldn't be undone (there was
    /// no "add it back," since the exact prior position/list was already
    /// gone the instant it was removed) — his own words, "I am stuck. I
    /// cannot add the song to the Playlist again. It cannot be restored,"
    /// after removing one without meaning to. Same confirm-before-destroy
    /// pattern "Delete Playlist" below already used.
    enum RemovalTarget {
        case existing(CustomPlaylistTrackDetail)
        case appleOrigin(AppleRow)
    }

    private var displayName: String {
        if let playlist { return playlist.name }
        return appleName.isEmpty ? "Playlist" : appleName
    }

    private var isReadOnly: Bool { customPlaylistID == nil }

    var body: some View {
        List {
            if let loadError {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.error)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if isReadOnly {
                if appleRows.isEmpty {
                    Text("No songs in this playlist.")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(appleRows) { row in
                        appleRowView(row)
                            .listRowBackground(DesignTokens.Color.background)
                    }
                }
            } else if rows.isEmpty {
                Text("No songs yet — add some from any track's “…” menu while listening, or from a picker screen.")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(rows) { row in
                    trackRow(row)
                        .listRowBackground(DesignTokens.Color.background)
                }
            }
        }
        .listStyle(.plain)
        .background(DesignTokens.Color.background)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        newName = displayName
                        showRenameAlert = true
                    }
                    // Works for both: an `.existing` native playlist, and a
                    // still-read-only Apple Music one (which it snapshots
                    // into a fresh standalone "SM" playlist without touching
                    // the real Apple original).
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        duplicateName = "\(displayName) copy"
                        showDuplicateAlert = true
                    }
                    // A plain, not-yet-copied Apple Music playlist has
                    // nothing native to delete yet — this only makes sense
                    // once a real copy exists.
                    if !isReadOnly {
                        Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .padding(8)
                        .background(Circle().fill(DesignTokens.Color.surfaceTint))
                }
                .menuStyle(.borderlessButton)
            }
        }
        .alert("Rename Playlist", isPresented: $showRenameAlert) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { rename(to: newName) }
        }
        .alert("Duplicate Playlist", isPresented: $showDuplicateAlert) {
            TextField("Name", text: $duplicateName)
            Button("Cancel", role: .cancel) {}
            Button("Duplicate") { duplicate(named: duplicateName) }
        } message: {
            Text("Makes a separate copy with these songs. This playlist stays exactly as it is.")
        }
        .confirmationDialog("Delete this playlist?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = customPlaylistID {
                    store.deleteCustomPlaylist(customPlaylistID: id)
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. The songs stay in your library — only this playlist is removed.")
        }
        .confirmationDialog("Remove this song from the list?", isPresented: removalConfirmationBinding, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let pendingRemoval { performRemoval(pendingRemoval) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("It'll come off this playlist. You can always add it back later from any track's “…” menu.")
        }
        .onAppear(perform: load)
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private func trackRow(_ row: CustomPlaylistTrackDetail) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.track.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .lineLimit(1)
                Text(row.track.artist)
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Remove from this List", role: .destructive) {
                    pendingRemoval = .existing(row)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .padding(8)
                    .background(Circle().fill(DesignTokens.Color.surfaceTint))
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    private func appleRowView(_ row: AppleRow) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .lineLimit(1)
                Text(row.artist)
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Remove from this List", role: .destructive) {
                    pendingRemoval = .appleOrigin(row)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .padding(8)
                    .background(Circle().fill(DesignTokens.Color.surfaceTint))
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    // MARK: - Load

    private func load() {
        loadError = nil
        switch target {
        case .existing(let id):
            customPlaylistID = id
            loadExisting(id: id)
        case .appleOrigin(let persistentID):
            // **Revised 2026-09-10**: always show the live Apple Music
            // playlist read-only here, even if an "SM" copy already exists.
            // Now that the Apple row and its "SM" copy both appear in the
            // Playlists picker (the copy is no longer hidden), the Apple
            // row's pencil is meant to be exactly that — the pristine
            // original, unchanged, so "Duplicate" from here snapshots the
            // real Apple list. A genuine edit (Rename/Remove) still routes
            // transparently to the existing copy via `ensureEditable()`,
            // which stays idempotent.
            loadAppleReadOnly(persistentID: persistentID)
        }
    }

    private func loadExisting(id: Int64) {
        guard let db = store.db else {
            loadError = "Couldn't open the library database."
            return
        }
        do {
            guard let detail = try db.loadCustomPlaylistDetail(customPlaylistID: id) else {
                loadError = "This playlist no longer exists."
                return
            }
            playlist = detail.playlist
            rows = detail.tracks
        } catch {
            loadError = "Couldn't load this playlist: \(error.localizedDescription)"
        }
    }

    private func loadAppleReadOnly(persistentID: MPMediaEntityPersistentID) {
        guard let mediaPlaylist = MPMediaQuery.playlists().collections?
            .first(where: { $0.persistentID == persistentID }) as? MPMediaPlaylist
        else {
            loadError = "This playlist is no longer in your library."
            return
        }
        appleName = mediaPlaylist.name ?? "Untitled Playlist"
        appleRows = mediaPlaylist.items.map { item in
            AppleRow(persistentID: item.persistentID, title: item.title ?? "Untitled", artist: item.artist ?? "Unknown Artist")
        }
    }

    // MARK: - Lazy copy-on-edit

    /// Runs copy-on-edit for real, the first time a genuine mutation is
    /// attempted on a not-yet-copied Apple Music playlist — see this file's
    /// own top-of-file doc comment. A no-op returning the existing id once a
    /// copy already exists (either from an earlier session, or from earlier
    /// in this same visit).
    private func ensureEditable() -> Int64? {
        if let customPlaylistID { return customPlaylistID }
        guard case .appleOrigin(let persistentID) = target,
              let mediaPlaylist = MPMediaQuery.playlists().collections?
                .first(where: { $0.persistentID == persistentID }) as? MPMediaPlaylist,
              let copy = store.copyAppleMusicPlaylist(mediaPlaylist)
        else { return nil }
        customPlaylistID = copy.id
        playlist = copy
        onCopyCreated?(copy)
        return copy.id
    }

    private func rename(to name: String) {
        guard let id = ensureEditable() else { return }
        store.renameCustomPlaylist(customPlaylistID: id, to: name)
        loadExisting(id: id)
    }

    /// Deliberately does **not** call `ensureEditable()` — duplicating a
    /// still-read-only Apple Music playlist snapshots it into a fresh
    /// standalone "SM" playlist without making the origin-linked copy-on-edit
    /// copy, so the Apple row stays exactly as it was. Dismisses on success
    /// so `PlaylistPickerView` picks up the new playlist on its own
    /// `onDisappear` refresh, landing the user back on the grid where both
    /// the original and the new copy are visible.
    private func duplicate(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let created: CustomPlaylist?
        if let id = customPlaylistID {
            created = store.duplicateCustomPlaylist(customPlaylistID: id, newName: trimmed)
        } else if case .appleOrigin(let persistentID) = target,
                  let mediaPlaylist = MPMediaQuery.playlists().collections?
                    .first(where: { $0.persistentID == persistentID }) as? MPMediaPlaylist {
            created = store.duplicateApplePlaylist(mediaPlaylist, newName: trimmed)
        } else {
            created = nil
        }
        if created != nil {
            dismiss()
        }
    }

    private func performRemoval(_ removal: RemovalTarget) {
        switch removal {
        case .existing(let row):
            guard let id = customPlaylistID else { return }
            store.removeCustomPlaylistTrack(id: row.id, fromCustomPlaylistID: id)
            loadExisting(id: id)
        case .appleOrigin(let appleRow):
            // The copy already carries every song, including this one (a
            // full bulk import) — "remove" here means "copy, then drop this
            // one song from the fresh copy," not "copy everything except
            // it."
            guard let id = ensureEditable() else { return }
            loadExisting(id: id)
            let wantedID = Int64(bitPattern: appleRow.persistentID)
            if let matchingRow = rows.first(where: { $0.track.persistentID == wantedID }) {
                store.removeCustomPlaylistTrack(id: matchingRow.id, fromCustomPlaylistID: id)
                loadExisting(id: id)
            }
        }
    }
}
