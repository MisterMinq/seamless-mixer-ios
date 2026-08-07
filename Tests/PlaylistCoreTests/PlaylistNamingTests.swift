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
}
