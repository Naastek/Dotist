import DotistCore
import SwiftUI

/// One native optical surface for small floating controls and lifted content.
/// Window paper/frost preferences belong to the expanded reading surface; they
/// must not be stacked over transient glass or fade its contrast and light edge.
struct TransientGlassSurface: View {
    let cornerRadius: CGFloat
    var color: DotistGroupColor = .none
    var interactive = false
    let solid: Bool
    let scheme: ColorScheme
    var debug: GlassDebugParameters? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if solid {
            // Accessibility requests an intentionally opaque, readable surface.
            shape.fill(DotistDesign.paper)
                .overlay(shape.fill(DotistTheme.swatch(color).opacity(0.08)))
        } else if let debug {
            GlassDebugOpticalSurface(parameters: debug, color: color, scheme: scheme)
        } else {
            Color.clear
                .glassEffect(.regular.tint(color == .none ? nil : DotistTheme.tint(color, scheme))
                    .interactive(interactive), in: shape)
        }
    }
}

struct TransientGlassMaterial: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TransientGlassSurface(cornerRadius: cornerRadius,
            solid: reduceTransparency || contrast == .increased, scheme: scheme)
    }
}
