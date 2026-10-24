import Foundation

/// Turns the path of a file the user picked for import into a short, readable
/// "where did this come from" note — e.g. `On My iPhone › Music › Funk` or
/// `iCloud Drive › Music` — so that months later, after a reinstall and a
/// restore, the app can say *which folder to pick* to bring the song back
/// (CLAUDE.md 0.26.40, Andy's own idea: "note where the files were imported
/// from").
///
/// This is a **hint for a human, not a way for the app to find the file**:
/// after an app delete iOS removes the app's permission to every folder it was
/// ever given, so the user still has to pick the folder again. The note just
/// tells them which one.
///
/// Pure string logic with no file access, so it is unit-tested
/// (`ImportSourceHintTests`). The path shapes below are what iOS hands an app
/// for files picked through the Files app; they have not been checked against a
/// real device, which is why every case falls back to the plain folder names
/// (`Music › Disco`) instead of returning nothing.
public enum ImportSourceHint {

    /// How many folder levels below the root location are kept (the last ones),
    /// so a deeply nested file doesn't produce a paragraph.
    private static let maxDepth = 3

    /// A readable description of the folder holding the file at `filePath`, or
    /// `nil` when the path has no folder part at all.
    public static func describe(filePath: String) -> String? {
        let parts = filePath.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let folders = Array(parts.dropLast()) // drop the file name itself

        // Files app → "On My iPhone": the picked file is a copy under a
        // "File Provider Storage" folder; the user's own folders sit below it.
        if let i = folders.firstIndex(of: "File Provider Storage") {
            return join("On My iPhone", Array(folders[(i + 1)...]))
        }

        // iCloud Drive proper, or another app's iCloud folder.
        if let i = folders.firstIndex(of: "Mobile Documents"), i + 1 < folders.count {
            let container = folders[i + 1]
            var rest = Array(folders[(i + 2)...])
            if container == "com~apple~CloudDocs" {
                return join("iCloud Drive", rest)
            }
            if rest.first == "Documents" { rest.removeFirst() }
            let appName = container.split(separator: "~").last.map(String.init) ?? container
            return join("iCloud (\(appName))", rest)
        }

        // Third-party cloud providers (Dropbox, Google Drive, OneDrive...).
        if let i = folders.firstIndex(of: "CloudStorage"), i + 1 < folders.count {
            let provider = folders[i + 1].split(separator: "-").first.map(String.init) ?? folders[i + 1]
            return join(provider, Array(folders[(i + 2)...]))
        }

        // Anything else: just the last two folder names.
        return folders.suffix(2).joined(separator: " › ")
    }

    private static func join(_ base: String, _ rest: [String]) -> String {
        ([base] + rest.suffix(maxDepth)).joined(separator: " › ")
    }
}
