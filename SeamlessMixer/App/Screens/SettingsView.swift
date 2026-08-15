import SwiftUI

/// First real slice of the Settings screen — deliberately deferred since
/// Phase 3 status, per CLAUDE.md ("first-run analysis/DRM-exclusion/Settings
/// screens stay deferred until the code that needs them... exists"), and My
/// Mixes' own gear icon has been a no-op since the screen was first built.
///
/// **Built 2026-08-15, narrowly scoped to one thing: showing which build is
/// currently installed.** Andy asked directly, mid-testing: "Is there any
/// way of knowing if I am testing the current build? Can we implement the
/// version e.g. V1.0.27 into the settings." A real, recurring friction point
/// across this whole real-device testing effort — every round has had to
/// establish "which build is this" from context (a Codemagic build number,
/// a timestamp) rather than the app just saying so. Reads
/// `CFBundleShortVersionString`/`CFBundleVersion` straight from
/// `Bundle.main` — the same two values `project.yml`'s `MARKETING_VERSION`/
/// `CURRENT_PROJECT_VERSION` (`$(BUILD_NUMBER)`) already write into the
/// generated Info.plist at build time (see CLAUDE.md's 0.18.11–0.18.14
/// versioning saga), so this is genuinely the same number Codemagic/
/// TestFlight assign, not a separately-maintained string that could drift.
/// Displayed as "V{short version}.{build}" (e.g. "V1.0.27"), matching the
/// exact format Andy used when asking for this.
///
/// Everything else a real Settings screen would eventually hold (first-run
/// scan status, DRM-exclusion overrides, background-scan progress — all
/// still-deferred per CLAUDE.md) is out of scope for this slice on purpose;
/// this exists to answer one specific, recurring question, not to become
/// the full screen in one pass.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    private var versionString: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "V\(shortVersion).\(build)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Version")
                            .foregroundStyle(DesignTokens.Color.textPrimary)
                        Spacer()
                        Text(versionString)
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                    }
                } footer: {
                    Text("This is the exact build/version number shown in TestFlight — useful for confirming which build you're testing against.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
