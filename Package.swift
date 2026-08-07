// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PlaylistCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "PlaylistCore", targets: ["PlaylistCore"]),
    ],
    dependencies: [
        // Local SQLite wrapper. Confirmed by Andy as the default choice for the
        // data layer per CLAUDE.md's SQLite schema section (tracks / playlists /
        // playlist_sources / playlist_tracks). Not compiled or tested here — no
        // Xcode/Swift toolchain is available in this environment. Build in Xcode
        // to confirm the version resolves and the API surface below is correct.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "PlaylistCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "PlaylistCoreTests",
            dependencies: ["PlaylistCore"]
        ),
    ]
)
