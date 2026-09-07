import SwiftUI
import PlaylistCore

/// The "view/edit a native playlist's songs" screen — new for Batch 2
/// (2026-09-07), closing the last piece of Andy's own original suggestion
/// #3 ("I could also envision being able to see the songs in an already
/// scanned playlist... and add or remove songs to it"), confirmed in
/// CLAUDE.md's "Add to Playlist" design as "Remove from this List."
///
/// Deliberately plain, not a re-skin of Playlist Detail: a `CustomPlaylist`
/// is raw, unsequenced material (per its own doc comment) — no crossfade
/// connector lines, no Play button, no collage artwork. Just the song list
/// and a way to trim it. Reached from `PlaylistPickerView`'s small edit
/// affordance on each cell; a plain Apple Music row not yet copied gets
/// copy-on-edited (`PlaylistStore.copyAppleMusicPlaylist`) before landing
/// here, so this screen only ever operates on a real `CustomPlaylist` id.
struct CustomPlaylistDetailView: View {
    let customPlaylistID: Int64
    let store: PlaylistStore

    @Environment(\.dismiss) private var dismiss
    @State private var playlist: CustomPlaylist?
    @State private var rows: [CustomPlaylistTrackDetail] = []
    @State private var loadError: String?
    @State private var showRenameAlert = false
    @State private var newName = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            if let loadError {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.error)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
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
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        newName = playlist?.name ?? ""
                        showRenameAlert = true
                    }
                    Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                        showDeleteConfirm = true
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
            Button("Save") {
                store.renameCustomPlaylist(customPlaylistID: customPlaylistID, to: newName)
                load()
            }
        }
        .confirmationDialog("Delete this playlist?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deleteCustomPlaylist(customPlaylistID: customPlaylistID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. The songs stay in your library — only this playlist is removed.")
        }
        .onAppear(perform: load)
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
                    remove(row)
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

    private func load() {
        loadError = nil
        guard let db = store.db else {
            loadError = "Couldn't open the library database."
            return
        }
        do {
            guard let detail = try db.loadCustomPlaylistDetail(customPlaylistID: customPlaylistID) else {
                loadError = "This playlist no longer exists."
                return
            }
            playlist = detail.playlist
            rows = detail.tracks
        } catch {
            loadError = "Couldn't load this playlist: \(error.localizedDescription)"
        }
    }

    private func remove(_ row: CustomPlaylistTrackDetail) {
        store.removeCustomPlaylistTrack(id: row.id, fromCustomPlaylistID: customPlaylistID)
        load()
    }
}
