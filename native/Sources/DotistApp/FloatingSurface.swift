import AppKit
import CoreText
import DotistCore
import SwiftUI

// QA diagnostics are cached once at launch and enabled only for the QA bundle.
struct QAEdge: OptionSet {
    let rawValue: UInt8
    static let noShadow = Self(rawValue: 1 << 0), noEdge = Self(rawValue: 1 << 1)
    static let noGlass = Self(rawValue: 1 << 2), noPaper = Self(rawValue: 1 << 3)
    static let fullMask = Self(rawValue: 1 << 4), noRim = Self(rawValue: 1 << 5)
    static let cutout1 = Self(rawValue: 1 << 7)
    static let flags: Self = {
        guard Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa",
              let value = ProcessInfo.processInfo.environment["DOTIST_QA_EDGE"] else { return [] }
        let names: [String: Self] = ["noshadow": .noShadow, "noedge": .noEdge, "noglass": .noGlass,
            "nopaper": .noPaper, "fullmask": .fullMask, "norim": .noRim, "cutout1": .cutout1]
        return value.split(separator: ",").reduce(into: Self()) { result, name in
            result.formUnion(names[name.trimmingCharacters(in: .whitespacesAndNewlines)] ?? [])
        }
    }()
}

private struct QAEdgeEnvironmentKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var qaMainPanel: Bool {
        get { self[QAEdgeEnvironmentKey.self] }
        set { self[QAEdgeEnvironmentKey.self] = newValue }
    }
}

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
            // its optical edge clipped by the shared glass helper.
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
    @Environment(\.qaMainPanel) private var qaMainPanel
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
                let qa: QAEdge = qaMainPanel ? QAEdge.flags : []
                let clippedGlass = Color.clear.dotistGlass(.regular.tint(DotistTheme.tint(color, scheme)), in: opticalShape)
                    .padding(ExpandedReadingMaterial.opticalClearance)
                ZStack {
                    if !qa.contains(.noGlass) {
                        if qa.contains(.fullMask) || glassAlpha >= 0.999 {
                            clippedGlass
                        } else if qa.contains(.noRim) {
                            clippedGlass.mask { Color.white.opacity(glassAlpha) }
                        } else {
                            clippedGlass.mask {
                                Color.white.overlay {
                                    ExpandedReadingMaterial.interiorMask(cornerRadius: radius)
                                        .padding(ExpandedReadingMaterial.opticalClearance)
                                        .opacity(1 - glassAlpha)
                                        .blendMode(.destinationOut)
                                }.compositingGroup()
                            }
                        }
                    }
                    if !qa.contains(.noPaper) {
                        ExpandedReadingMaterial(opacity: opacity, frost: frost, color: color, scheme: scheme, cornerRadius: radius)
                            .applyingBackgroundOpacity(amount)
                            .opacity(idleContentOpacity)
                            .padding(ExpandedReadingMaterial.opticalClearance)
                    }
                    GlassGloss(shape: opticalShape.inset(by: GlassSilhouette.glassClip), intensity: .expanded, scheme: scheme)
                        .padding(ExpandedReadingMaterial.opticalClearance)
                    if !qa.contains(.noEdge) {
                        GlassEdge(cornerRadius: radius, compact: false, scheme: scheme, color: color)
                            .padding(ExpandedReadingMaterial.opticalClearance)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DotistDesign.windowCornerRadius, style: .continuous).inset(by: GlassSilhouette.expandedInset))
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
        let paper: Color = scheme == .light ? .white : DotistDesign.paper
        return ZStack {
            shape.fill(paper.opacity(DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false) * amount))
            shape.fill(paper.opacity(Double(frost) / 100 * GlassTintMaterial.expandedFrostScale * amount))
            shape.fill(GlassTintMaterial.themeWash(color, scheme).opacity(amount))
        }
        .dotistGlassInterior(in: shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

