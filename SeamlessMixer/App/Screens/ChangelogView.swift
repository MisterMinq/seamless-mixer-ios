import SwiftUI

/// "What's new" — a per-build, plain-language list of what changed, reached
/// from Settings. **Built 2026-09-10**, per Andy's request (backlog #63):
/// during a long test cycle it's easy to lose track of which fixes landed
/// in which build, and re-reading chat scrollback doesn't work for that.
///
/// Deliberately **user-facing only** — this is not CLAUDE.md's Version
/// History (which records every internal change, refactor, and dead end).
/// It only lists things a tester would actually see or feel, keyed by the
/// TestFlight build number shown in Settings (the `(NN)` / `V1.0.NN`),
/// newest first. Entries before the point where this screen was added are
/// grouped into a few "highlights" blocks, since the exact build-by-build
/// mapping that far back isn't reliable; from here on each build gets its
/// own precise entry.
///
/// Keep this current: every fix-round that ships something a tester can
/// see gets one entry added at the top, with the real build number, when
/// the "what changed / what to test" checklist for that round is written.
struct ChangelogView: View {
    struct Entry: Identifiable {
        let build: String
        let title: String
        let changes: [String]
        var id: String { build }
    }

    private static let entries: [Entry] = [
        Entry(
            build: "Build 71",
            title: "Crossfade rework",
            changes: [
                "Blends are longer across the board — still tempo-based per transition (roughly 3–16 seconds), and the Hub's \"Crossfade length\" control now goes up to +12 seconds on top.",
                "Fixed \"blending gets weaker over time\": the fade now finishes with real audio still under it, and keeps its full length even hours into a session.",
                "Takes effect for mixes built or Refreshed on this build onward — rebuild or Refresh an older mix to get the new timing."
            ]
        ),
        Entry(
            build: "Builds 66–70",
            title: "Playlists & Favourites",
            changes: [
                "Create your own playlists (\"New Playlist\"), and add the currently-playing song to one from Now Playing's \"…\" menu.",
                "Open any playlist to view and trim its songs. Editing an Apple Music playlist makes an independent \"SM\" copy — the real Apple Music playlist is never changed.",
                "Favourite individual songs (star on Now Playing, or the per-track \"…\"), and build a mix from your Favourites."
            ]
        ),
        Entry(
            build: "Builds 59–65",
            title: "Duplicates, scan visibility, tap-to-play",
            changes: [
                "Duplicate copies of the same song in your library no longer play back-to-back in a mix (there's a Settings toggle if you want every copy).",
                "The library scan now shows a running \"N of M songs\" count, and keeps going in the background.",
                "Tap any track in a mix or the Up Next list to start playing from there."
            ]
        ),
        Entry(
            build: "Builds 41–58",
            title: "Now Playing polish & playback recovery",
            changes: [
                "Now Playing background is drawn from the current track's album art and shifts as tracks change.",
                "The real connected speaker/output device name is shown.",
                "Tempo is nudged between tracks during a crossfade so blends beat-match better.",
                "Playback now recovers reliably after a call, alarm, Reminder, or a Bluetooth device connecting/disconnecting.",
                "Lock Screen and Control Center now show what's playing, with working transport controls."
            ]
        ),
        Entry(
            build: "Builds 30–40",
            title: "Search & the Songs picker",
            changes: [
                "Search on the Hub across every source type, plus a search box inside each category picker.",
                "\"Songs\" picker for choosing individual songs as a source.",
                "A-Z index rails on the long picker lists.",
                "The current build/version number is shown in Settings."
            ]
        ),
        Entry(
            build: "Builds 17–29",
            title: "Foundations",
            changes: [
                "Real equal-power crossfade blending between tracks.",
                "Pause, seek, and skip controls on Now Playing.",
                "My Mixes, Source Selection, Playlist Detail, and Up Next screens.",
                "Build Mix from any combination of playlists, genres, artists, and albums."
            ]
        )
    ]

    var body: some View {
        List {
            ForEach(Self.entries) { entry in
                Section {
                    ForEach(Array(entry.changes.enumerated()), id: \.offset) { _, change in
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                            Text("•")
                                .foregroundStyle(DesignTokens.Color.textSecondary)
                            Text(change)
                                .font(.footnote)
                                .foregroundStyle(DesignTokens.Color.textPrimary)
                        }
                    }
                } header: {
                    Text("\(entry.build) — \(entry.title)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                        .textCase(nil)
                }
            }
        }
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { ChangelogView() }
}
