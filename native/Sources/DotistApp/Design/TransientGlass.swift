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
                    if compact { GlassEdge(cornerRadius: cornerRadius, compact: true, scheme: scheme) }
                }
        }
    }
}

/// A thin directional reflection and a confined inner light. Neither
/// layer paints the interior or changes the native window shadow.
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

        func interpolated(to other: Profile, fraction: CGFloat) -> Profile {
            let t = Double(fraction)
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
            return Profile(highlight: mix(highlight, other.highlight), secondary: mix(secondary, other.secondary),
                line: CGFloat(mix(Double(line), Double(other.line))), innerLight: mix(innerLight, other.innerLight),
                innerWidth: CGFloat(mix(Double(innerWidth), Double(other.innerWidth))),
                blur: CGFloat(mix(Double(blur), Double(other.blur))))
        }
    }

    private func profile(width: CGFloat) -> Profile {
        let dark = scheme == .dark
        let ball = Profile(highlight: dark ? 0.78 : 0.68, secondary: dark ? 0.18 : 0.12,
            line: 1.0, innerLight: dark ? 0.22 : 0.18, innerWidth: 3.0, blur: 1.2)
        let strip = Profile(highlight: dark ? 0.72 : 0.62, secondary: dark ? 0.16 : 0.10,
            line: 0.9, innerLight: dark ? 0.19 : 0.15, innerWidth: 2.5, blur: 1.0)
        if compact { return ball.interpolated(to: strip, fraction: min(1, max(0, (width - 48) / 192))) }
        return Profile(highlight: dark ? 0.58 : 0.48, secondary: dark ? 0.12 : 0.08,
            line: 0.8, innerLight: dark ? 0.14 : 0.11, innerWidth: 2.0, blur: 1.0)
    }

    var body: some View {
        GeometryReader { geometry in
            let p = profile(width: geometry.size.width)
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let light = LinearGradient(stops: [
                .init(color: .white.opacity(p.highlight), location: 0),
                .init(color: .white.opacity(p.highlight * 0.55), location: 0.20),
                .init(color: .white.opacity(0.015), location: 0.55),
                .init(color: .white.opacity(p.secondary), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            let innerLight = LinearGradient(stops: [.init(color: .white.opacity(p.innerLight), location: 0),
                .init(color: .clear, location: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
            ZStack {
                shape.inset(by: 1).strokeBorder(innerLight, lineWidth: p.innerWidth)
                    .blur(radius: p.blur)
                    .clipShape(shape)
                shape.strokeBorder(light, lineWidth: p.line)
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
