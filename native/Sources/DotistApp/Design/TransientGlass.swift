import DotistCore
import SwiftUI

/// Shared material strengths. These preserve the existing appearance and settings
/// while keeping optical glass, tint density and accessibility fallback distinct.
enum GlassTintMaterial {
    static let accessibilityTint = 0.08
    static let compactTintScale = 1.0 / 3
    static let compactDarkProtection = 0.4
    static let expandedLightTint = 0.16
    static let expandedDarkTint = 0.18
    static let expandedFrostScale = 0.12
    static let tabUnselectedTint = 0.06
    static let tabSelectedTint = 0.30
    static let tabHighContrastSelectedTint = 0.42
}

/// One native optical surface for small floating controls and lifted content.
/// Window tint density and frost preferences belong to the expanded reading surface; they
/// must not be stacked over transient glass or fade its contrast and light edge.
struct TransientGlassSurface: View {
    let cornerRadius: CGFloat
    var color: DotistGroupColor = .none
    var interactive = false
    var compact = false
    let solid: Bool
    let scheme: ColorScheme
    var debug: GlassDebugParameters? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if solid {
            // Accessibility requests an intentionally opaque, readable surface.
            shape.fill(DotistDesign.paper)
                .overlay(shape.fill(DotistTheme.swatch(color).opacity(GlassTintMaterial.accessibilityTint)))
        } else if let debug {
            GlassDebugOpticalSurface(parameters: debug, color: color, scheme: scheme)
        } else {
            // One native glass surface; compact ink needs a contrast-bearing
            // backing in dark appearance and a reflection independent of focus.
            let tint = color == .none ? nil : DotistTheme.tint(color, scheme).opacity(compact ? GlassTintMaterial.compactTintScale : 1)
            Color.clear
                .glassEffect(Glass.regular.tint(tint)
                    .interactive(compact ? false : interactive), in: shape)
                .overlay {
                    if compact && scheme == .dark {
                        shape.fill(.black.opacity(GlassTintMaterial.compactDarkProtection)).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .overlay {
                    if compact { CompactGlassHighlights(cornerRadius: cornerRadius) }
                }
        }
    }
}

/// Directional reflections only: the native glass remains the optical body.
struct CompactGlassHighlights: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let light = LinearGradient(stops: [
            .init(color: .white.opacity(0.85), location: 0),
            .init(color: .white.opacity(0.55), location: 0.20),
            .init(color: .white.opacity(0.04), location: 0.52),
            .init(color: .white.opacity(0.12), location: 0.78),
            .init(color: .white.opacity(0.38), location: 1)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
        ZStack {
            shape.strokeBorder(light, lineWidth: 1.25)
            shape.inset(by: 2).strokeBorder(light.opacity(0.38), lineWidth: 4)
                .blur(radius: 2)
                .clipShape(shape)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
