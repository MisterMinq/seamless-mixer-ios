import SwiftUI
import PlaylistCore

/// Shared "..." overflow sheet — Tier 2 of `documentation/
/// Editability_UX_Gap_Analysis.docx`'s roadmap, reused on both My Mixes
/// rows and Playlist Detail's toolbar (both previously no-op buttons).
/// Layout matches the confirmed design (from the real Apple Music
/// reference screens section): two pinned quick actions up top (Favourite,
/// Share), then a plain list of secondary actions (Play Next, Rename,
/// Refresh, Delete).
///
/// **Real this slice:** Favourite (reuses the same `PlaylistStore.
/// setFavorite` the Playlist Detail toolbar star already uses), Rename,
/// Refresh (reuses `MixBuilder`'s existing resolve/analyze/sequence
/// pipeline against the playlist's own stored sources), Delete.
/// **Still disabled placeholders:** Share (blocked on ADR-5's export
/// pipeline, which doesn't exist) and Play Next (blocked on a real
/// playback queue, which doesn't exist) — both shown, greyed out, rather
/// than hidden, so the sheet's shape matches the confirmed design even
/// before every action is wired.
struct PlaylistOverflowSheet: View {
    let playlist: Playlist
    let store: PlaylistStore
    /// Called after a successful rename, so a caller displaying this
    /// playlist's name elsewhere (e.g. Playlist Detail's nav title) can
    /// update its own local copy — `playlist` itself is a `let` snapshot,
    /// not observed.
    var onRenamed: ((String) -> Void)?
    /// Called after a successful delete, so a caller showing this
    /// playlist's own detail screen can navigate away. My Mixes passes
    /// `nil` since its list already updates itself via `store.refresh()`.
    var onDeleted: (() -> Void)?

    @Environment(\.dismiss) private var dismissSheet
    @StateObject private var mixBuilder = MixBuilder()
    @State private var isFavorite: Bool
    @State private var showRenameAlert = false
    @State private var newName = ""
    @State private var showDeleteConfirm = false

    init(
        playlist: Playlist, store: PlaylistStore,
        onRenamed: ((String) -> Void)? = nil, onDeleted: (() -> Void)? = nil
    ) {
        self.playlist = playlist
        self.store = store
        self.onRenamed = onRenamed
        self.onDeleted = onDeleted
        _isFavorite = State(initialValue: playlist.isFavorite)
        _newName = State(initialValue: playlist.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.xxl) {
                Spacer()
                quickAction(icon: isFavorite ? "star.fill" : "star", label: "Favourite") {
                    isFavorite.toggle()
                    if let id = playlist.id {
                        store.setFavorite(playlistID: id, isFavorite: isFavorite)
                    }
                }
                quickAction(icon: "square.and.arrow.up", label: "Share", isDisabled: true) {}
                Spacer()
            }
            .padding(.vertical, DesignTokens.Spacing.lg)

            Divider()

            List {
                actionRow(icon: "text.badge.plus", title: "Play Next", isDisabled: true) {}
                actionRow(icon: "pencil", title: "Rename") {
                    newName = playlist.name
                    showRenameAlert = true
                }
                actionRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: mixBuilder.isBuilding ? (mixBuilder.progressText.isEmpty ? "Refreshing…" : mixBuilder.progressText) : "Refresh",
                    isDisabled: mixBuilder.isBuilding
                ) {
                    Task {
                        if await mixBuilder.refresh(playlist: playlist, store: store) {
                            dismissSheet()
                        }
                    }
                }
                actionRow(icon: "trash", title: "Delete", isDestructive: true) {
                    showDeleteConfirm = true
                }
            }
            .listStyle(.plain)
        }
        .presentationDetents([.medium])
        .alert("Rename mix", isPresented: $showRenameAlert) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let id = playlist.id {
                    store.rename(playlistID: id, to: newName)
                    onRenamed?(newName.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                dismissSheet()
            }
        }
        .confirmationDialog("Delete this mix?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = playlist.id {
                    store.delete(playlistID: id)
                }
                dismissSheet()
                onDeleted?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .alert("Couldn't refresh mix", isPresented: Binding(
            get: { mixBuilder.buildError != nil },
            set: { if !$0 { mixBuilder.buildError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mixBuilder.buildError ?? "")
        }
    }

    private func quickAction(icon: String, label: String, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: icon)
                    .font(.title2)
                Text(label)
                    .font(.caption)
            }
            .foregroundStyle(isDisabled ? DesignTokens.Color.textDisabled : DesignTokens.Color.primaryText)
        }
        .disabled(isDisabled)
    }

    private func actionRow(
        icon: String, title: String, isDisabled: Bool = false, isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 24)
                Text(title)
                Spacer()
            }
            .foregroundStyle(
                isDisabled ? DesignTokens.Color.textDisabled :
                    isDestructive ? DesignTokens.Color.error : DesignTokens.Color.textPrimary
            )
        }
        .disabled(isDisabled)
    }
}

#Preview {
    PlaylistOverflowSheet(playlist: Playlist(name: "Smooth Jazz Seamless Mix", mode: .energyWave), store: PlaylistStore())
}
