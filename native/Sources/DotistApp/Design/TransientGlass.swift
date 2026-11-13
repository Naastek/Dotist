import DotistCore
import SwiftUI

enum GlassSilhouette {
    /// One physical pixel inside the shape. Measured with an HDR capture on an XDR display:
    /// the system glass's dark hairline and pale halo lie just outside the shape, and its
    /// own extended-range specular rim (brighter than SDR white, about 1.35x) lies just
    /// inside. Inset 1 removes every XDR highlight and the glass looks dull; inset 0 keeps a
    /// pixel darker than the fill at the boundary; 0.5 removes that pixel and keeps the gloss.
    static let glassClip: CGFloat = 0.5
    static let expandedInset: CGFloat = ExpandedReadingMaterial.opticalClearance + glassClip
}

extension View {
    // System glass paints a dark hairline and pale halo at its outer boundary; see
    // GlassSilhouette.glassClip for why the clip sits half a point inside the shape.
    func dotistGlass<S: InsettableShape>(_ glass: Glass, in shape: S) -> some View {
        glassEffect(glass, in: shape).clipShape(shape.inset(by: GlassSilhouette.glassClip))
    }

    // SDR decoration and reading paint must not cover the native optical rim.
    // Fade them into the interior rather than attenuating the system highlight.
    func dotistGlassInterior<S: InsettableShape>(in shape: S) -> some View {
        mask {
            shape.inset(by: 3).fill(.white).blur(radius: 1)
                .clipShape(shape.inset(by: 1))
        }
    }

    func dotistInlineShadow() -> some View { modifier(DotistInlineShadow()) }
}

private struct DotistInlineShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let tier = DotistShadow.inline
        content.shadow(color: .black.opacity(Double(tier.opacity(dark: scheme == .dark))), radius: tier.blur, y: tier.y)
    }
}

/// Shared material strengths. These preserve the existing appearance and settings
/// while keeping optical glass, tint density and accessibility fallback distinct.
enum GlassTintMaterial {
    static let accessibilityTint = 0.08
    static let expandedLightTint = 0.16
    static let expandedDarkTint = 0.18
    static func themeWash(_ color: DotistGroupColor, _ scheme: ColorScheme) -> Color {
        let strength: Double = scheme == .dark ? expandedDarkTint : expandedLightTint
        return DotistTheme.swatch(color).opacity(strength)
    }

    static let expandedFrostScale = 0.12
    static let tabUnselectedTint = 0.06
    static let tabSelectedTint = 0.30
    static let tabHighContrastSelectedTint = 0.42
}

enum CompactGlassStyle {
    static let tintStrength: Double = 1.0
    enum Tier { case compact, expanded }
    static func specularTop(_ tier: Tier, _ scheme: ColorScheme) -> Double {
        switch tier {
        case .compact: return scheme == .dark ? 0.34 : 0.55   // peak of the partial edge highlight
        case .expanded: return scheme == .dark ? 0.05 : 0.10
        }
    }
    static func innerShade(_ tier: Tier, _ scheme: ColorScheme) -> Double {
        switch tier {
        case .compact: return scheme == .dark ? 0.16 : 0.07
        case .expanded: return 0.03
        }
    }
}

struct GlassGloss<S: InsettableShape>: View {
    let shape: S
    let intensity: CompactGlassStyle.Tier
    let scheme: ColorScheme
    var body: some View {
        Group {
            if intensity == .compact { slab } else { sheen }
        }.dotistGlassInterior(in: shape).allowsHitTesting(false).accessibilityHidden(true)
    }

