import SwiftUI
import PlaylistCore

/// Screen 1 of the confirmed two-screen Source Selection design (see
/// CLAUDE.md's "Source Selection (revised, confirmed)"): a compact hub —
/// pinned "Use your whole library" row, four category rows (Playlists/
/// Genres/Artists/Albums), the mode picker, and a sticky "Build Mix" bar.
/// No search field, per the confirmed 2026-08-02 revision.
///
/// **Scope of this slice:** the Hub only. Screen 2 (the per-category
/// picker — A-Z rail for Artists/Albums, artwork grid for Playlists, plain
/// list for Genres) is real, designed, but a separate, larger piece of
/// work — tapping a category row here pushes to `CategoryPickerPlaceholderView`
/// for now rather than the real picker, so the navigation shape exists and
/// is testable without committing to the full picker in the same pass.
/// Likewise, the chip row showing accumulated cross-category picks is only
/// meaningful once Screen 2 exists to populate it — this pass only tracks
/// the binary "whole library selected or not" needed to drive the Build
/// Mix bar correctly.
struct SourceSelectionHubView: View {
    @StateObject private var viewModel = SourceSelectionViewModel()

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
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                allSongsRow
                categoryRows
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
            categoryRow(title: "Playlists", icon: "music.note.list", count: viewModel.playlistCount)
            categoryRow(title: "Genres", icon: "guitars", count: viewModel.genreCount)
            categoryRow(title: "Artists", icon: "person.wave.2", count: viewModel.artistCount)
            categoryRow(title: "Albums", icon: "square.stack", count: viewModel.albumCount)
        }
        // "All Songs" combining with anything else is redundant, per the
        // confirmed design -- gray these out rather than letting both be
        // selected at once.
        .opacity(viewModel.useWholeLibrary ? 0.4 : 1.0)
        .disabled(viewModel.useWholeLibrary)
    }

    private func categoryRow(title: String, icon: String, count: Int) -> some View {
        NavigationLink {
            CategoryPickerPlaceholderView(title: title)
        } label: {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: DesignTokens.Size.iconMedium))
                    .foregroundStyle(DesignTokens.Color.primaryText)
                Text(title)
                    .font(.body)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                Spacer()
                Text("\(count)")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
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
                Text(viewModel.hasSelection ? "1 source selected" : "No sources selected")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                Spacer()
                Button(action: {}) {
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
        SourceSelectionHubView()
    }
}
