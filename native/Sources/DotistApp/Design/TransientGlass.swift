import DotistCore
import SwiftUI

/// Shared material strengths. These preserve the existing appearance and settings
/// while keeping optical glass, tint density and accessibility fallback distinct.
enum GlassTintMaterial {
    static let accessibilityTint = 0.08
    static let compactTintScale = 1.0 / 3
    static let compactDensity = 0.53
    static let expandedLightTint = 0.16
    static let expandedDarkTint = 0.18
    static let expandedFrostScale = 0.12
    static let tabUnselectedTint = 0.06
    static let tabSelectedTint = 0.30
    static let tabHighContrastSelectedTint = 0.42

    /// The neutral pigment is shared by the compact glaze and reading backing.
    static func neutral(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
                        : Color(red: 249 / 255, green: 249 / 255, blue: 250 / 255)
    }
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
            let tint = color == .none ? nil : DotistTheme.tint(color, scheme).opacity(compact ? GlassTintMaterial.compactTintScale : 1)
            if compact {
                FloatingGlassBackdrop()
                    .overlay(shape.fill(tint ?? .clear))
                    .overlay {
                        shape.fill(GlassTintMaterial.neutral(scheme).opacity(GlassTintMaterial.compactDensity))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .clipShape(shape)
                    .overlay { GlassEdge(cornerRadius: cornerRadius, compact: true, scheme: scheme) }
                    .overlay { GlassContour(cornerRadius: cornerRadius, scheme: scheme) }
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

/// Crisp, focus-invariant hairline outer contour that defines the thin optical
/// glass silhouette cleanly against warm light and dark desktops.
struct GlassContour: View {
    let cornerRadius: CGFloat
    let scheme: ColorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = scheme == .dark
        let contour = LinearGradient(stops: dark ? [
            .init(color: .black.opacity(0.24), location: 0),
            .init(color: .black.opacity(0.36), location: 0.5),
            .init(color: .black.opacity(0.42), location: 1)
        ] : [
            .init(color: .black.opacity(0.06), location: 0),
            .init(color: .black.opacity(0.16), location: 0.22),
            .init(color: .black.opacity(0.20), location: 0.50),
            .init(color: .black.opacity(0.16), location: 0.82),
            .init(color: .black.opacity(0.12), location: 1)
        ], startPoint: .top, endPoint: .bottom)
        shape.strokeBorder(contour, lineWidth: 0.6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Unified, focus-invariant taut specular rim reflection shared by the floating
/// button, hover strip, and expanded task card. Pure white pigment with a clear
/// center and tight inner falloff seated cleanly inside `GlassContour`.
struct GlassEdge: View {
    let cornerRadius: CGFloat
    let compact: Bool
    let scheme: ColorScheme

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

        func interpolated(to other: Profile, fraction: CGFloat) -> Profile {
            let t = Double(fraction)
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
            return Profile(
                highlight: mix(highlight, other.highlight),
                secondary: mix(secondary, other.secondary),
                line: CGFloat(mix(Double(line), Double(other.line))),
                innerLight: mix(innerLight, other.innerLight),
                innerWidth: CGFloat(mix(Double(innerWidth), Double(other.innerWidth))),
                blur: CGFloat(mix(Double(blur), Double(other.blur))),
                rimTop: mix(rimTop, other.rimTop),
                rimBottom: mix(rimBottom, other.rimBottom),
                rimSide: mix(rimSide, other.rimSide),
                rimLine: CGFloat(mix(Double(rimLine), Double(other.rimLine))),
                rimInnerTop: mix(rimInnerTop, other.rimInnerTop),
                rimInnerBottom: mix(rimInnerBottom, other.rimInnerBottom),
                rimInnerWidth: CGFloat(mix(Double(rimInnerWidth), Double(other.rimInnerWidth))),
                rimBlur: CGFloat(mix(Double(rimBlur), Double(other.rimBlur)))
            )
        }
    }

    private func profile(width: CGFloat) -> Profile {
        let dark = scheme == .dark
        let ball = Profile(
            highlight: dark ? 0.46 : 0.52, secondary: dark ? 0.08 : 0.08,
            line: 0.75, innerLight: dark ? 0.14 : 0.18, innerWidth: 1.6, blur: 0.8,
            rimTop: dark ? 0.62 : 0.96, rimBottom: dark ? 0.46 : 0.90,
            rimSide: dark ? 0.06 : 0.10, rimLine: 1.0,
            rimInnerTop: dark ? 0.62 : 0.70, rimInnerBottom: dark ? 0.14 : 0.26,
            rimInnerWidth: 2.35, rimBlur: 1.0
        )
        let strip = Profile(
            highlight: dark ? 0.44 : 0.50, secondary: dark ? 0.08 : 0.08,
            line: 0.75, innerLight: dark ? 0.13 : 0.16, innerWidth: 1.6, blur: 0.8,
            rimTop: dark ? 0.60 : 0.96, rimBottom: dark ? 0.44 : 0.90,
            rimSide: dark ? 0.06 : 0.10, rimLine: 1.0,
            rimInnerTop: dark ? 0.60 : 0.68, rimInnerBottom: dark ? 0.14 : 0.24,
            rimInnerWidth: 2.35, rimBlur: 1.0
        )
        if compact { return ball.interpolated(to: strip, fraction: min(1, max(0, (width - 48) / 192))) }
        return Profile(
            highlight: dark ? 0.40 : 0.46, secondary: dark ? 0.07 : 0.07,
            line: 0.75, innerLight: dark ? 0.12 : 0.16, innerWidth: 1.8, blur: 0.9,
            rimTop: dark ? 0.60 : 0.96, rimBottom: dark ? 0.46 : 0.90,
            rimSide: dark ? 0.05 : 0.09, rimLine: 1.0,
            rimInnerTop: dark ? 0.34 : 0.48, rimInnerBottom: dark ? 0.19 : 0.31,
            rimInnerWidth: 2.55, rimBlur: 1.0
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let p = profile(width: geometry.size.width)
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let insetShape = shape.inset(by: 0.5)
            let light = LinearGradient(stops: [
                .init(color: .white.opacity(p.highlight), location: 0),
                .init(color: .white.opacity(p.highlight * 0.55), location: 0.20),
                .init(color: .white.opacity(compact ? p.secondary : 0.015), location: 0.55),
                .init(color: .white.opacity(p.secondary), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            let innerLight = LinearGradient(stops: [
                .init(color: .white.opacity(p.innerLight), location: 0),
                .init(color: .clear, location: 0.45)
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
                shape.inset(by: 1.2).strokeBorder(innerLight, lineWidth: p.innerWidth)
                    .blur(radius: p.blur)
                    .clipShape(insetShape)
                insetShape.strokeBorder(light, lineWidth: p.line)
                shape.inset(by: 1.2).strokeBorder(verticalInner, lineWidth: p.rimInnerWidth)
                    .blur(radius: p.rimBlur)
                    .clipShape(insetShape)
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
