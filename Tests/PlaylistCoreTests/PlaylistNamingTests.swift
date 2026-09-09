import XCTest
@testable import PlaylistCore

/// Covers CLAUDE.md's "Auto-naming logic": 1 source names itself, 2 sources
/// join as "A + B", 3+ falls back to a generic name. Pure-function tests —
/// no database needed. Run via `swift test` or Xcode's test navigator; not
/// run here, since no Swift toolchain is available in this environment.
final class PlaylistNamingTests: XCTestCase {

    private func source(_ type: SourceType, _ value: String, _ label: String) -> PlaylistSource {
        PlaylistSource(playlistID: 1, sourceType: type, sourceValue: value, sourceLabel: label)
    }

    /// **Added 2026-09-09**, alongside `isExclusion` — a whole-library
    /// build's own base source (never itself an exclusion) plus, in most of
    /// the new tests below, one or more genuinely-excluded sources built
    /// via `exclusion(_:_:_:)`.
    private func wholeLibrary() -> PlaylistSource {
        PlaylistSource(playlistID: 1, sourceType: .wholeLibrary, sourceValue: "Whole Library", sourceLabel: "Whole Library")
    }

    private func exclusion(_ type: SourceType, _ value: String, _ label: String) -> PlaylistSource {
        PlaylistSource(playlistID: 1, sourceType: type, sourceValue: value, sourceLabel: label, isExclusion: true)
    }

    func testSingleSourceTitle() {
        let sources = [source(.genre, "smooth-jazz", "Smooth jazz")]
        XCTAssertEqual(PlaylistNaming.title(for: sources), "Smooth jazz Seamless Mix")
    }

    func testTwoSourceTitleJoinsWithPlus() {
        let sources = [
            source(.genre, "smooth-jazz", "Smooth jazz"),
            source(.genre, "funk", "Funk"),
        ]
        XCTAssertEqual(PlaylistNaming.title(for: sources), "Smooth jazz + Funk Seamless Mix")
    }

    func testThreeOrMoreSourcesFallBackToCustom() {
        let sources = [
            source(.genre, "smooth-jazz", "Smooth jazz"),
            source(.genre, "funk", "Funk"),
            source(.artist, "123", "Bill Evans Trio"),
        ]
        XCTAssertEqual(PlaylistNaming.title(for: sources), "Custom Seamless Mix")
    }

    func testSingleSourceSubtitleIncludesTypeAndStats() {
        let sources = [source(.genre, "smooth-jazz", "Smooth jazz")]
        let subtitle = PlaylistNaming.subtitle(for: sources, mode: .energyWave, songCount: 12, durationSec: 47 * 60)
        XCTAssertEqual(subtitle, "Genre · Smooth jazz · Energy wave · 12 songs · 47 min")
    }

    func testThreeSourceSubtitleUsesCount() {
        let sources = [
            source(.genre, "smooth-jazz", "Smooth jazz"),
            source(.genre, "funk", "Funk"),
            source(.artist, "123", "Bill Evans Trio"),
        ]
        let subtitle = PlaylistNaming.subtitle(for: sources, mode: .stay, songCount: 24, durationSec: 78 * 60)
        XCTAssertEqual(subtitle, "3 sources · Stay · 24 songs · 78 min")
    }

    // MARK: - Whole library + exclusions (2026-09-09)

    /// A plain whole-library build (no exclusions) has exactly one source,
    /// same as any other single-source build — must keep falling through to
    /// the ordinary `case 1` naming, unchanged, for every playlist already
    /// built this way before exclusions existed.
    func testWholeLibraryWithNoExclusionsUsesOrdinarySingleSourceNaming() {
        let sources = [wholeLibrary()]
        XCTAssertEqual(PlaylistNaming.title(for: sources), "Whole Library Seamless Mix")
        let subtitle = PlaylistNaming.subtitle(for: sources, mode: .energyWave, songCount: 2609, durationSec: 180 * 60)
        XCTAssertEqual(subtitle, "Library · Whole Library · Energy wave · 2609 songs · 180 min")
    }

    func testWholeLibraryWithOneExclusionNamesItDirectly() {
        let sources = [wholeLibrary(), exclusion(.genre, "christmas", "Christmas")]
        XCTAssertEqual(PlaylistNaming.title(for: sources), "Whole Library (excluding Christmas) Seamless Mix")
        let subtitle = PlaylistNaming.subtitle(for: sources, mode: .energyWave, songCount: 2500, durationSec: 150 * 60)
        XCTAssertEqual(subtitle, "Whole Library · excluding Christmas · Energy wave · 2500 songs · 150 min")
    }

    /// With `sources.count == 3` (the base plus two exclusions), this must
    /// NOT fall into the generic count-based "3 sources" combination case
    /// below `exclusionBase`'s own guard — that would misleadingly read as
    /// three things being *included* together.
    func testWholeLibraryWithMultipleExclusionsDoesNotFallBackToGenericCount() {
        let sources = [wholeLibrary(), exclusion(.genre, "christmas", "Christmas"), exclusion(.genre, "kids", "Kids")]
        XCTAssertEqual(PlaylistNaming.title(for: sources), "Whole Library (excluding 2 sources) Seamless Mix")
        let subtitle = PlaylistNaming.subtitle(for: sources, mode: .stay, songCount: 2400, durationSec: 140 * 60)
        XCTAssertEqual(subtitle, "Whole Library · excluding Christmas, Kids · Stay · 2400 songs · 140 min")
    }
}
