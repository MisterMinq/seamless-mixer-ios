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

    private static let lastImportDateKey = "settings.lastImportedSongAddedAt"
    private static let lastBackupDateKey = "settings.lastBackupMadeAt"

    /// **Added 2026-10-21 (imported-songs backup record)** — when a song was
    /// last imported, and when a backup file was last made. Together they
    /// drive the Settings reminder "you've imported songs since your last
    /// backup": a backup is the only thing that survives deleting the app, so
    /// the reminder is what stops an import from being quietly un-backed-up.
    static var lastImportDate: Date? {
        get { UserDefaults.standard.object(forKey: lastImportDateKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastImportDateKey) }
    }

    static var lastBackupDate: Date? {
        get { UserDefaults.standard.object(forKey: lastBackupDateKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastBackupDateKey) }
    }

    /// True when there is at least one imported song and either no backup was
    /// ever made, or the last import is newer than the last backup.
    static func importedSongsNeedBackup(importedSongCount: Int) -> Bool {
        guard importedSongCount > 0 else { return false }
        guard let lastBackup = lastBackupDate else { return true }
        guard let lastImport = lastImportDate else { return false }
        return lastImport > lastBackup
    }
}
