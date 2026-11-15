import DotistCore

import SwiftUI
import AppKit

struct TaskRowActionBacking: View {
    let color: DotistGroupColor
    let scheme: ColorScheme
    let opaque: Bool
    var keyboardFocused = false
    var body: some View {
        Group {
            if opaque {
                Capsule().fill(DotistDesign.paper)
                    .overlay(Capsule().strokeBorder(keyboardFocused ? DotistDesign.accent : DotistDesign.rule, lineWidth: 1))
            } else {
                Color.clear.dotistGlass(.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(keyboardFocused ? DotistDesign.accent.opacity(0.65) : Color.clear, lineWidth: 0.5))
            }
        }.clipShape(Capsule()).allowsHitTesting(false).accessibilityHidden(true)
    }
}
