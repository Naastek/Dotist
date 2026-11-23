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

    var body: some View {
        let opticalInset = Self.opticalInsets(compact: compact, reduceTransparency: reduceTransparency,
            increasedContrast: contrast == .increased, frameInsets: frameInsets)
        let material = FloatingPanelMaterial(opacity: opacity, frost: frost, compact: compact, color: color)
            .padding(opticalInset)
            .frame(width: compact && !transitioning ? base + (size.width - base) * min(1, max(0, reveal)) : size.width, height: size.height)
            .frame(width: size.width, height: size.height, alignment: onRight ? .topTrailing : .topLeading)
        material.modifier(FloatingSurfaceClipping(
            shape: FloatingPanelShape(compact: compact, transitioning: transitioning,
                onRight: onRight, reveal: reveal, base: base),
            clipsSilhouette: !(compact && !transitioning && !reduceTransparency && contrast != .increased)))
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

/// Compact glass has a fixed density. The expanded reading surface responds
/// to tint, frost and background opacity settings.
struct FloatingPanelMaterial: View {
    let opacity: UInt8
    let frost: UInt8
    let compact: Bool
    let color: DotistGroupColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        FloatingPanelSurface(opacity: opacity, frost: frost, compact: compact, color: color,
                             solid: reduceTransparency || contrast == .increased, scheme: scheme)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: color)
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

    var body: some View {
        if compact {
            TransientGlassSurface(cornerRadius: 24, color: color, interactive: true, compact: true, solid: solid, scheme: scheme, debug: glassDebug)
        } else {
            let shape = RoundedRectangle(cornerRadius: DotistDesign.windowCornerRadius, style: .continuous)
            if solid {
                shape.fill(DotistDesign.paper)
                    .overlay(shape.fill(DotistTheme.swatch(color).opacity(GlassTintMaterial.accessibilityTint)))
            } else {
                // Leave room for native optical light inside the window clip.
                // The reading backing owns its shape. Opacity scales every
                // interior plane (native glass, density, frost and tint),
                // while the optical band and reflection keep their strength.
                let radius = DotistDesign.windowCornerRadius - ExpandedReadingMaterial.opticalClearance
                let opticalShape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                let amount = DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false)
                ZStack {
                    ZStack {
                        FloatingGlassBackdrop()
                            .overlay(opticalShape.fill(DotistTheme.tint(color, scheme)))
                            .clipShape(opticalShape)
                        ExpandedReadingMaterial(opacity: opacity, frost: frost, color: color, scheme: scheme, cornerRadius: radius)
                    }
                    .padding(ExpandedReadingMaterial.opticalClearance)
                    .mask {
                        // alpha = 1 at the rim, amount in the interior. Masking the
                        // combined backdrop + reading planes once honors the opacity
                        // budget without double-compounding alpha in the center.
                        Color.white.overlay {
                            ExpandedReadingMaterial.interiorMask(cornerRadius: radius)
                                .padding(ExpandedReadingMaterial.opticalClearance)
                                .opacity(1 - amount)
                                .blendMode(.destinationOut)
                        }.compositingGroup()
                    }
                    LinearGradient(stops: [
                        .init(color: .white.opacity((scheme == .dark ? 0.14 : 0.18) * amount), location: 0),
                        .init(color: .white.opacity(0), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                        .frame(height: scheme == .dark ? 10 : 8)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .clipShape(opticalShape)
                        .padding(ExpandedReadingMaterial.opticalClearance)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    GlassEdge(cornerRadius: radius, compact: false, scheme: scheme)
                        .padding(ExpandedReadingMaterial.opticalClearance)
                    GlassContour(cornerRadius: radius, scheme: scheme)
                        .padding(ExpandedReadingMaterial.opticalClearance)
                }
            }
        }
    }
}

/// A readable interior inside the native optical band. The small feather joins
/// the density backing to glass without introducing a second outlined border.
/// Internal so tests can measure density independently of native glass alpha.
struct ExpandedReadingMaterial: View {
    static let opticalClearance: CGFloat = 2
    private let rimInset: CGFloat = 3
    let opacity: UInt8
    let frost: UInt8
    let color: DotistGroupColor
    let scheme: ColorScheme
    let cornerRadius: CGFloat

    static func interiorMask(cornerRadius: CGFloat, inset: CGFloat = 3) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Confine the feather too: keep the first optical point free of paint.
        return shape.inset(by: inset).fill(.white).blur(radius: 1)
            .clipShape(shape.inset(by: 1))
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
        let pigment = GlassTintMaterial.neutral(scheme)
        return ZStack {
            shape.fill(pigment.opacity(DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false) * amount))
            shape.fill(pigment.opacity(Double(frost) / 100 * GlassTintMaterial.expandedFrostScale * amount))
            shape.fill(DotistTheme.swatch(color).opacity((scheme == .dark ? GlassTintMaterial.expandedDarkTint : GlassTintMaterial.expandedLightTint) * amount))
        }
        .mask {
            Self.interiorMask(cornerRadius: cornerRadius, inset: rimInset)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

