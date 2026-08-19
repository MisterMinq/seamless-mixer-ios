import SwiftUI
import UIKit

/// Auto-generated collage artwork for a mix with no single cover of its
/// own — up to 4 distinct albums' artwork tiled 2x2, per the confirmed
/// design (CLAUDE.md's "Real Apple Music Reference Screens" note: "Apple
/// tiles 4 of its tracks' artwork into a grid... good pattern for this
/// app's generated seamless playlists too"). Andy's own direct request,
/// 2026-08-20, with real Apple Music sampler screenshots as reference.
///
/// Fewer than 4 distinct albums (a small or single-artist mix) fills the
/// remaining quadrants with the same flat placeholder every other artwork
/// tile in this app already uses, rather than inventing a separate
/// 1/2/3-image layout — keeps this component simple and its behavior
/// predictable at any pool size.
///
/// Deliberately sizes via `GeometryReader` rather than an `.aspectRatio`
/// on a `LazyVGrid` — the two real call sites (Playlist Detail's full-
/// width header, My Mixes' small per-row thumbnail) need genuinely
/// different sizes, so this view just fills whatever frame its caller
/// gives it and splits that space into four equal quadrants, no implicit
/// sizing behavior to fight.
struct CollageArtworkView: View {
    /// Up to 4 images, in the order they should fill quadrants
    /// (top-left, top-right, bottom-left, bottom-right) — see
    /// `ArtworkResolver.distinctAlbumImages(from:limit:)` for how callers
    /// build this list.
    let images: [UIImage]

    var body: some View {
        GeometryReader { geo in
            let tileWidth = geo.size.width / 2
            let tileHeight = geo.size.height / 2
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    quadrant(0, width: tileWidth, height: tileHeight)
                    quadrant(1, width: tileWidth, height: tileHeight)
                }
                HStack(spacing: 0) {
                    quadrant(2, width: tileWidth, height: tileHeight)
                    quadrant(3, width: tileWidth, height: tileHeight)
                }
            }
        }
    }

    @ViewBuilder
    private func quadrant(_ index: Int, width: CGFloat, height: CGFloat) -> some View {
        Group {
            if index < images.count {
                Image(uiImage: images[index])
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    DesignTokens.Color.surfaceTint
                    Image(systemName: "music.note")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.primaryText)
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }
}
