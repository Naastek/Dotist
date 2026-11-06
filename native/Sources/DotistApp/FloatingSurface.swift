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
        if compact && !transitioning && !reduceTransparency && contrast != .increased {
            // The native material owns its shape at the animated width. Leave
            // its optical edge unmasked; no second glass/paint layer.
            material
        } else {
            // Preserve the exact opaque/expanded silhouette, including pixel
            // rounding at fractional hover widths, for window alpha/shadows.
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
            Group {
                if solid {
                    DotistDesign.paper
                } else {
                    Color.clear.glassEffect(.regular.tint(DotistTheme.tint(color, scheme)), in: shape)
                        .overlay(tintDensityLayer)
                }
            }
            .overlay(DotistTheme.swatch(color).opacity(solid ? GlassTintMaterial.accessibilityTint : (scheme == .dark ? GlassTintMaterial.expandedDarkTint : GlassTintMaterial.expandedLightTint)))
            .overlay {
                if !solid { GlassEdge(cornerRadius: DotistDesign.windowCornerRadius, compact: false, scheme: scheme) }
            }
            .opacity(solid ? 1 : DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false))
            .clipShape(shape)
        }
    }

    private var tintDensityLayer: some View {
        DotistDesign.paper.opacity(DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false))
            .overlay(DotistDesign.paper.opacity(Double(frost) / 100 * GlassTintMaterial.expandedFrostScale))
    }
}

