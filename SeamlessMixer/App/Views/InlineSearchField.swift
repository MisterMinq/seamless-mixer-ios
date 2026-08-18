import SwiftUI

/// A plain, self-contained search field embedded directly in a screen's own
/// content — deliberately **not** `.searchable()`.
///
/// **Why this exists, 2026-08-18 (real bug, not a style preference).** All
/// five category pickers (Genre/Playlist/Artist/Album/Songs) used
/// `.searchable(text:)` for their own per-category filter box. Andy reported
/// this directly, repeated across every category: "you cannot add the songs
/// to build a mix, because the arrow at the top goes missing as soon as you
/// start typing in the search field... managed to get to the arrow by
/// cancelling the search." This is standard, documented UIKit behavior for
/// a `.searchable()`-backed field on a *pushed* (non-root) navigation
/// screen: the moment the search field becomes active, `UISearchController`
/// takes over the navigation bar and hides the back button, replacing it
/// with its own "Cancel" control — SwiftUI's `.searchable()` inherits this
/// wholesale, it isn't something `.searchable()`'s own parameters can turn
/// off. An earlier fix attempt (Round 26) mistakenly targeted the Hub's own
/// *global* search instead — a different, separate search field entirely —
/// which is why it didn't touch this bug at all.
///
/// Rather than fight `UISearchController`'s behavior, this sidesteps it
/// completely: a plain `TextField` in a rounded-rect background, placed as
/// ordinary content at the top of the screen, never handed to
/// `UISearchController`. The standard back chevron is never touched by
/// search state, active or not — there's nothing here for iOS to hide.
struct InlineSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DesignTokens.Color.textSecondary)
            TextField(prompt, text: $text)
                .foregroundStyle(DesignTokens.Color.textPrimary)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(DesignTokens.Color.surfaceTint)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium))
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}
