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
        // playlist_sources / playlist_tracks). Resolves and builds clean as of
        // the 2026-08-07 Codemagic build (all 19 PlaylistCoreTests passing,
        // GRDB 6.29.3 resolved) — see CLAUDE.md Version History 0.13.6.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "PlaylistCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "PlaylistCoreTests",
            dependencies: ["PlaylistCore"],
            // A small, deliberately curated set of real tracks for
            // RealAudioValidationTests — a one-time, narrow exception to
            // keeping this repo free of audio-sample clutter (see CLAUDE.md
            // Rule 5 / "Build & Verification Pipeline"). Needed because
            // there is no way to run Swift anywhere except via this repo's
            // Codemagic build — Andy has no Mac, and the environment these
            // files were written in has no Swift toolchain either.
            resources: [.copy("Fixtures")]
        ),
    ]
)
