import SwiftUI

/// A left-to-right, top-to-bottom wrapping layout — items that don't fit the
/// remaining width on the current row start a new row below, growing the
/// container downward, rather than being clipped or requiring horizontal
/// scrolling to reach.
///
/// **Added 2026-08-15**, fixing a real bug on the Source Selection Hub's
/// selected-sources chip row: it was a horizontal `ScrollView`, so picking
/// more sources than fit in one screen-width just scrolled the extra chips
/// off to the side with no visible sign more existed — Andy, testing a real
/// 4-genre/2-album selection: "Above the mode selection where what I had
/// selected was displayed, I can only see Afro-Beat and Gospel. The rest is
/// cut off... Maybe if too many selections are made - to extend the space
/// downward to accommodate selection?" That's exactly what this does: chips
/// wrap onto additional rows instead of scrolling, so every current
/// selection stays visible at a glance without an extra gesture.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth == 0 ? 0 : spacing) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
