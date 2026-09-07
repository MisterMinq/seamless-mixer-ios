import SwiftUI
import PlaylistCore

/// The confirmed "New Playlist" screen (CLAUDE.md's "Add to Playlist"
/// design) — deliberately minimal: a name field and "Done," **no back
/// arrow at all**, per Andy's own explicit instruction to shorten the flow
/// as much as possible ("I do not think there should be a necessity for a
/// back arrow. As soon as 'Done' is tapped the Playlist is created...").
///
/// Reached two different ways, with two different dismiss behaviors — a
/// natural consequence of one shared screen serving both flows, not
/// something separately asked about. This view itself never dismisses
/// itself (no `@Environment(\.dismiss)`, deliberately) — `onCreated` is the
/// caller's own hook to decide what "done" means, since that differs by
/// entry context:
/// - **Directly from the Playlists picker's own "..." menu** (Batch 2,
///   built now): `PlaylistPickerView`'s `onCreated` flips the boolean that
///   pushed this screen back to `false`, popping it and landing back on the
///   picker, which reloads its custom-playlist list and shows the new,
///   empty, selectable playlist.
/// - **From "Add to Playlist" on a playing song** (Batch 3, not yet built):
///   `onCreated` will instead need to dismiss the *whole* flow back to Now
///   Playing, after silently adding the song that triggered it — a
///   different `onCreated` closure at a different call site; this view
///   itself doesn't need to know or care which context it's in.
struct NewPlaylistView: View {
    let store: PlaylistStore
    /// Called once, right after a successful creation, with the new
    /// playlist — the caller decides what "done" means for its own entry
    /// context (see this file's own doc comment above).
    let onCreated: (CustomPlaylist) -> Void

    @State private var name: String = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Playlist Name")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                TextField("e.g. Birthday Warm-Up", text: $name)
                    .font(.title3)
                    .padding(DesignTokens.Spacing.sm)
                    .background(DesignTokens.Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium)
                            .strokeBorder(DesignTokens.Color.border, lineWidth: DesignTokens.Size.borderWidthStandard)
                    )
                    .focused($nameFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(createAndDismiss)
            }
            Spacer()
        }
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Color.background)
        .navigationTitle("New Playlist")
        .navigationBarTitleDisplayMode(.inline)
        // No back arrow at all, per this file's own doc comment — the
        // system back button is hidden and no custom leading item replaces
        // it. "Done" (below) is the only way off this screen.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done", action: createAndDismiss)
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { nameFieldFocused = true }
    }

    private func createAndDismiss() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let created = store.createCustomPlaylist(name: trimmed) else { return }
        onCreated(created)
    }
}
