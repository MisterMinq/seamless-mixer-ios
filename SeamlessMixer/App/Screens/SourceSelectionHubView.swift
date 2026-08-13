import SwiftUI
import PlaylistCore

/// Screen 1 of the confirmed two-screen Source Selection design (see
/// CLAUDE.md's "Source Selection (revised, confirmed)"): a compact hub —
/// pinned "Use your whole library" row, four category rows (Playlists/
/// Genres/Artists/Albums), the mode picker, and a sticky "Build Mix" bar.
/// No search field, per the confirmed 2026-08-02 revision.
///
/// **All four category pickers are now real** (Genres, Playlists, Artists,
/// Albums — `AlbumPickerView` was the last, combining the artwork-grid
/// cell `PlaylistPickerView` established with the A-Z rail
/// `ArtistPickerView` established), each with selection state flowing back
/// into this Hub's chip row and live "N selected" counts. **"Build Mix" is
/// wired for real** (see `MixBuilder`) and now resolves any combination of
/// genre/playlist/artist/album selections, not just genres — only "whole
/// library" still shows an error explaining it isn't supported yet, per the
/// reasoning in `MixBuilder`'s own doc comment. On success this pushes to
/// `PlaylistDetailView` (the confirmed Navigation Flow's actual next step)
/// rather than dismissing back to My Mixes, per CLAUDE.md's "tap Build Mix
/// -> Playlist Detail".
struct SourceSelectionHubView: View {
    let store: PlaylistStore

    @StateObject private var viewModel = SourceSelectionViewModel()
    @StateObject private var mixBuilder = MixBuilder()
    @State private var builtPlaylist: Playlist?

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
        .navigationDestination(item: $builtPlaylist) { playlist in
            PlaylistDetailView(playlist: playlist, store: store)
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
                durationControl
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
                PlaylistPickerView(viewModel: viewModel)
            }
            categoryRow(title: "Genres", icon: "guitars", count: viewModel.genreCount, type: .genre) {
                GenrePickerView(viewModel: viewModel)
            }
            categoryRow(title: "Artists", icon: "person.wave.2", count: viewModel.artistCount, type: .artist) {
                ArtistPickerView(viewModel: viewModel)
            }
            categoryRow(title: "Albums", icon: "square.stack", count: viewModel.albumCount, type: .album) {
                AlbumPickerView(viewModel: viewModel)
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
    /// populated live as checkboxes are ticked on any of the four category
    /// pickers.
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

    // MARK: - Duration control

    /// Tier 1 quick win per `documentation/Editability_UX_Gap_Analysis.docx`
    /// — `MixBuilder` already accepted `targetSeconds` as a parameter, this
    /// screen just never gave the user a way to set it. 10...120 min, by 5,
    /// matches `playlist_mixer.py`'s `--max-minutes` default cap at the top.
    ///
    /// **"Include everything" toggle added 2026-08-14** — real-device
    /// feedback asked why picking one bounded source (a genre, an artist)
    /// still gets trimmed to a duration rather than just including
    /// everything in it, mirroring Phase 1's `--keep-all` mode. Defaults to
    /// on (Andy's explicit instruction, same day).
    ///
    /// **Display bug fixed 2026-08-14** (reported in real-device testing the
    /// same day the toggle itself shipped): the first version only grayed
    /// out and disabled the Target Length control while the toggle was on,
    /// rather than hiding it — and always showed the toggle's "no length
    /// limit" explanatory text regardless of state, which read as
    /// contradictory when off. Now the Stepper is only in the view hierarchy
    /// at all when relevant (`if !includeEverything`), and the toggle's own
    /// subtitle switches between the two states instead of only ever
    /// describing the "on" one.
    private var durationControl: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Toggle(isOn: $viewModel.includeEverything) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text("Include everything")
                        .font(.body)
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                    Text(
                        viewModel.includeEverything
                            ? "No length limit — every available song in the selected pool is included."
                            : "Off — the mix is trimmed to the target length below."
                    )
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                }
            }
            .tint(DesignTokens.Color.primary)

            if !viewModel.includeEverything {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("Target length")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                    Stepper(value: $viewModel.targetMinutes, in: 10...120, step: 5) {
                        Text("\(viewModel.targetMinutes) min")
                            .foregroundStyle(DesignTokens.Color.textPrimary)
                    }
                }
            }
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
                        let playlist = await mixBuilder.build(
                            selectedSources: viewModel.selectedSources,
                            mode: viewModel.mode,
                            targetSeconds: Double(viewModel.targetMinutes * 60),
                            keepAll: viewModel.includeEverything,
                            store: store
                        )
                        if let playlist { builtPlaylist = playlist }
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

#Preview {
    // Same reasoning as `MyMixesView`'s preview -- a successful Build Mix
    // navigates to `PlaylistDetailView`, which requires `PlaybackEngine` as
    // an `@EnvironmentObject`.
    NavigationStack {
        SourceSelectionHubView(store: PlaylistStore())
    }
    .environmentObject(PlaybackEngine())
}
