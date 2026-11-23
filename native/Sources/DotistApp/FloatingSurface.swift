import AppKit
import CoreText
import DotistCore
import SwiftUI

struct FloatingSurface: View, Animatable {
    static let compactOpticalInset: CGFloat = 2
    static func opticalInsets(compact: Bool, reduceTransparency: Bool, increasedContrast: Bool,
                              frameInsets: EdgeInsets? = nil) -> EdgeInsets {
        let inset = compact && !reduceTransparency && !increasedContrast ? compactOpticalInset : 0
        let normal = EdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
        return !reduceTransparency && !increasedContrast ? frameInsets ?? normal : normal
    }

    /// Total visible glass inset inside the window frame, combining `opticalInsets`
    /// with `FloatingPanelSurface`'s expanded optical clearance. Both compact and
    /// expanded surfaces occupy the same 2pt-inset visible silhouette in normal mode
    /// and 0pt in accessibility solid mode.
    static func visibleGlassInsets(compact: Bool, reduceTransparency: Bool, increasedContrast: Bool,
                                   frameInsets: EdgeInsets? = nil) -> EdgeInsets {
        let outer = opticalInsets(compact: compact, reduceTransparency: reduceTransparency,
                                  increasedContrast: increasedContrast, frameInsets: frameInsets)
        let inner = (!compact && !reduceTransparency && !increasedContrast) ? ExpandedReadingMaterial.opticalClearance : 0
        return EdgeInsets(top: outer.top + inner, leading: outer.leading + inner,
                          bottom: outer.bottom + inner, trailing: outer.trailing + inner)
    }

    static func outerCornerRadius(for size: CGSize, compact: Bool, transitioning: Bool) -> CGFloat {
        if transitioning {
            let t = min(1, max(0, (min(size.width, size.height) - 48) / 80))
            return 24 + (DotistDesign.windowCornerRadius - 24) * t
        }
        return compact ? 24 : DotistDesign.windowCornerRadius
    }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let opacity: UInt8
    let frost: UInt8
    let compact: Bool
    let transitioning: Bool
    let onRight: Bool
    let size: CGSize
    var reveal: CGFloat
    let color: DotistGroupColor
    var base: CGFloat = 48
    var frameInsets: EdgeInsets? = nil
    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    static func glassCornerRadius(for size: CGSize, compact: Bool, transitioning: Bool, solid: Bool) -> CGFloat {
        let expandedRadius = solid ? DotistDesign.windowCornerRadius : DotistDesign.windowCornerRadius - ExpandedReadingMaterial.opticalClearance
        if transitioning {
            let t = min(1, max(0, (min(size.width, size.height) - 48) / 80))
            return 24 + (expandedRadius - 24) * t
        }
        return compact ? 24 : expandedRadius
    }

    var body: some View {
        let opticalInset = Self.opticalInsets(compact: compact, reduceTransparency: reduceTransparency,
            increasedContrast: contrast == .increased, frameInsets: frameInsets)
        let solid = reduceTransparency || contrast == .increased
        let radius = Self.glassCornerRadius(for: size, compact: compact, transitioning: transitioning, solid: solid)
        let width = compact && !transitioning ? base + (size.width - base) * min(1, max(0, reveal)) : size.width
        let circleBlend = min(1, max(0, (80 - max(width, size.height)) / 32))
        let material = FloatingPanelMaterial(opacity: opacity, frost: frost, compact: compact, color: color,
                                             cornerRadius: radius, transitioning: transitioning, circleBlend: circleBlend)
            .padding(opticalInset)
            .frame(width: width, height: size.height)
            .frame(width: size.width, height: size.height, alignment: onRight ? .topTrailing : .topLeading)
        material.modifier(FloatingSurfaceClipping(
            shape: FloatingPanelShape(compact: compact, transitioning: transitioning,
                onRight: onRight, reveal: reveal, base: base),
            clipsSilhouette: !(compact && !transitioning && !solid)))
    }
}

/// Keep the material's lifetime independent of the transition's clipping policy.
struct FloatingSurfaceClipping: ViewModifier {
    let shape: FloatingPanelShape
    let clipsSilhouette: Bool
    func body(content: Content) -> some View {
        content.clipShape(FloatingSurfaceClipShape(silhouette: shape, clipsSilhouette: clipsSilhouette))
    }
}

struct FloatingSurfaceClipShape: Shape {
    var silhouette: FloatingPanelShape
    let clipsSilhouette: Bool
    var animatableData: CGFloat {
        get { silhouette.animatableData }
        set { silhouette.animatableData = newValue }
    }
    func path(in rect: CGRect) -> Path {
        // Settled compact optics already own their rounded edge and sit 2pt
        // inside these bounds. A rectangular path preserves that edge without
        // moving the native material into a different SwiftUI branch.
        clipsSilhouette ? silhouette.path(in: rect) : Path(rect)
    }
}

/// Floating task surfaces take their tint, frost and opacity from the model.
struct FloatingPanelMaterial: View {
    let opacity: UInt8
    let frost: UInt8
    let compact: Bool
    let color: DotistGroupColor
    var cornerRadius: CGFloat? = nil
    var transitioning: Bool = false
    var circleBlend: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        FloatingPanelSurface(opacity: opacity, frost: frost, compact: compact, color: color,
                             solid: reduceTransparency || contrast == .increased, scheme: scheme,
                             cornerRadius: cornerRadius, transitioning: transitioning, circleBlend: circleBlend)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: color)
    }
}

