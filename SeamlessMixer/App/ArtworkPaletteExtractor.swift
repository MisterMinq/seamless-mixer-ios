import CoreImage
import SwiftUI
import UIKit

/// A plain RGB color (0...1 per channel), used instead of `SwiftUI.Color`
/// wherever a palette needs to be blended or measured — `Color` has no
/// built-in interpolation or luminance API, and round-tripping through
/// `UIColor` to get one on every crossfade tick would be needless overhead
/// for what's just three `Double`s.
struct RGBColor: Equatable {
    var r: Double
    var g: Double
    var b: Double

    var color: Color { Color(red: r, green: g, blue: b) }

    /// Standard relative-luminance weighting (same formula already used
    /// for this project's static design-token contrast checks, per
    /// CLAUDE.md's Design Tokens section) — used to decide light-vs-dark
    /// text on top of a blended background.
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    static func lerp(_ a: RGBColor, _ b: RGBColor, t: Double) -> RGBColor {
        let t = min(max(t, 0), 1)
        return RGBColor(
            r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t
        )
    }

    /// Blends toward black by `amount` (0...1) — used to darken a raw
    /// extracted color into something a background can actually sit
    /// behind white text on, matching the deep, muted tone real Apple
    /// Music's own dynamic background uses (confirmed against Andy's own
    /// reference screenshots, 2026-08-18), not the brighter, more
    /// saturated tone a raw average color usually comes out as.
    func darkened(by amount: Double) -> RGBColor {
        RGBColor.lerp(self, RGBColor(r: 0, g: 0, b: 0), t: amount)
    }

    /// Raises saturation to at least `minimum` (0...1), leaving hue and
    /// brightness untouched — added 2026-08-21, Testing (51): Andy reported
    /// the dynamic background looking like "the same old colour scheme"
    /// across five very different real album covers (a vivid red Boney
    /// James cover, a pastel orange/teal Kenny Pore cover, a bold red
    /// Michael Jackson cover, all producing near-identical muted teal-to-
    /// brown results). Root cause: `CIAreaAverage` averages every pixel in
    /// half the image into one flat value, and averaging many different
    /// real-photo colors together reliably regresses toward a muddy
    /// brown/gray, regardless of how vivid the source art actually is --
    /// this is why real apps that extract a "dominant color" this way
    /// always re-saturate afterward rather than using the raw average.
    /// Routes through `UIColor`'s own HSB conversion rather than
    /// hand-rolling the RGB<->HSB math, since that's a well-tested,
    /// standard API already available (`ArtworkPaletteExtractor` already
    /// imports UIKit).
    func saturationBoosted(to minimum: CGFloat = 0.55) -> RGBColor {
        let uiColor = UIColor(red: r, green: g, blue: b, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation < minimum else { return self }

        let boosted = UIColor(hue: hue, saturation: minimum, brightness: brightness, alpha: 1)
        var newR: CGFloat = 0, newG: CGFloat = 0, newB: CGFloat = 0, newA: CGFloat = 0
        boosted.getRed(&newR, green: &newG, blue: &newB, alpha: &newA)
        return RGBColor(r: Double(newR), g: Double(newG), b: Double(newB))
    }
}

/// Extracts two representative colors from a track's album artwork, for
/// Now Playing's dynamic background (per CLAUDE.md's confirmed design,
/// finally built 2026-08-18 after real reference screenshots from Andy
/// confirmed the direction: a single dominant, darkened tone per track,
/// not a busy multi-hue mesh).
///
/// **Deliberately cheap, not pixel-accurate.** Real "dominant color"
/// extraction usually means k-means clustering over the image's pixels —
/// meaningfully more code and risk for a background that's going to be
/// blurred/blended anyway. This uses Core Image's `CIAreaAverage` filter
/// (a standard, well-documented technique for "average color of a region")
/// over the artwork's left and right halves separately, which in practice
/// gives two usefully different tones for most real album art without any
/// clustering logic at all.
enum ArtworkPaletteExtractor {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// `nil` when the image can't be read at all (e.g. corrupt data) —
    /// callers fall back to the app's own teal, same as every other
    /// artwork-derived UI in this app falls back to a flat placeholder.
    static func extractPalette(from image: UIImage) -> (primary: RGBColor, secondary: RGBColor)? {
        guard let ciImage = CIImage(image: image) else { return nil }
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let leftHalf = CGRect(x: extent.minX, y: extent.minY, width: extent.width / 2, height: extent.height)
        let rightHalf = CGRect(x: extent.midX, y: extent.minY, width: extent.width / 2, height: extent.height)

        guard let primary = averageColor(of: ciImage, in: leftHalf),
              let secondary = averageColor(of: ciImage, in: rightHalf) else { return nil }

        // Saturation-boosted, then darkened for legibility -- see
        // `RGBColor.saturationBoosted(to:)`/`.darkened(by:)`'s own doc
        // comments. Boosting first, then darkening, keeps the real hue
        // vivid before it's pushed toward black -- darkening a muddy,
        // under-saturated average first would have nothing worth
        // preserving by the time it's dark enough to sit behind text.
        return (
            primary.saturationBoosted().darkened(by: 0.45),
            secondary.saturationBoosted().darkened(by: 0.45)
        )
    }

    private static func averageColor(of image: CIImage, in rect: CGRect) -> RGBColor? {
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return RGBColor(r: Double(pixel[0]) / 255, g: Double(pixel[1]) / 255, b: Double(pixel[2]) / 255)
    }
}
