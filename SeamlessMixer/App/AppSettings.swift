import Foundation

/// Small, `UserDefaults`-backed app-wide settings that don't need a full
/// `ObservableObject`/store of their own — added 2026-09-05 for the first
/// one of these, `includeDuplicateTracks` (see `DuplicateFilter`'s own doc
/// comment). Read directly by `MixBuilder` at build time and written
/// directly by `SettingsView`'s toggle; no observation needed either way
/// since a build only reads the value once, at the moment it runs.
enum AppSettings {
    private static let includeDuplicateTracksKey = "settings.includeDuplicateTracks"

    /// Defaults to `false` (dedup on) — the confirmed default per Andy's own
    /// call: nobody actually wants the same song playing back-to-back, so
    /// the better behavior is the out-of-the-box one, with this as the
    /// escape hatch for the rare case someone wants every copy included.
    static var includeDuplicateTracks: Bool {
        get { UserDefaults.standard.bool(forKey: includeDuplicateTracksKey) }
        set { UserDefaults.standard.set(newValue, forKey: includeDuplicateTracksKey) }
    }
}
