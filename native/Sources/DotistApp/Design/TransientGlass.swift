import DotistCore
import SwiftUI

/// Shared material strengths. These preserve the existing appearance and settings
/// while keeping optical glass, tint density and accessibility fallback distinct.
enum GlassTintMaterial {
    static let accessibilityTint = 0.08
    static let compactTintScale = 1.0 / 3
    static let expandedLightTint = 0.16
    static let expandedDarkTint = 0.18
    static let tabUnselectedTint = 0.06
    static let tabSelectedTint = 0.30
    static let tabHighContrastSelectedTint = 0.42

    /// Calibrated compact glaze density at the optical center so the button and
    /// hover strip transmit warm/neutral desktops with watery liquid-glass depth
    /// while giving crisp pure-white specular rims clear luminance contrast.
    static func compactDensity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.53 : 0.60
    }

    /// The neutral pigment is shared by the compact glaze and reading backing.
    static func neutral(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
                        : .white
    }
}

/// One native optical surface for small floating controls and lifted content.
/// Expanded panel material preferences belong to the main panel surface; they
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
            let tint = color == .none ? nil : DotistTheme.tint(color, scheme).opacity(compact ? GlassTintMaterial.compactTintScale : 1)
            if compact {
                Color.clear
                    .glassEffect(Glass.clear.tint(tint).interactive(interactive), in: shape)
                    .overlay { PhysicalLiquidGlassRim(cornerRadius: cornerRadius, compact: true, scheme: scheme) }
            } else {
                Color.clear.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
            }
        }
    }
}

/// Keep sampling the real desktop even when another app becomes active.
/// Uses `.hudWindow` so neutral and warm desktops transmit cleanly without
/// Aqua's cool blue-gray or green-gray tint shift.
struct FloatingGlassBackdrop: NSViewRepresentable {
    final class Backdrop: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Backdrop {
        let view = Backdrop()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: Backdrop, context: Context) {}
}

/// Curved glass dome glaze for compact floating controls (button and hover strip).
/// Models real convex glass optics: luminous top and bottom specular cushions,
/// a subtle upper-quarter and side-bevel refraction dip, and a softly brightened
/// center-to-lower belly, while preserving `compactDensity` at the optical center.
struct CompactGlassGlaze: View {
    let cornerRadius: CGFloat
    let scheme: ColorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = scheme == .dark
        ZStack {
            if dark {
                shape.fill(GlassTintMaterial.neutral(.dark).opacity(GlassTintMaterial.compactDensity(.dark)))
                shape.fill(LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.015), location: 0.14),
                    .init(color: .black.opacity(0.032), location: 0.26),
                    .init(color: .black.opacity(0.010), location: 0.44),
                    .init(color: .clear, location: 0.58),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom))
                shape.fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.13), location: 0),
                    .init(color: .white.opacity(0.045), location: 0.11),
                    .init(color: .white.opacity(0.00), location: 0.25),
                    .init(color: .white.opacity(0.005), location: 0.50),
                    .init(color: .white.opacity(0.04), location: 0.76),
                    .init(color: .white.opacity(0.09), location: 0.93),
                    .init(color: .white.opacity(0.11), location: 1)
                ], startPoint: .top, endPoint: .bottom))
            } else {
                // Uniform base translucency transmits the desktop warmly without
                // letting dark/mixed backdrops punch a horizontal crease.
                shape.fill(GlassTintMaterial.neutral(.light).opacity(GlassTintMaterial.compactDensity(.light)))
                // Clean, background-independent curved-dome refraction dip in the upper quarter.
                shape.fill(LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.008), location: 0.12),
                    .init(color: .black.opacity(0.022), location: 0.26),
                    .init(color: .black.opacity(0.008), location: 0.44),
                    .init(color: .clear, location: 0.56),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom))
                // Luminous liquid-glass top specular crown and convex lower-belly caustic bounce.
                shape.fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.56), location: 0),
                    .init(color: .white.opacity(0.24), location: 0.10),
                    .init(color: .white.opacity(0.00), location: 0.25),
                    .init(color: .white.opacity(0.00), location: 0.48),
                    .init(color: .white.opacity(0.14), location: 0.70),
                    .init(color: .white.opacity(0.34), location: 0.86),
                    .init(color: .white.opacity(0.52), location: 0.95),
                    .init(color: .white.opacity(0.46), location: 1)
                ], startPoint: .top, endPoint: .bottom))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Crisp, focus-invariant hairline outer contour that defines the thin optical
