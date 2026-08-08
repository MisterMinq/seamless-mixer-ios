import SwiftUI

/// Swift source of truth for `documentation/Design_Tokens.docx` / CLAUDE.md's
/// "Design Tokens" section — values copied over exactly, not re-derived.
/// Every screen should read from here rather than hardcoding a hex/point
/// value, per Rule 7's "defined once, reused everywhere" requirement. If a
/// token changes, update both this file and the CLAUDE.md section together
/// (Rule 2's iOS-codebase extension).
///
/// The Now Playing screen's dynamic, artwork-derived background/text is
/// intentionally NOT here — that's computed per-track at runtime (Core
/// Image dominant-color extraction + `MeshGradient`), not a fixed token.
/// `DesignTokens.color` values are the static fallback used everywhere else.
enum DesignTokens {

    enum Color {
        static let background = SwiftUI.Color(hex: 0xF5F9FA)
        static let surface = SwiftUI.Color(hex: 0xFFFFFF)
        static let surfaceTint = SwiftUI.Color(hex: 0xEAF2F3)

        /// Large fills/icons >=24px only — buttons, progress fill, active
        /// states. Fails 4.5:1 for small text (white-on-primary measures
        /// 3.68:1) — use `primaryText` instead for small text/thin strokes.
        static let primary = SwiftUI.Color(hex: 0x23948F)
        /// Teal variant for small text / thin icon strokes on light
        /// backgrounds — clears 4.5:1 (5.79:1) where `primary` itself doesn't.
        static let primaryText = SwiftUI.Color(hex: 0x146D69)
        static let primaryPressed = SwiftUI.Color(hex: 0x0F5652)

        /// Secondary accent for larger surfaces/chips (e.g. "blending into
        /// next"). Not verified for small text — don't use that way.
        static let secondary = SwiftUI.Color(hex: 0x6E97C9)

        static let onPrimary = SwiftUI.Color(hex: 0xFFFFFF)

        static let textPrimary = SwiftUI.Color(hex: 0x16232B)
        static let textSecondary = SwiftUI.Color(hex: 0x5B6B75)
        static let textDisabled = SwiftUI.Color(hex: 0xA9B4BA)

        static let success = SwiftUI.Color(hex: 0x2E7D4F)
        static let warning = SwiftUI.Color(hex: 0xB7791F)
        static let error = SwiftUI.Color(hex: 0xC0392B)

        static let border = SwiftUI.Color(hex: 0xDCE6E8)
    }

    /// 4pt-grid baseline (Material convention).
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16   // base unit
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        static let xxxl: CGFloat = 64
    }

    enum Size {
        /// HIG minimum, also clears WCAG.
        static let tapTargetMin: CGFloat = 44
        static let buttonHeightStandard: CGFloat = 50
        static let buttonHeightCompact: CGFloat = 44

        static let iconSmall: CGFloat = 20
        static let iconMedium: CGFloat = 24
        static let iconLarge: CGFloat = 32

        static let cornerRadiusSmall: CGFloat = 8
        static let cornerRadiusMedium: CGFloat = 12
        static let cornerRadiusLarge: CGFloat = 20
        /// Bumped from `cornerRadiusLarge` specifically for the collage
        /// artwork tile, per the confirmed Design Tokens revision.
        static let cornerRadiusArtwork: CGFloat = 16

        static let borderWidthStandard: CGFloat = 1
    }
}

extension SwiftUI.Color {
    /// `0xRRGGBB` convenience initializer so `DesignTokens.Color` can read
    /// as the same hex values documented in CLAUDE.md, not hand-converted
    /// RGB components that would be easy to transcribe wrong.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
