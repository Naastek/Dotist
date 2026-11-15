import SwiftUI

/// The native editor stays outside the effect graph; only this sibling backdrop is glass.
struct DotistInputBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var horizontalOutset: CGFloat = 0
    var verticalOutset: CGFloat = 0
    func body(content: Content) -> some View {
        content.background {
            Color.clear.dotistGlass(.regular.tint(DotistTheme.tint(.none, scheme)), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, -horizontalOutset).padding(.vertical, -verticalOutset)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
