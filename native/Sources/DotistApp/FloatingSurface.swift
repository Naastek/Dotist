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
    var idleContentOpacity: Double = 1
    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    var body: some View {
        let opticalInset = Self.opticalInsets(compact: compact, reduceTransparency: reduceTransparency,
            increasedContrast: contrast == .increased, frameInsets: frameInsets)
        let material = FloatingPanelMaterial(opacity: opacity, frost: frost, compact: compact, color: color, idleContentOpacity: idleContentOpacity)
            .padding(opticalInset)
            .frame(width: compact && !transitioning ? base + (size.width - base) * min(1, max(0, reveal)) : size.width, height: size.height)
            .frame(width: size.width, height: size.height, alignment: onRight ? .topTrailing : .topLeading)
        if compact && !transitioning && !reduceTransparency && contrast != .increased {
            // The native material owns its shape at the animated width. Leave
            // its optical edge unmasked; no second glass/paint layer.
            material
        } else {
            // Keep the window/transition alpha constrained. Expanded native
            // optics have their own clearance inside this outer silhouette.
            material.clipShape(FloatingPanelShape(compact: compact, transitioning: transitioning,
                onRight: onRight, reveal: reveal, base: base))
        }
    }
}

/// The compact surface uses native glass directly. Expanded reading surfaces
/// retain their independently configured tint density, frost and background opacity.
struct FloatingPanelMaterial: View {
    let opacity: UInt8
    let frost: UInt8
    let compact: Bool
    let color: DotistGroupColor
    var idleContentOpacity: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        FloatingPanelSurface(opacity: opacity, frost: frost, compact: compact, color: color,
                             solid: reduceTransparency || contrast == .increased, scheme: scheme, idleContentOpacity: idleContentOpacity)
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
    var idleContentOpacity: Double = 1

    var body: some View {
        if compact {
            TransientGlassSurface(cornerRadius: 24, color: color, interactive: true, compact: true, solid: solid, scheme: scheme, debug: glassDebug)
        } else {
            let shape = RoundedRectangle(cornerRadius: DotistDesign.windowCornerRadius, style: .continuous)
            if solid {
                shape.fill(DotistDesign.paper)
                    .overlay(shape.fill(DotistTheme.swatch(color).opacity(GlassTintMaterial.accessibilityTint)))
            } else {
                // Preserve the optical rim while adjusting the glass interior and reading backing.
                let radius = DotistDesign.windowCornerRadius - ExpandedReadingMaterial.opticalClearance
                let opticalShape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                let amount = DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false)
                let glassAlpha = ExpandedReadingMaterial.glassInteriorAlpha(opacity: opacity, frost: frost, dark: scheme == .dark)
                let glass = Color.clear.glassEffect(.regular.tint(DotistTheme.tint(color, scheme)), in: opticalShape)
                    .padding(ExpandedReadingMaterial.opticalClearance)
                ZStack {
                    if glassAlpha >= 0.999 {
                        glass
                    } else {
                        glass.mask {
                            Color.white.overlay {
                                ExpandedReadingMaterial.interiorMask(cornerRadius: radius)
                                    .padding(ExpandedReadingMaterial.opticalClearance)
                                    .opacity(1 - glassAlpha)
                                    .blendMode(.destinationOut)
                            }.compositingGroup()
                        }
                    }
                    ExpandedReadingMaterial(opacity: opacity, frost: frost, color: color, scheme: scheme, cornerRadius: radius)
                        .applyingBackgroundOpacity(amount)
                        .opacity(idleContentOpacity)
                        .padding(ExpandedReadingMaterial.opticalClearance)
                    GlassEdge(cornerRadius: radius, compact: false, scheme: scheme)
                        .padding(ExpandedReadingMaterial.opticalClearance)
                }
            }
        }
    }
}

/// A readable backing sharing the native glass silhouette.
/// Internal so tests can measure density independently of native glass alpha.
struct ExpandedReadingMaterial: View {
    static let opticalClearance: CGFloat = 2
    let opacity: UInt8
    let frost: UInt8
    let color: DotistGroupColor
    let scheme: ColorScheme
    let cornerRadius: CGFloat

    static func glassInteriorAlpha(opacity: UInt8, frost: UInt8, dark: Bool) -> Double {
        let amount = DotistDesign.materialOpacity(opacity, dark: dark, highContrast: false)
        return 1 - (1 - Double(frost) / 100) * (1 - amount)
    }

    static func interiorMask(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape.inset(by: 3).fill(.white).blur(radius: 1)
            .clipShape(shape.inset(by: 1))
    }

    var body: some View {
        paint(backgroundOpacity: 1)
    }

    /// Legacy full-background opacity multiplies every paint plane. Applying it
    /// after compositing the planes would change density.
    func applyingBackgroundOpacity(_ amount: Double) -> some View {
        paint(backgroundOpacity: amount)
    }

    private func paint(backgroundOpacity amount: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ZStack {
            shape.fill(DotistDesign.paper.opacity(DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false) * amount))
            shape.fill(DotistDesign.paper.opacity(Double(frost) / 100 * GlassTintMaterial.expandedFrostScale * amount))
            shape.fill(DotistTheme.swatch(color).opacity((scheme == .dark ? GlassTintMaterial.expandedDarkTint : GlassTintMaterial.expandedLightTint) * amount))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

