import AppKit
import CoreText
import DotistCore
import SwiftUI

struct FloatingSurface: View, Animatable {
    static let compactOpticalInset: CGFloat = 2
    static let expandedOpticalClearance: CGFloat = 2
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
        let inner = (!compact && !reduceTransparency && !increasedContrast) ? expandedOpticalClearance : 0
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
    var material: DotistPanelMaterial = .regular
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
        let expandedRadius = solid ? DotistDesign.windowCornerRadius : DotistDesign.windowCornerRadius - expandedOpticalClearance
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
        let surfaceMaterial = FloatingPanelMaterial(material: material, compact: compact, color: color,
                                                    cornerRadius: radius, transitioning: transitioning)
            .padding(opticalInset)
            .frame(width: width, height: size.height)
            .frame(width: size.width, height: size.height, alignment: onRight ? .topTrailing : .topLeading)
        surfaceMaterial.modifier(FloatingSurfaceClipping(
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

/// Floating task surfaces take their tint and native glass style from the model.
struct FloatingPanelMaterial: View {
    var material: DotistPanelMaterial = .regular
    let compact: Bool
    let color: DotistGroupColor
    var cornerRadius: CGFloat? = nil
    var transitioning: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        FloatingPanelSurface(material: material, compact: compact, color: color,
                             solid: reduceTransparency || contrast == .increased, scheme: scheme,
                             cornerRadius: cornerRadius, transitioning: transitioning)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: color)
    }
}

/// Resolved material inputs also let previews inspect the opaque accessibility surface.
struct FloatingPanelSurface: View {
    @Environment(\.glassDebugParameters) private var glassDebug
    var material: DotistPanelMaterial = .regular
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
            let inset: CGFloat = compact ? 0 : FloatingSurface.expandedOpticalClearance
            let radius = cornerRadius ?? (compact ? 24 : DotistDesign.windowCornerRadius - inset)
            NativeFloatingGlass(cornerRadius: radius, compact: compact, material: material, color: color, scheme: scheme)
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

/// Native two-tier glass profile for the expanded floating panel.
/// - `.clear`: crystal-clear Liquid Glass droplet (`NSGlassEffectView.Style.clear`).
/// - `.regular`: macOS native adaptive frosted glass (`NSGlassEffectView.Style.regular`),
///   automatically adjusting blur and contrast against the content behind the window.
struct ExpandedGlassProfile: Equatable {
    let glassStyle: NSGlassEffectView.Style
    let tintAlpha: Double
    let maskInsetPt: CGFloat
    let maskFeatherPt: CGFloat

    static func resolve(material: DotistPanelMaterial, dark: Bool, hasGroupColor: Bool) -> ExpandedGlassProfile {
        switch material {
        case .clear:
            return ExpandedGlassProfile(
                glassStyle: .clear,
                tintAlpha: hasGroupColor ? (dark ? 0.10 : 0.08) : 0.0,
                maskInsetPt: 1.75,
                maskFeatherPt: 10.0
            )
        case .regular:
            return ExpandedGlassProfile(
                glassStyle: .regular,
                tintAlpha: hasGroupColor ? (dark ? GlassTintMaterial.expandedDarkTint : GlassTintMaterial.expandedLightTint) : 0.0,
                maskInsetPt: 1.75,
                maskFeatherPt: 10.0
            )
        }
    }
}

/// One system `NSGlassEffectView` persists through the panel's three geometries.
/// Compact forms always render with `.clear` crystal Liquid Glass, while the
/// expanded panel switches directly between `.clear` and `.regular` native glass
/// without stacking a separate `NSVisualEffectView` or manual wash plane.
private struct NativeFloatingGlass: NSViewRepresentable {
    let cornerRadius: CGFloat
    let compact: Bool
    let material: DotistPanelMaterial
    let color: DotistGroupColor
    let scheme: ColorScheme

    final class GlassView: NSGlassEffectView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            style = .clear
            if #available(macOS 27.0, *) {
                // Guard with dynamic selector check so macOS 26 SDK (CI runner) compiles cleanly
                // while macOS 27+ runtimes still enable interactive Liquid Glass response.
                let selector = NSSelectorFromString("setEffectIsInteractive:")
                if responds(to: selector) {
                    setValue(true, forKey: "effectIsInteractive")
                }
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
    // 1. `glassView` (`NSGlassEffectView`): `.clear` or `.regular` live WindowServer Liquid Glass
    // 2. `pigmentView` (`washLayer` + `tintLayer`): hover-strip readability veil and optional group tint
    final class HostView: NSView {
        let glassView = GlassView()
        let pigmentView = PigmentView()

        var radius: CGFloat = 0 {
            didSet { if radius != oldValue { needsLayout = true } }
        }
        var compact: Bool = false {
            didSet { if compact != oldValue { needsLayout = true } }
        }
        var isDark: Bool = false {
            didSet { if isDark != oldValue { needsLayout = true } }
        }
        var material: DotistPanelMaterial = .regular {
            didSet { if material != oldValue { updateAppearance() } }
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
                // 100% pure crystal .clear Liquid Glass droplet: zero milky wash.
                glassView.alphaValue = 1.0
                pigmentView.washLayer.backgroundColor = NSColor.clear.cgColor
                pigmentView.tintLayer.backgroundColor = NSColor.clear.cgColor
            } else if isStrip {
                // Hover capsule: independent of expanded panel material; full .clear glass + airy text veil.
                updateInteriorMask(insetPt: 2.5, featherPt: 6.0)
                glassView.alphaValue = 1.0
                let stripWashAlpha: Double = isDark ? 0.22 : 0.14
                let neutral = NSColor(GlassTintMaterial.neutral(isDark ? .dark : .light)).withAlphaComponent(stripWashAlpha)
                pigmentView.washLayer.backgroundColor = neutral.cgColor
                let stripTintAlpha: Double = groupColor == .none ? 0.0 : (isDark ? 0.05 : 0.04)
                pigmentView.tintLayer.backgroundColor = NSColor(DotistTheme.swatch(groupColor)).withAlphaComponent(stripTintAlpha).cgColor
            } else {
                // Expanded panel: native `.clear` or `.regular` Liquid Glass without manual wash or NSVisualEffectView.
                let profile = ExpandedGlassProfile.resolve(
                    material: material,
                    dark: isDark,
                    hasGroupColor: groupColor != .none
                )
                glassView.alphaValue = 1.0
                pigmentView.washLayer.backgroundColor = NSColor.clear.cgColor
                if profile.tintAlpha > 0 {
                    updateInteriorMask(insetPt: profile.maskInsetPt, featherPt: profile.maskFeatherPt)
                    pigmentView.tintLayer.backgroundColor = NSColor(DotistTheme.swatch(groupColor)).withAlphaComponent(profile.tintAlpha).cgColor
                } else {
                    pigmentView.tintLayer.backgroundColor = NSColor.clear.cgColor
                }
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
        let targetStyle: NSGlassEffectView.Style = (compact || material == .clear) ? .clear : .regular
        if view.glassView.cornerRadius != cornerRadius { view.glassView.cornerRadius = cornerRadius }
        if view.glassView.style != targetStyle { view.glassView.style = targetStyle }
        let tintScale: Double = compact ? GlassTintMaterial.compactTintScale : 1.0
        let materialTint = color == .none ? nil : NSColor(DotistTheme.tint(color, scheme).opacity(tintScale))
        if view.glassView.tintColor != materialTint { view.glassView.tintColor = materialTint }

        view.radius = cornerRadius
        view.compact = compact
        view.isDark = scheme == .dark
        view.material = material
        view.groupColor = color
        view.updateAppearance()
    }
}

