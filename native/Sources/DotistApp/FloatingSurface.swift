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
        let material = FloatingPanelMaterial(opacity: opacity, frost: frost, compact: compact, color: color,
                                             cornerRadius: radius, transitioning: transitioning)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        FloatingPanelSurface(opacity: opacity, frost: frost, compact: compact, color: color,
                             solid: reduceTransparency || contrast == .increased, scheme: scheme,
                             cornerRadius: cornerRadius, transitioning: transitioning)
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

    var body: some View {
        if solid {
            let radius = cornerRadius ?? (compact ? 24 : DotistDesign.windowCornerRadius)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape.fill(DotistDesign.paper)
                .overlay(shape.fill(DotistTheme.swatch(color).opacity(GlassTintMaterial.accessibilityTint)))
        } else if compact, let glassDebug {
            GlassDebugOpticalSurface(parameters: glassDebug, color: color, scheme: scheme)
        } else {
            let inset: CGFloat = compact ? 0 : ExpandedReadingMaterial.opticalClearance
            let radius = cornerRadius ?? (compact ? 24 : DotistDesign.windowCornerRadius - inset)
            let amount = DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false)
            NativeFloatingGlass(cornerRadius: radius, compact: compact, color: color, scheme: scheme,
                density: amount, frost: Double(frost) / 100.0)
                .overlay {
                    PhysicalLiquidGlassRim(cornerRadius: radius, compact: compact, scheme: scheme,
                                           transitioning: transitioning)
                }
                .padding(inset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Calibrated orthogonal mapping for the expanded floating panel's
/// transparency (`opacity = 100 - transparency`) and frost sliders.
struct ExpandedGlassCalibration: Equatable {
    let washAlpha: Double
    let glassAlpha: Double
    let frostAlpha: Double
    let tintAlpha: Double
    let maskInsetPt: CGFloat
    let maskFeatherPt: CGFloat

    var showsFrost: Bool { frostAlpha > 0.005 }

    static func resolve(opacity: Double, frost: Double, dark: Bool, hasGroupColor: Bool) -> ExpandedGlassCalibration {
        let d = max(0.0, min(1.0, opacity))
        let f = max(0.0, min(1.0, frost))

        // 1. Neutral backing wash: purely driven by opacity (100 - transparency),
        //    spanning [0, 1] so 0% transparency solidly blocks backdrops while
        //    preserving airy clarity across standard/clear/ultra presets.
        let washAlpha = d < 0.005 ? 0.0 : pow(d, dark ? 1.45 : 1.55)

        // 2. Two-stage behind-window optical diffusion: purely driven by frost (independent of opacity).
        //    - Stage A (`NSGlassEffectView .clear`): 0 at frost=0 (truly crisp clear glass),
        //      ramps to 1.0 by frost=50% so airy presets retain live Liquid Glass refraction.
        //    - Stage B (`NSVisualEffectView`): adds deep Gaussian diffusion across 12%..100%
        //      so 100% frost fully softens dense text & bold stripes.
        let glassAlpha = f < 0.005 ? 0.0 : min(1.0, 0.22 + 1.56 * f)
        let frostAlpha: Double
        if f <= 0.12 {
            frostAlpha = 0.0
        } else {
            frostAlpha = pow((f - 0.12) / 0.88, 1.15)
        }

        // 3. Group tint: follows docs/ui-decisions.md (16% light / 18% dark) scaled by opacity.
        let tintBase = dark ? GlassTintMaterial.expandedDarkTint : GlassTintMaterial.expandedLightTint
        let tintAlpha = hasGroupColor ? tintBase * d : 0.0

        // 4. Dynamic optical rim feathering: keeps a generous refractive bezel on airy settings,
        //    and tightens smoothly as solid wash or heavy frost approaches 100% so edges never leak.
        let coverage = max(washAlpha, frostAlpha)
        let quantized = (coverage * 20.0).rounded() / 20.0
        let maskInsetPt = CGFloat(((1.75 - 1.25 * quantized) * 4.0).rounded() / 4.0)
        let maskFeatherPt = CGFloat(((10.5 - 9.0 * quantized) * 4.0).rounded() / 4.0)

        return ExpandedGlassCalibration(
            washAlpha: washAlpha,
            glassAlpha: glassAlpha,
            frostAlpha: frostAlpha,
            tintAlpha: tintAlpha,
            maskInsetPt: maskInsetPt,
            maskFeatherPt: maskFeatherPt
        )
    }
}

/// One system `.clear` Liquid Glass surface persists through the panel's three geometries.
/// AppKit/WindowServer owns live behind-window refraction and macOS 27 interactive response,
/// while behind-window frost and pigment wash sit in strictly ordered sibling views so
/// opacity (wash/tint) and frost (blur) stay 100% orthogonal without overwriting each other.
private struct NativeFloatingGlass: NSViewRepresentable {
    let cornerRadius: CGFloat
    let compact: Bool
    let color: DotistGroupColor
    let scheme: ColorScheme
    let density: Double
    let frost: Double

    final class GlassView: NSGlassEffectView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            style = .clear
            if #available(macOS 27.0, *) {
                effectIsInteractive = true
            }
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class PigmentView: NSView {
        let washLayer = CALayer()
        let washMaskLayer = CALayer()
        let tintLayer = CALayer()
        let tintMaskLayer = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            washLayer.name = "dotist.wash"
            tintLayer.name = "dotist.tint"
            washLayer.mask = washMaskLayer
            tintLayer.mask = tintMaskLayer
            layer?.addSublayer(washLayer)
            layer?.addSublayer(tintLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            washLayer.frame = bounds
            tintLayer.frame = bounds
            washMaskLayer.frame = bounds
            tintMaskLayer.frame = bounds
            CATransaction.commit()
        }
    }

    // Layered host inside NativeFloatingGlass (bottom -> top):
    // 1. `glassView` (`NSGlassEffectView .clear`): live WindowServer Liquid Glass refraction
    // 2. `frostView` (`NSVisualEffectView .behindWindow`): deep Gaussian frost diffusion
    // 3. `pigmentView` (`washLayer` + `tintLayer`): strictly above frostView so 0% transparency
    //    always blocks backdrops cleanly regardless of frost level.
    final class HostView: NSView {
        let glassView = GlassView()
        let frostView = NSVisualEffectView()
        let frostMaskLayer = CALayer()
        let pigmentView = PigmentView()

        var radius: CGFloat = 0 {
            didSet { if radius != oldValue { needsLayout = true } }
        }
        var compact: Bool = false {
            didSet { if compact != oldValue { needsLayout = true } }
        }
        var isDark: Bool = false {
            didSet {
                if isDark != oldValue {
                    frostView.material = isDark ? .hudWindow : .popover
                    needsLayout = true
                }
            }
        }
        var density: Double = 0.6 {
            didSet { if density != oldValue { updateAppearance() } }
        }
        var frost: Double = 0.4 {
            didSet { if frost != oldValue { updateAppearance() } }
        }
        var groupColor: DotistGroupColor = .none {
            didSet { if groupColor != oldValue { updateAppearance() } }
        }

        private var lastMaskSize: CGSize = .zero
        private var lastMaskRadius: CGFloat = -1
        private var lastMaskCompact: Bool = false
        private var lastMaskInset: CGFloat = -1
        private var lastMaskFeather: CGFloat = -1

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            addSubview(glassView)

            frostView.blendingMode = .behindWindow
            frostView.state = .active
            frostView.material = .popover
            frostView.wantsLayer = true
            frostView.layer?.mask = frostMaskLayer
            addSubview(frostView)

            addSubview(pigmentView)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func updateInteriorMask(insetPt: CGFloat, featherPt: CGFloat) {
            let size = bounds.size
            guard size.width > 1, size.height > 1 else { return }
            let sizeChanged = abs(size.width - lastMaskSize.width) > 0.5 || abs(size.height - lastMaskSize.height) > 0.5
            let geometryChanged = sizeChanged
                || abs(radius - lastMaskRadius) > 0.5
                || compact != lastMaskCompact
                || abs(insetPt - lastMaskInset) > 0.01
                || abs(featherPt - lastMaskFeather) > 0.01
            guard geometryChanged else { return }
            let mask = LiquidGlassOpticsRenderer.featheredInteriorMask(
                size: size, cornerRadius: radius, insetPt: insetPt, featherPt: featherPt, scale: 1.0
            )
            frostMaskLayer.contents = mask
            pigmentView.washMaskLayer.contents = mask
            pigmentView.tintMaskLayer.contents = mask
            lastMaskSize = size
            lastMaskRadius = radius
            lastMaskCompact = compact
            lastMaskInset = insetPt
            lastMaskFeather = featherPt
        }

        override func layout() {
            super.layout()
            let size = bounds.size
            guard size.width > 1, size.height > 1 else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glassView.frame = bounds
            frostView.frame = bounds
            frostMaskLayer.frame = bounds
            pigmentView.frame = bounds
            CATransaction.commit()
            updateAppearance()
        }

        func updateAppearance() {
            let isBubble = compact && bounds.width <= 60
            let isStrip = compact && bounds.width > 60

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            if isBubble {
                // 100% pure crystal .clear Liquid Glass droplet: zero blur slab, zero milky wash.
                glassView.alphaValue = 1.0
                frostView.isHidden = true
                frostView.alphaValue = 0
                pigmentView.washLayer.backgroundColor = NSColor.clear.cgColor
                pigmentView.tintLayer.backgroundColor = NSColor.clear.cgColor
            } else if isStrip {
                // Hover capsule: independent of expanded opacity/frost; full .clear glass + airy text veil.
                updateInteriorMask(insetPt: 2.5, featherPt: 6.0)
                glassView.alphaValue = 1.0
                frostView.isHidden = true
                frostView.alphaValue = 0
                let stripWashAlpha: Double = isDark ? 0.22 : 0.14
                let neutral = NSColor(GlassTintMaterial.neutral(isDark ? .dark : .light)).withAlphaComponent(stripWashAlpha)
                pigmentView.washLayer.backgroundColor = neutral.cgColor
                let stripTintAlpha: Double = groupColor == .none ? 0.0 : (isDark ? 0.05 : 0.04)
                pigmentView.tintLayer.backgroundColor = NSColor(DotistTheme.swatch(groupColor)).withAlphaComponent(stripTintAlpha).cgColor
            } else {
                // Expanded panel: orthogonal full-range opacity wash + two-stage frost + dynamic rim feather.
                let cal = ExpandedGlassCalibration.resolve(
                    opacity: density,
                    frost: frost,
                    dark: isDark,
                    hasGroupColor: groupColor != .none
                )
                updateInteriorMask(insetPt: cal.maskInsetPt, featherPt: cal.maskFeatherPt)

                glassView.alphaValue = CGFloat(cal.glassAlpha)
                frostView.isHidden = !cal.showsFrost
                frostView.alphaValue = CGFloat(cal.frostAlpha)

                let neutral = NSColor(GlassTintMaterial.neutral(isDark ? .dark : .light)).withAlphaComponent(cal.washAlpha)
                pigmentView.washLayer.backgroundColor = neutral.cgColor

                pigmentView.tintLayer.backgroundColor = NSColor(DotistTheme.swatch(groupColor)).withAlphaComponent(cal.tintAlpha).cgColor
            }

            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        if view.glassView.cornerRadius != cornerRadius { view.glassView.cornerRadius = cornerRadius }
        if view.glassView.style != .clear { view.glassView.style = .clear }
        let tintScale: Double = compact ? GlassTintMaterial.compactTintScale : 1.0
        let materialTint = color == .none ? nil : NSColor(DotistTheme.tint(color, scheme).opacity(tintScale))
        if view.glassView.tintColor != materialTint { view.glassView.tintColor = materialTint }

        view.radius = cornerRadius
        view.compact = compact
        view.isDark = scheme == .dark
        view.density = density
        view.frost = frost
        view.groupColor = color
        view.updateAppearance()
    }
}

private struct GlassInteriorPaint<S: Shape>: View {
    let opacity: UInt8
    let frost: UInt8
    let color: DotistGroupColor
    let scheme: ColorScheme
    let shape: S
    var amount: Double = 1

    var body: some View {
        let pigment = GlassTintMaterial.neutral(scheme)
        shape.fill(pigment.opacity(DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false) * amount))
            .overlay(shape.fill(pigment.opacity(Double(frost) / 100 * GlassTintMaterial.expandedFrostScale * amount)))
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