/// Resolved material inputs also let previews inspect the opaque accessibility surface.
struct FloatingPanelSurface: View {
    @Environment(\.glassDebugParameters) private var glassDebug
    let opacity: UInt8
    let frost: UInt8
    let compact: Bool
    let color: DotistGroupColor
    let solid: Bool
    let scheme: ColorScheme
    var cornerRadius: CGFloat? = nil
    var transitioning: Bool = false
    var circleBlend: CGFloat = 0

    var body: some View {
        if solid {
            let radius = cornerRadius ?? (compact ? 24 : DotistDesign.windowCornerRadius)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape.fill(DotistDesign.paper)
                .overlay(shape.fill(DotistTheme.swatch(color).opacity(GlassTintMaterial.accessibilityTint)))
        } else if compact, let glassDebug {
            GlassDebugOpticalSurface(parameters: glassDebug, color: color, scheme: scheme)
        } else {
            // Keep the backdrop and interior stable while the window resizes.
            // The light circle gets a narrower sheen and extra frost to offset
            // the stronger backdrop color at its curved edge.
            let inset: CGFloat = compact ? 0 : ExpandedReadingMaterial.opticalClearance
            let radius = cornerRadius ?? (compact ? 24 : DotistDesign.windowCornerRadius - ExpandedReadingMaterial.opticalClearance)
            let opticalShape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let amount = DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false)
            let lightCircle = scheme == .light ? Double(circleBlend) : 0
            ZStack {
                ZStack {
                    FloatingGlassBackdrop()
                        .clipShape(opticalShape.inset(by: 0.5))
                    GlassInteriorPaint(opacity: opacity, frost: frost, color: color, scheme: scheme,
                        shape: opticalShape.inset(by: 0.75), frostScale: GlassTintMaterial.expandedFrostScale + 0.25 * lightCircle)
                }
                .opacity(amount)
                .padding(inset)
                FloatingGlassSheen(cornerRadius: radius, scheme: scheme, amount: amount, lightCircle: lightCircle)
                    .padding(inset)
                GlassEdge(cornerRadius: radius, scheme: scheme, transitioning: transitioning)
                    .padding(inset)
                GlassContour(cornerRadius: radius, scheme: scheme)
                    .padding(inset)
            }
            .background {
                CompactGlassLiftShadow(cornerRadius: radius, scheme: scheme)
                    .padding(inset)
            }
        }
    }
}

private struct FloatingGlassSheen: View {
    let cornerRadius: CGFloat
    let scheme: ColorScheme
    let amount: Double
    let lightCircle: Double

    var body: some View {
        GeometryReader { geometry in
            let dark = scheme == .dark
            let height = max(1, Double(geometry.size.height))
            let top = min(0.5, (dark ? 18 : 20 - 10 * lightCircle) / height)
            let bottom = min(0.5, (dark ? 15 : 16) / height)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .inset(by: 0.5)
                .fill(LinearGradient(stops: [
                    .init(color: .white.opacity((dark ? 0.22 : 0.49) * amount), location: 0),
                    .init(color: .white.opacity((dark ? 0.085 : 0.20) * amount), location: top * 0.24),
                    .init(color: .clear, location: top),
                    .init(color: .clear, location: 1 - bottom),
                    .init(color: .white.opacity((dark ? 0.045 : 0.075) * amount), location: 1 - bottom * 0.30),
                    .init(color: .white.opacity((dark ? 0.12 : 0.22) * amount), location: 1)
                ], startPoint: UnitPoint(x: 0.49, y: 0), endPoint: UnitPoint(x: 0.51, y: 1)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GlassInteriorPaint<S: Shape>: View {
    let opacity: UInt8
    let frost: UInt8
    let color: DotistGroupColor
    let scheme: ColorScheme
    let shape: S
    var amount: Double = 1
    var frostScale = GlassTintMaterial.expandedFrostScale

    var body: some View {
        let pigment = GlassTintMaterial.neutral(scheme)
        shape.fill(pigment.opacity(DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false) * amount))
            .overlay(shape.fill(pigment.opacity(Double(frost) / 100 * frostScale * amount)))
            .overlay(shape.fill(DotistTheme.swatch(color).opacity((scheme == .dark ? GlassTintMaterial.expandedDarkTint : GlassTintMaterial.expandedLightTint) * amount)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A readable interior inside the native optical band. Tight 0.75pt feather
/// eliminates the double-rimmed moat at the top-right corner while keeping the
/// outer 0.5pt hairline contour clear of reading pigment.
struct ExpandedReadingMaterial: View {
    static let opticalClearance: CGFloat = 2
    private let rimInset: CGFloat = 0.75
    let opacity: UInt8
    let frost: UInt8
    let color: DotistGroupColor
    let scheme: ColorScheme
    let cornerRadius: CGFloat

    static func interiorMask(cornerRadius: CGFloat, inset: CGFloat = 0.75) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Confine the feather too: keep the outer 0.5pt hairline free of paint.
        return shape.inset(by: inset).fill(.white).blur(radius: 0.45)
            .clipShape(shape.inset(by: 0.5))
    }

    var body: some View {
        paint(backgroundOpacity: 1)
    }

    /// Legacy full-background opacity multiplies every paint plane. Applying it
    /// after the shaped mask would flatten those planes first and change density.
    func applyingBackgroundOpacity(_ amount: Double) -> some View {
        paint(backgroundOpacity: amount)
    }

    private func paint(backgroundOpacity amount: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return GlassInteriorPaint(opacity: opacity, frost: frost, color: color, scheme: scheme, shape: shape, amount: amount)
            .mask {
                Self.interiorMask(cornerRadius: cornerRadius, inset: rimInset)
            }
    }
}

