import Foundation
import UIKit

/// Saved collage images for My Mixes — added 2026-10-20 (Push A), the
/// "permanent method" for the My Mixes artwork delay.
///
/// **Why this exists.** Until now `PlaylistStore` rebuilt every mix's
/// 4-album collage on EVERY launch: after the first frame it ran one
/// full-library `MPMediaQuery` scan and re-picked each mix's albums, so the
/// covers always appeared "a tick late" (placeholders first, covers filling
/// in afterward). That ordering was deliberate — doing the scan before the
/// first frame once crashed the app on launch (0.25.92) — but it meant the
/// same work was repeated on every launch, forever.
///
/// Now each mix's collage is drawn **once** (at Build Mix, at Refresh, or —
/// for mixes that existed before this change — the first launch after the
/// update) and saved here as up to four small JPEGs. My Mixes just reads
/// those files: a few KB of plain disk reads, no `MediaPlayer`, no library
/// scan, covers on screen immediately.
///
/// **Decisions (Andy, 2026-10-20):**
/// - Redrawn only when a mix is built or Refreshed (and after a library
///   re-scan that found new covers) — NOT on every small edit. After a
///   manual remove/reorder in Playlist Detail the saved collage can differ
///   slightly from the mix's first four albums until the next Refresh; that
///   is accepted ("nobody would deem it necessary to find out if the mix
///   contains songs from the artwork").
/// - A reinstall wipes these files, so every mix redraws once. Accepted.
///
/// **Storage.** `Application Support/MixCollages/<playlistID>_<slot>.jpg`
/// (slot 0...3, in collage order), plus `<playlistID>.none` for a mix whose
/// songs genuinely have no artwork at all, so such a mix is not re-scanned
/// on every launch. Application Support rather than Caches: Caches can be
/// purged by iOS at any time, which would silently bring the launch scan
/// back; a purge here is not harmful (it just redraws) but is not wanted.
///
/// Not unit-testable in `swift test` (UIKit + real file I/O) — same standing
/// gap as the other artwork files, see TESTING.md.
enum MixCollageStore {
    private static let maxSlots = 4

    private static let directory: URL = {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MixCollages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func slotURL(_ playlistID: Int64, _ slot: Int) -> URL {
        directory.appendingPathComponent("\(playlistID)_\(slot).jpg")
    }

    private static func noneMarkerURL(_ playlistID: Int64) -> URL {
        directory.appendingPathComponent("\(playlistID).none")
    }

    /// `nil` = nothing saved for this mix (needs drawing). `[]` = saved as
    /// "this mix has no artwork at all". Otherwise the saved images in
    /// collage order (1...4 of them).
    static func load(playlistID: Int64) -> [UIImage]? {
        var images: [UIImage] = []
        for slot in 0..<maxSlots {
            guard let data = try? Data(contentsOf: slotURL(playlistID, slot)),
                  let image = UIImage(data: data) else { break }
            images.append(image)
        }
        if !images.isEmpty { return images }
        if FileManager.default.fileExists(atPath: noneMarkerURL(playlistID).path) { return [] }
        return nil
    }

    /// Replaces whatever was saved for this mix. An empty `images` array
    /// saves the "no artwork" marker instead.
    static func save(images: [UIImage], playlistID: Int64) {
        delete(playlistID: playlistID)
        if images.isEmpty {
            try? Data().write(to: noneMarkerURL(playlistID))
            return
        }
        for (slot, image) in images.prefix(maxSlots).enumerated() {
            guard let data = image.jpegData(compressionQuality: 0.85) else { continue }
            try? data.write(to: slotURL(playlistID, slot))
        }
    }

    static func delete(playlistID: Int64) {
        for slot in 0..<maxSlots {
            try? FileManager.default.removeItem(at: slotURL(playlistID, slot))
        }
        try? FileManager.default.removeItem(at: noneMarkerURL(playlistID))
    }

    static func deleteAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
