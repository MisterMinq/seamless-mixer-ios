import SwiftUI
import PlaylistCore

/// **Added 2026-09-05**, per Andy's direct request after finding the same
/// song play 4 times in a row in a whole-library mix — see `DuplicateFilter`'s
/// own doc comment for the root cause. Andy was explicit about the framing:
/// "showing that there are duplicates found... is a good step" but a
/// "suggest deletion" message wasn't wanted — he already goes and deletes
/// duplicates himself once he knows about them, so this is a plain, factual
/// list to make that easy, not an advisory screen telling him what to do.
///
/// Grouped by duplicate group (one `Section` each) rather than a flat list,
/// so it's clear at a glance which tracks were considered copies of the
/// same song — each row shows title/artist/duration, since duration is
/// part of what makes two entries a match (see `DuplicateFilter`) and
/// having it visible helps confirm the grouping actually looks right before
/// going to delete anything.
struct DuplicateTracksView: View {
    let groups: [[Track]]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group) { track in
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                                Text(track.title)
                                    .foregroundStyle(DesignTokens.Color.textPrimary)
                                HStack {
                                    Text(track.artist)
                                        .font(.caption)
                                        .foregroundStyle(DesignTokens.Color.textSecondary)
                                    Spacer()
                                    Text(Self.formatDuration(track.durationSec))
                                        .font(.caption)
                                        .foregroundStyle(DesignTokens.Color.textSecondary)
                                }
                            }
                            .listRowBackground(DesignTokens.Color.surface)
                        }
                    } header: {
                        Text("\(group.count) copies found")
                    }
                }
            }
            .navigationTitle("Duplicate Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview {
    DuplicateTracksView(groups: [
        [
            Track(persistentID: 1, title: "Is This Love", artist: "Bob Marley", album: "", genre: "", durationSec: 237),
            Track(persistentID: 2, title: "Is This Love", artist: "Bob Marley", album: "", genre: "", durationSec: 237.4),
        ]
    ])
}
