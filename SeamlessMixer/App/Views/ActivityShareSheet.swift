import SwiftUI
import UIKit

/// A thin SwiftUI wrapper around `UIActivityViewController` — SwiftUI has
/// no native "share arbitrary files via the system share sheet" view as of
/// this project's iOS deployment target, so this is the standard, minimal
/// bridge. Used by `SettingsView`'s "Back up my mixes" export, so the user
/// can hand the backup file to Files, iCloud Drive, Mail, AirDrop, or
/// anywhere else outside this app's own sandbox.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
