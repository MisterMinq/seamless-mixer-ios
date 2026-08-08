import SwiftUI
import PlaylistCore

/// Screen 1 of the confirmed two-screen Source Selection design (see
/// CLAUDE.md's "Source Selection (revised, confirmed)"): a compact hub —
/// pinned "Use your whole library" row, four category rows (Playlists/
/// Genres/Artists/Albums), the mode picker, and a sticky "Build Mix" bar.
/// No search field, per the confirmed 2026-08-02 revision.
///
/// **Scope of this slice (revised):** Genres is now a real picker
/// (`GenrePickerView`) with real selection state flowing back into this
/// Hub's chip row and live "N selected" counts. Playlists/Artists/Albums
/// still route to `CategoryPickerPlaceholderView` — their pickers need an
/// A-Z rail (Artists/Albums) or an artwork grid (Playlists/Albums), each a
/// separate, larger piece of work, same phased approach as everything else
/// in this app. **"Build Mix" is now wired for real** (see `MixBuilder`) —
/// scoped to genre selections only; "whole library" still shows an error
/// explaining it isn't supported yet, per the reasoning in `MixBuilder`'s
/// own doc comment.
struct SourceSelectionHubView: View {
    let store: PlaylistStore

    @StateObject private var viewModel = SourceSelectionViewModel()
    @StateObject private var mixBuilder = MixBuilder()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch viewModel.authorizationStatus {
            case .authorized:
                content
            case .notDetermined:
                ProgressView()
            default:
                permissionDenied
            }
        }
        .background(DesignTokens.Color.background)
        .navigationTitle("New Seamless Mix")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.requestAccessAndLoadCounts() }
        .overlay {
            if mixBuilder.isBuilding {
                buildingOverlay
            }
        }
        .alert("Couldn't build mix", isPresented: buildErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mixBuilder.buildError ?? "")
        }
    }

    private var buildErrorBinding: Binding<Bool> {
        Binding(
            get: { mixBuilder.buildError != nil },
            set: { if !$0 { mixBuilder.buildError = nil } }
        )
    }

    private var buildingOverlay: some View {
        ZStack {
            DesignTokens.Color.background.opacity(0.9).ignoresSafeArea()
            VStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView()
                    .tint(DesignTokens.Color.primary)
                Text(mixBuilder.progressText)
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                allSongsRow
                categoryRows
                chipRow
                modePicker
                // Bottom padding so the sticky Build Mix bar doesn't cover
                // the last row.
                Color.clear.frame(height: DesignTokens.Size.buttonHeightStandard + DesignTokens.Spacing.lg)
            }
            .padding(DesignTokens.Spacing.md)
        }
        .safeAreaInset(edge: .bottom) { buildMixBar }
    }

    // MARK: - Rows

    private var allSongsRow: some View {
        Button {
            viewModel.useWholeLibrary.toggle()
        } label: {
            HStack {
                Image(systemName: "music.note.house")
                    .font(.system(size: DesignTokens.Size.iconMedium))
                    .foregroundStyle(DesignTokens.Color.primaryText)
                Text("Use your whole library")
                    .font(.body.weight(.medium))
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                Spacer()
                if viewModel.useWholeLibrary {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignTokens.Color.primary)
                }
            }
            .padding(DesignTokens.Spacing.sm)
            .background(DesignTokens.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium)
                    .strokeBorder(DesignTokens.Color.border, lineWidth: DesignTokens.Size.borderWidthStandard)
            )
        }
        .buttonStyle(.plain)
    }

    private var categoryRows: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            categoryRow(title: "Playlists", icon: "music.note.list", count: viewModel.playlistCount, type: .playlist) {
                CategoryPickerPlaceholderView(title: "Playlists")
            }
            categoryRow(title: "Genres", icon: "guitars", count: viewModel.genreCount, type: .genre) {
                GenrePickerView(viewModel: viewModel)
            }
            categoryRow(title: "Artists", icon: "person.wave.2", count: viewModel.artistCount, type: .artist) {
                CategoryPickerPlaceholderView(title: "Artists")
            }
            categoryRow(title: "Albums", icon: "square.stack", count: viewModel.albumCount, type: .album) {
                CategoryPickerPlaceholderView(title: "Albums")
            }
        }
        // "All Songs" combining with anything else is redundant, per the
        // confirmed design -- gray these out rather than letting both be
        // selected at once.
        .opacity(viewModel.useWholeLibrary ? 0.4 : 1.0)
        .disabled(viewModel.useWholeLibrary)
    }

    /// - Parameter type: which `SourceType` this row represents, used only
    ///   to compute the live "N selected" badge from `viewModel.selectedSources`
    ///   — the row's own picked-ness has no other bearing on navigation.
    private func categoryRow<Destination: View>(
        title: String, icon: String, count: Int, type: SourceType,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        let selectedCount = viewModel.selectedCount(for: type)
        return NavigationLink {
            destination()
        } label: {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: DesignTokens.Size.iconMedium))
                    .foregroundStyle(DesignTokens.Color.primaryText)
                Text(title)
                    .font(.body)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                Spacer()
                Text(selectedCount > 0 ? "\(selectedCount) selected" : "\(count)")
                    .font(.footnote)
                    .foregroundStyle(selectedCount > 0 ? DesignTokens.Color.primaryText : DesignTokens.Color.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
            .padding(DesignTokens.Spacing.sm)
            .background(DesignTokens.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chip row

    /// "How do I see what I'm combining" across categories, per the
    /// confirmed design — a horizontally-scrollable row of removable chips,
    /// populated live as checkboxes are ticked on a category picker. Only
    /// Genres can populate this so far (see scope note above).
    @ViewBuilder
    private var chipRow: some View {
        if !viewModel.selectedSources.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(viewModel.selectedSources) { source in
                        HStack(spacing: DesignTokens.Spacing.xxs) {
                            Text(source.label)
                                .font(.footnote)
                            Button {
                                viewModel.toggle(source)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.footnote)
                            }
                        }
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.vertical, DesignTokens.Spacing.xxs)
                        .background(DesignTokens.Color.surfaceTint)
                        .foregroundStyle(DesignTokens.Color.primaryText)
                        .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Mode")
                .font(.footnote.weight(.medium))
                .foregroundStyle(DesignTokens.Color.textSecondary)
            Picker("Mode", selection: $viewModel.mode) {
                ForEach(PlaylistMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Build Mix bar

    private var buildMixBar: some View {
        VStack(spacing: DesignTokens.Spacing.xxs) {
            Divider()
            HStack {
                Text(selectionSummary)
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                Spacer()
                Button {
                    Task {
                        // 30 min default target -- there's no duration
                        // control on this screen yet (Playlist Detail /
                        // duration setting isn't designed in that level of
                        // detail yet), so this is a placeholder, not a
                        // confirmed value.
                        let succeeded = await mixBuilder.build(
                            selectedSources: viewModel.selectedSources,
                            mode: viewModel.mode,
                            targetSeconds: 30 * 60,
                            store: store
                        )
                        if succeeded { dismiss() }
                    }
                } label: {
                    Text("Build Mix")
                        .frame(minHeight: DesignTokens.Size.buttonHeightStandard)
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Color.primary)
                .foregroundStyle(DesignTokens.Color.onPrimary)
                .disabled(!viewModel.hasSelection)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.xs)
        }
        .background(DesignTokens.Color.surface)
    }

    private var selectionSummary: String {
        if viewModel.useWholeLibrary { return "Whole library selected" }
        let count = viewModel.selectedSources.count
        if count == 0 { return "No sources selected" }
        return "\(count) source\(count == 1 ? "" : "s") selected"
    }

    // MARK: - Permission denied

    private var permissionDenied: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "music.note.list")
                .font(.title)
                .foregroundStyle(DesignTokens.Color.textSecondary)
            Text("Seamless Mixer needs access to your music library to build mixes from your own songs.")
                .font(.body)
                .foregroundStyle(DesignTokens.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignTokens.Spacing.xl)
        }
        .padding(DesignTokens.Spacing.lg)
    }
}

/// Stand-in for Screen 2 (the real per-category picker: A-Z rail for
/// Artists/Albums, artwork grid for Playlists, plain list for Genres) —
/// deliberately not built this slice, per the phased approach already used
/// for every other piece of this app. Exists so the Hub's navigation is
/// real and testable now, not so this placeholder itself is a finished UI.
struct CategoryPickerPlaceholderView: View {
    let title: String

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text("\(title) picker")
                .font(.title2.weight(.semibold))
                .foregroundStyle(DesignTokens.Color.textPrimary)
            Text("Not built yet — coming in a later slice.")
                .font(.body)
                .foregroundStyle(DesignTokens.Color.textSecondary)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SourceSelectionHubView(store: PlaylistStore())
    }
}
