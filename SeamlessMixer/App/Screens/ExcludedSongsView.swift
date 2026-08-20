import SwiftUI
import PlaylistCore

/// **Added 2026-08-21**, per Andy's direct request after several rounds of
/// the DRM-exclusion investigation only actually getting settled once he
/// checked *specific* songs (the "Games"/"Galaxy" real-world test that
/// found the actual root cause, 0.25.13): "giving me a list of songs not
/// included helps to investigate the reasoning... I could send you audio
/// data to analyse which would create better certainty." The exclusion
/// alert's aggregate count/message never let him do that without guessing
/// which songs to look at — this is the real list, reachable via "View
/// List" on that same alert.
///
/// Deliberately plain: title, artist, and a one-word reason per row (using
/// the same distinction `DRMExclusionSummary` already tracks internally —
/// `hasRawAudioAccess == false` vs. a decode/analysis failure with access),
/// no artwork or extra chrome. This is a diagnostic list for spot-checking
/// specific songs, not a polished library-browsing screen.
struct ExcludedSongsView: View {
    let tracks: [Track]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(tracks) { track in
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(track.title)
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                    HStack {
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                        Spacer()
                        Text(reason(for: track))
                            .font(.caption)
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                    }
                }
                .listRowBackground(DesignTokens.Color.surface)
            }
            .navigationTitle("Excluded Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Mirrors `DRMExclusionSummary.summarize(pool:)`'s own split — a track
    /// with no raw audio access at all vs. one that had access but still
    /// failed to produce real analysis data.
    private func reason(for track: Track) -> String {
        track.hasRawAudioAccess ? "Couldn't be analyzed" : "Not downloaded"
    }
}

#Preview {
    ExcludedSongsView(tracks: [
        Track(
            persistentID: 1, title: "Games", artist: "Jazmin Ghent", album: "", genre: "",
            durationSec: 200, hasRawAudioAccess: false
        ),
        Track(
            persistentID: 2, title: "Galaxy", artist: "Jeff Lorber Fusion", album: "", genre: "",
            durationSec: 200, hasRawAudioAccess: false
        ),
    ])
}