/// glass silhouette cleanly against white, warm light, and dark desktops.
struct GlassContour: View {
    let cornerRadius: CGFloat
    let scheme: ColorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = scheme == .dark
        let contour = LinearGradient(stops: dark ? [
            .init(color: .black.opacity(0.28), location: 0),
            .init(color: .black.opacity(0.38), location: 0.5),
            .init(color: .black.opacity(0.46), location: 1)
        ] : [
            .init(color: .black.opacity(0.07), location: 0),
            .init(color: .black.opacity(0.12), location: 0.25),
            .init(color: .black.opacity(0.145), location: 0.55),
            .init(color: .black.opacity(0.16), location: 0.88),
            .init(color: .black.opacity(0.14), location: 1)
        ], startPoint: .top, endPoint: .bottom)
        shape.strokeBorder(contour, lineWidth: 0.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Unified, focus-invariant taut specular rim reflection shared by the floating
/// button, hover strip, and expanded task card. Pure white pigment with a clear
/// center and tight inner falloff seated cleanly inside `GlassContour`.
struct GlassEdge: View {
    let cornerRadius: CGFloat
    let scheme: ColorScheme
    var transitioning: Bool = false

    private struct Profile {
        let highlight: Double
        let secondary: Double
        let line: CGFloat
        let innerLight: Double
        let innerWidth: CGFloat
        let blur: CGFloat
        let rimTop: Double
        let rimBottom: Double
        let rimSide: Double
        let rimLine: CGFloat
        let rimInnerTop: Double
        let rimInnerBottom: Double
        let rimInnerWidth: CGFloat
        let rimBlur: CGFloat

    }

    private var profile: Profile {
        let dark = scheme == .dark
        // Unified specular rim profile across button, hover strip, and expanded card
        // so outer thickness, specular width, and edge-to-interior glow stay identical.
        return Profile(
            highlight: dark ? 0.52 : 0.62, secondary: dark ? 0.08 : 0.08,
            line: 0.75, innerLight: dark ? 0.16 : 0.19, innerWidth: dark ? 1.5 : 1.4, blur: dark ? 0.75 : 0.6,
            rimTop: dark ? 0.80 : 1.0, rimBottom: dark ? 0.60 : 0.76,
            rimSide: dark ? 0.14 : 0.26, rimLine: dark ? 1.1 : 1.15,
            rimInnerTop: dark ? 0.58 : 0.58, rimInnerBottom: dark ? 0.24 : 0.22,
            rimInnerWidth: dark ? 2.2 : 2.0, rimBlur: dark ? 1.0 : 0.85
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let p = profile
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let insetShape = shape.inset(by: 0.5)
            let light = LinearGradient(stops: [
                .init(color: .white.opacity(p.highlight), location: 0),
                .init(color: .white.opacity(p.highlight * 0.55), location: 0.20),
                .init(color: .white.opacity(p.secondary), location: 0.55),
                .init(color: .white.opacity(p.secondary), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            let innerLight = LinearGradient(stops: [
                .init(color: .white.opacity(p.innerLight), location: 0),
                .init(color: .white.opacity(0), location: 0.45)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            let falloff = min(0.28, max(cornerRadius * 1.1, 10) / max(1, geometry.size.height))
            let verticalRim = LinearGradient(stops: [
                .init(color: .white.opacity(p.rimTop), location: 0),
                .init(color: .white.opacity(p.rimSide), location: falloff),
                .init(color: .white.opacity(p.rimSide * 0.5), location: 0.5),
                .init(color: .white.opacity(p.rimSide), location: 1 - falloff),
                .init(color: .white.opacity(p.rimBottom), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            let verticalInner = LinearGradient(stops: [
                .init(color: .white.opacity(p.rimInnerTop), location: 0),
                .init(color: .white.opacity(0), location: falloff),
                .init(color: .white.opacity(0), location: 1 - falloff),
                .init(color: .white.opacity(p.rimInnerBottom), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            ZStack {
                if !transitioning {
                    shape.inset(by: 0.8).strokeBorder(innerLight, lineWidth: p.innerWidth)
                        .blur(radius: p.blur)
                        .clipShape(insetShape)
                }
                insetShape.strokeBorder(light, lineWidth: p.line)
                if !transitioning {
                    shape.inset(by: 0.75).strokeBorder(verticalInner, lineWidth: p.rimInnerWidth)
                        .blur(radius: p.rimBlur)
                        .clipShape(insetShape)
                }
                insetShape.strokeBorder(verticalRim, lineWidth: p.rimLine)
            }
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