    /// A clear, flat slab. There is deliberately NO closed line around the shape: any
    /// stroke that runs the whole perimeter reads as an outline, whatever its colour.
    /// Light only touches the two places a slab catches it (top-left, and more faintly
    /// bottom-right) and fades to nothing in between; the fill and the shadow define the edge.
    private var slab: some View {
        let peak: Double = CompactGlassStyle.specularTop(.compact, scheme)
        let arcs = LinearGradient(stops: [
            .init(color: .white.opacity(peak), location: 0),
            .init(color: .white.opacity(0), location: 0.34),
            .init(color: .white.opacity(0), location: 0.74),
            .init(color: .white.opacity(peak * 0.45), location: 1)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
        return ZStack {
            // Soft light spilling a few points inside the lit edges.
            shape.inset(by: 2).strokeBorder(arcs, lineWidth: 5).blur(radius: 3).opacity(0.45)
            // The crisp part stays inside the native optical edge.
            shape.inset(by: 2).strokeBorder(arcs, lineWidth: 1).blur(radius: 0.3)
        }
    }

    /// Large reading surfaces only get a faint light falling from the top edge.
    private var sheen: some View {
        GeometryReader { (geometry: GeometryProxy) in
            let height: CGFloat = min(120, geometry.size.height)
            let specular: Double = CompactGlassStyle.specularTop(.expanded, scheme)
            let shade: Double = CompactGlassStyle.innerShade(.expanded, scheme)
            ZStack(alignment: .top) {
                LinearGradient(stops: [.init(color: .white.opacity(specular), location: 0),
                    .init(color: .clear, location: 0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                shape.strokeBorder(LinearGradient(stops: [.init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(shade), location: 1)],
                    startPoint: .top, endPoint: .bottom), lineWidth: 7).blur(radius: 3.5)
            }
        }
    }
}

/// One native optical surface for small floating controls and lifted content.
/// Window tint density and frost preferences belong to the expanded reading surface; they
/// do not fade compact glass or its contrast and light edge.
struct TransientGlassSurface: View {
    let cornerRadius: CGFloat
    var color: DotistGroupColor = .none
    var interactive = false
    var compact = false
    let solid: Bool
    let scheme: ColorScheme
    var debug: GlassDebugParameters? = nil
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if solid {
            // Accessibility requests an intentionally opaque, readable surface.
            shape.fill(DotistDesign.paper)
                .overlay(shape.fill(DotistTheme.swatch(color).opacity(GlassTintMaterial.accessibilityTint)))
        } else if let debug {
            GlassDebugOpticalSurface(parameters: debug, color: color, scheme: scheme)
        } else if compact {
            opticalSurface(shape: FloatingPanelShape(compact: true, transitioning: false, onRight: false, reveal: 1))
        } else {
            opticalSurface(shape: shape)
        }
    }

    private func opticalSurface<S: InsettableShape>(shape: S) -> some View {
        // The local environment override does not prevent non-key graying.
        let tint = DotistTheme.tint(color, scheme).opacity(CompactGlassStyle.tintStrength)
        return Color.clear
            .dotistGlass(Glass.regular.tint(tint).interactive(compact ? false : interactive), in: shape)
            .environment(\.appearsActive, compact || appearsActive)
            // Keep native reflections exposed: no secondary color wash or black veil.
            .overlay {
                if compact { GlassGloss(shape: shape.inset(by: GlassSilhouette.glassClip), intensity: .compact, scheme: scheme) }
            }
            .overlay {
                if compact { GlassEdge(cornerRadius: cornerRadius, compact: true, scheme: scheme, color: color) }
            }
            .clipShape(shape.inset(by: GlassSilhouette.glassClip))
    }
}

/// A thin directional reflection with a continuous compact rim and a confined
/// inner light. Neither layer paints the interior or changes the window shadow.
struct GlassEdge: View {
    let cornerRadius: CGFloat
    let compact: Bool
    let scheme: ColorScheme
    var color: DotistGroupColor = .none

    static func highlightColor(_ color: DotistGroupColor, _ scheme: ColorScheme) -> Color {
        guard color != .none else { return .white }
        let amount: Double = scheme == .dark ? 0.65 : 0.70
        return Color.white.mix(with: DotistTheme.swatch(color), by: amount)
    }

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
        let highlight = Self.highlightColor(color, scheme)
        return GeometryReader { geometry in
            let p = profile(width: geometry.size.width)
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).inset(by: 2)
            let light = LinearGradient(stops: [
                .init(color: highlight.opacity(p.highlight), location: 0),
                .init(color: highlight.opacity(p.highlight * 0.55), location: 0.20),
                // Zero through the middle: the highlight must never close into an outline.
                .init(color: highlight.opacity(0), location: 0.36),
                .init(color: highlight.opacity(0), location: 0.74),
                .init(color: highlight.opacity(p.secondary), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            let innerLight = LinearGradient(stops: [.init(color: highlight.opacity(p.innerLight), location: 0),
                .init(color: highlight.opacity(0), location: 0.34)], startPoint: .topLeading, endPoint: .bottomTrailing)
            ZStack {
                shape.inset(by: 1).strokeBorder(innerLight, lineWidth: p.innerWidth)
                    .blur(radius: p.blur)
                    .clipShape(shape)
                shape.strokeBorder(light, lineWidth: p.line)
            }
        }
        .dotistGlassInterior(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
