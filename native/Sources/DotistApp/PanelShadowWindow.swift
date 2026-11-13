import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class PanelShadowWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // The shadow margin must be free to extend under the menu bar and past screen
    // edges; AppKit's default constraint would push it away from its parent.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// Child windows follow parent translations before AppKit updates their reported frame.
struct ChildFramePlacement: Equatable {
    let offset: CGPoint
    let size: CGSize
    let parentSize: CGSize

    init(child: CGRect, parent: CGRect) {
        offset = CGPoint(x: child.minX - parent.minX, y: child.minY - parent.minY)
        size = child.size
        parentSize = parent.size
    }
}

enum DotistShadow {
    case panel, compact, inline
    var blur: CGFloat { switch self { case .panel: 18; case .compact: 16; case .inline: 12 } }
    var y: CGFloat { switch self { case .panel: 6; case .compact: 5; case .inline: 4 } }
    func opacity(dark: Bool) -> Float {
        switch self { case .panel: dark ? 0.25 : 0.14; case .compact: dark ? 0.24 : 0.10; case .inline: dark ? 0.28 : 0.14 }
    }
}

/// The even-odd mask removes every shadow pixel beneath the glass surface.
@MainActor
final class PanelShadowController {
    static let margin: CGFloat = 48
    let window: PanelShadowWindow
    private weak var parent: DotistPanel?
    private weak var motion: PanelMotion?
    private let ambient = CALayer(), cutout = CAShapeLayer()
    private var observers: [NSObjectProtocol] = []
    private(set) var displayLink: CADisplayLink?
    private var target: PanelShadowDisplayTarget?
    private var stopped = false
    private var motionObservation: AnyCancellable?
    private var tabRects: [CGRect] = [] // Relative to the parent frame, in screen coordinates.
    private struct LayerInputs: Equatable {
        let size: CGSize, rect: CGRect
        let radius: CGFloat, dark: Bool, compactProgress: CGFloat, alpha: CGFloat
        let hideShadow: Bool
        let tabs: [CGRect]
    }
    private var lastLayerInputs: LayerInputs?
    private var lastPlacement: ChildFramePlacement?
    private var lastParentOrigin: CGPoint?
    private var frameVerification: DispatchWorkItem?
    private var wasTransitioning = false
    enum TransitionBehavior {
        case baseline
        case continuousSmooth
        case smoothReappear
    }
    var transitionBehavior: TransitionBehavior?
    var effectiveTransitionBehavior: TransitionBehavior { transitionBehavior ?? .smoothReappear }
    private var reveal: CGFloat = 0, revealStart: CGFloat = 0, revealTarget: CGFloat = 0
    private var revealBegan: CFTimeInterval = 0
    private var lastHover = false
    private var presence: CGFloat = 1, presenceStart: CGFloat = 1, presenceTarget: CGFloat = 1
    private var presenceBegan: CFTimeInterval = 0, presenceDuration: CFTimeInterval = 0
    private var transitionAnchorRight = true
    private var transitionAnchorOffset: CGPoint = .zero
    private var wasParentVisible = false
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }
    var forcedCanAnimateVisibility: Bool?
    var shadowAlphaFraction: CGFloat { presence }
    var isPresenceAnimating: Bool { presence != presenceTarget }

    static let transitionFadeOutDuration: CFTimeInterval = 0.06
    static let transitionFadeInDuration: CFTimeInterval = 0.22

    static func frame(for frame: NSRect) -> NSRect { frame.insetBy(dx: -margin, dy: -margin) }

    func setTabRects(_ rects: [CGRect]) {
        guard !stopped, tabRects != rects else { return }
        tabRects = rects
        synchronize()
    }

    static func silhouette(rect: CGRect, radius: CGFloat, tabs: [CGRect]) -> CGPath {
        var outline = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
        for tab in tabs {
            let shape = SideTabShape(inward: false).path(in: tab).cgPath
            // Preserve the painted outer corners, extending only the square edge.
            let bridge = CGRect(x: tab.maxX - 1, y: tab.minY,
                                width: max(1, rect.minX - tab.maxX + 2), height: tab.height)
            outline = outline.union(shape.union(CGPath(rect: bridge, transform: nil)))
        }
        return outline
    }

    init(parent: DotistPanel, motion: PanelMotion) {
        self.parent = parent; self.motion = motion
        window = PanelShadowWindow(contentRect: Self.frame(for: parent.frame), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
        window.isMovable = false; window.hidesOnDeactivate = false
        window.collectionBehavior = parent.collectionBehavior; window.level = parent.level
        let view = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        view.wantsLayer = true
        let root = view.layer!
        root.backgroundColor = NSColor.clear.cgColor
        root.addSublayer(ambient)
        cutout.fillRule = .evenOdd; root.mask = cutout
        window.contentView = view
        parent.addChildWindow(window, ordered: .below)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didMiniaturizeNotification, NSWindow.willStartLiveResizeNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self, weak motion] _ in
                MainActor.assumeIsolated {
                    guard let self, let motion else { return }
                    // PanelMotion synchronizes after publishing the matching insets.
                    if motion.animationInProgress && (name == NSWindow.didMoveNotification || name == NSWindow.didResizeNotification) { return }
                    self.synchronize(verifyFrame: name == NSWindow.didResizeNotification || name == NSWindow.didChangeScreenNotification)
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        let target = PanelShadowDisplayTarget(self); self.target = target
        displayLink = parent.displayLink(target: target, selector: #selector(PanelShadowDisplayTarget.tick(_:)))
        displayLink?.isPaused = true
        displayLink?.add(to: .main, forMode: .common)
        motionObservation = motion.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.motion?.animationInProgress != true else { return }
                self.synchronize()
            }
        }
        synchronize()
    }

    func synchronize(verifyFrame: Bool = false) {
        synchronize(verifyFrame: verifyFrame, at: clock())
    }

    func synchronize(verifyFrame: Bool = false, at now: CFTimeInterval, animateVisibility: Bool? = nil) {
        if QAPerf.enabled { QAPerf.count(.shadowSynchronize) }
        guard !stopped, let parent, let motion else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let canAnimateVisibility = animateVisibility ?? forcedCanAnimateVisibility ?? (!reduceMotion && parent.isVisible && parent.screen != nil)
        if motion.hovering != lastHover {
            revealStart = reveal; revealTarget = motion.hovering ? 1 : 0
            revealBegan = now; lastHover = motion.hovering
        }
        if reduceMotion { reveal = revealTarget }
        else {
            let progress = min(1, max(0, (now - revealBegan) / 0.26))
            reveal = revealStart + (revealTarget - revealStart) * PanelFrameAnimation.easedProgress(CGFloat(progress))
        }
        let compact = motion.bubble, transitioning = motion.animationInProgress
        let behavior = effectiveTransitionBehavior
        let suppressTransitionShadow = behavior == .smoothReappear
        func stepPresence() {
            if !canAnimateVisibility || presenceDuration <= 0 {
                presence = presenceTarget
                return
            }
            let elapsed = now - presenceBegan
            if elapsed >= presenceDuration {
                presence = presenceTarget
                return
            }
            let raw = min(1, max(0, CGFloat(elapsed / presenceDuration)))
            let eased = PanelFrameAnimation.easedProgress(raw)
            presence = presenceStart + (presenceTarget - presenceStart) * eased
        }
        func startPresence(to targetValue: CGFloat, duration: CFTimeInterval) {
            if !canAnimateVisibility || duration <= 0 {
                presence = targetValue; presenceStart = targetValue; presenceTarget = targetValue
                presenceBegan = now; presenceDuration = 0
                return
            }
            if presenceTarget != targetValue {
                presenceStart = presence
                presenceTarget = targetValue
                presenceBegan = now
                presenceDuration = duration * Double(abs(targetValue - presence))
            }
        }
        if suppressTransitionShadow && transitioning {
            if !wasTransitioning {
                wasTransitioning = true
                transitionAnchorRight = compact || motion.bubbleOnRight
                let anchorX = transitionAnchorRight ? (window.frame.maxX - parent.frame.maxX) : (window.frame.minX - parent.frame.minX)
                transitionAnchorOffset = CGPoint(x: anchorX, y: window.frame.maxY - parent.frame.maxY)
                startPresence(to: 0, duration: Self.transitionFadeOutDuration)
            }
            stepPresence()
            window.alphaValue = parent.alphaValue * presence
            if presence > 0 {
                let desiredX = transitionAnchorRight
                    ? (parent.frame.maxX + transitionAnchorOffset.x - window.frame.width)
                    : (parent.frame.minX + transitionAnchorOffset.x)
                let desiredY = parent.frame.maxY + transitionAnchorOffset.y - window.frame.height
                let desiredOrigin = CGPoint(x: desiredX, y: desiredY)
                if window.frame.origin != desiredOrigin { window.setFrameOrigin(desiredOrigin) }
            }
            let parentShown = parent.isVisible && !parent.isMiniaturized
            if parentShown {
                wasParentVisible = true
                if !window.isVisible { window.order(.below, relativeTo: parent.windowNumber) }
            } else {
                wasParentVisible = false
                if window.isVisible { window.orderOut(nil) }
                presence = 0; presenceStart = 0; presenceTarget = 0; presenceDuration = 0
                window.alphaValue = 0
            }
            displayLink?.isPaused = !(parentShown && presence != presenceTarget)
            return
        }
        let landedFromSuppression = suppressTransitionShadow && wasTransitioning && !transitioning
        let newlyVisible = parent.isVisible && !parent.isMiniaturized && !wasParentVisible
        if landedFromSuppression {
            // Keep current presence (typically 0) until target geometry and cutout mask align below.
            presenceTarget = presence
        }
        let tabs = compact || transitioning ? [] : tabRects
        let parentBounds = CGRect(origin: .zero, size: parent.frame.size)
        let silhouetteBounds = tabs.reduce(parentBounds) { $0.union($1) }
        let scale = max(1, parent.backingScaleFactor)
        func pixelCeil(_ value: CGFloat) -> CGFloat { ceil(max(0, value) * scale) / scale }
        let left = pixelCeil(-silhouetteBounds.minX)
        let bottom = pixelCeil(-silhouetteBounds.minY)
        let right = pixelCeil(silhouetteBounds.maxX - parentBounds.maxX)
        let top = pixelCeil(silhouetteBounds.maxY - parentBounds.maxY)
        let frame = CGRect(x: parent.frame.minX - Self.margin - left, y: parent.frame.minY - Self.margin - bottom,
                           width: parent.frame.width + 2 * Self.margin + left + right,
                           height: parent.frame.height + 2 * Self.margin + bottom + top)
        let placement = ChildFramePlacement(child: frame, parent: parent.frame)
        let mustVerify = verifyFrame || (wasTransitioning && !transitioning) || (parent.isVisible && !window.isVisible)
        wasTransitioning = transitioning
        let translated = lastParentOrigin != parent.frame.origin
        lastParentOrigin = parent.frame.origin
        if placement == lastPlacement && !mustVerify && translated {
            frameVerification?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.synchronize(verifyFrame: true) }
            frameVerification = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else if placement != lastPlacement || mustVerify {
            if placement != lastPlacement || window.frame != frame { if QAPerf.enabled { QAPerf.count(.shadowSetFrame) }; window.setFrame(frame, display: false) }
            lastPlacement = placement
        }
        if window.level != parent.level { window.level = parent.level }
        if window.collectionBehavior != parent.collectionBehavior { window.collectionBehavior = parent.collectionBehavior }
        let bounds = CGRect(origin: .zero, size: frame.size)
        let accessible = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let inset = accessible ? EdgeInsets() : motion.surfaceInsets
        let width = compact && !transitioning ? min(parent.frame.width, motion.baseWidth + (parent.frame.width - motion.baseWidth) * reveal) : parent.frame.width
        var rect = CGRect(x: Self.margin + left + (motion.bubbleOnRight ? parent.frame.width - width : 0), y: Self.margin + bottom, width: width, height: parent.frame.height)
        rect = CGRect(x: rect.minX + inset.leading, y: rect.minY + inset.bottom,
                      width: max(0, rect.width - inset.leading - inset.trailing), height: max(0, rect.height - inset.top - inset.bottom))
        // Expanded glass sits inside the optical clearance; hug it so no unshadowed band shows.
        let qa = parent.identifier?.rawValue == "dotist.main" && !compact && !transitioning ? QAEdge.flags : []
        let clearance: CGFloat = !accessible && !compact ? GlassSilhouette.expandedInset : 0
        let glassClip: CGFloat = !accessible && compact ? GlassSilhouette.glassClip : 0
        rect = rect.insetBy(dx: clearance + glassClip, dy: clearance + glassClip)
        let transitionProgress = min(1, max(0, motion.surfaceInsets.top / FloatingSurface.compactOpticalInset))
        let radius: CGFloat = compact ? 24 : DotistDesign.windowCornerRadius - clearance
        let visibleRadius = radius - glassClip
        let compactProgress = transitioning ? transitionProgress : (compact ? 1.0 : 0.0)
        let dark = parent.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let localTabs = tabs.map { $0.offsetBy(dx: Self.margin + left, dy: Self.margin + bottom) }
        let inputs = LayerInputs(size: frame.size, rect: rect, radius: visibleRadius, dark: dark, compactProgress: compactProgress, alpha: parent.alphaValue, hideShadow: qa.contains(.noShadow), tabs: localTabs)
        if inputs != lastLayerInputs {
            lastLayerInputs = inputs
            Self.render(ambient: ambient, cutout: cutout, bounds: bounds, rect: rect, radius: visibleRadius, dark: dark, compactProgress: compactProgress, tabs: localTabs, hideShadow: qa.contains(.noShadow))
        }
        if landedFromSuppression {
            startPresence(to: 1, duration: Self.transitionFadeInDuration)
        } else if newlyVisible && behavior != .baseline {
            presence = 0; presenceStart = 0; presenceTarget = 0; presenceDuration = 0
            startPresence(to: 1, duration: Self.transitionFadeInDuration)
        } else if behavior != .baseline {
            startPresence(to: 1, duration: Self.transitionFadeInDuration)
        } else {
            presence = 1; presenceStart = 1; presenceTarget = 1; presenceDuration = 0
        }
        stepPresence()
        let parentShown = parent.isVisible && !parent.isMiniaturized
        if parentShown {
            wasParentVisible = true
            window.alphaValue = parent.alphaValue * presence
            if !window.isVisible { window.order(.below, relativeTo: parent.windowNumber) }
        } else {
            wasParentVisible = false
            if window.isVisible { window.orderOut(nil) }
            presence = 0; presenceStart = 0; presenceTarget = 0; presenceDuration = 0
            window.alphaValue = 0
        }
        let needsHoverTick = reveal != revealTarget && !transitioning
        let needsPresenceTick = presence != presenceTarget
        displayLink?.isPaused = !(parentShown && (needsHoverTick || needsPresenceTick))
    }

    fileprivate static func render(ambient: CALayer, cutout: CAShapeLayer, bounds: CGRect, rect: CGRect, radius: CGFloat, dark: Bool, compactProgress: CGFloat, tabs: [CGRect] = [], hideShadow: Bool = false) {
        if QAPerf.enabled { QAPerf.count(.shadowRender) }
        let outline = silhouette(rect: rect, radius: radius, tabs: tabs)
        let mask = CGMutablePath(); mask.addRect(bounds); mask.addPath(outline)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cutout.frame = bounds; cutout.path = mask
        ambient.frame = bounds; ambient.backgroundColor = NSColor.clear.cgColor
        ambient.shadowColor = NSColor.black.cgColor; ambient.shadowPath = outline
        let panel = DotistShadow.panel, compact = DotistShadow.compact
        let t = compactProgress
        ambient.shadowRadius = panel.blur + (compact.blur - panel.blur) * t
        ambient.shadowOffset = CGSize(width: 0, height: -(panel.y + (compact.y - panel.y) * t))
        let opacity = panel.opacity(dark: dark) + (compact.opacity(dark: dark) - panel.opacity(dark: dark)) * Float(t)
        ambient.shadowOpacity = hideShadow ? 0 : opacity
        CATransaction.commit()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        frameVerification?.cancel(); frameVerification = nil
        motionObservation = nil
        displayLink?.invalidate(); displayLink = nil; target = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        parent?.removeChildWindow(window)
        window.orderOut(nil); window.close()
    }
}

@MainActor
private final class PanelShadowDisplayTarget: NSObject {
    weak var controller: PanelShadowController?
    init(_ controller: PanelShadowController) { self.controller = controller }
    @objc func tick(_ link: CADisplayLink) {
        guard let controller else { link.invalidate(); return }
        controller.synchronize()
    }
}

@MainActor
final class ViewsShadowController {
    let window: PanelShadowWindow
    private weak var parent: NSWindow?
    private let ambient = CALayer(), cutout = CAShapeLayer()
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var fullScreen = false, stopped = false
    private let cornerRadius: CGFloat
    private let usesOpticalClearance: Bool
    private let accessibleCornerRadius: CGFloat?

    static func silhouette(size: CGSize, accessible: Bool) -> (rect: CGRect, radius: CGFloat) {
        let clearance = accessible ? 0 : GlassSilhouette.expandedInset
        return (CGRect(x: PanelShadowController.margin, y: PanelShadowController.margin, width: size.width, height: size.height).insetBy(dx: clearance, dy: clearance), DotistDesign.windowCornerRadius - clearance)
    }
    init(parent: NSWindow, cornerRadius: CGFloat = DotistDesign.windowCornerRadius, usesOpticalClearance: Bool = true, accessibleCornerRadius: CGFloat? = nil) {
        self.parent = parent
        self.cornerRadius = cornerRadius; self.usesOpticalClearance = usesOpticalClearance
        self.accessibleCornerRadius = accessibleCornerRadius
        window = PanelShadowWindow(contentRect: PanelShadowController.frame(for: parent.frame), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
        window.isMovable = false; window.hidesOnDeactivate = false
        let view = NSView(frame: NSRect(origin: .zero, size: window.frame.size)); view.wantsLayer = true
        view.layer?.addSublayer(ambient); cutout.fillRule = .evenOdd; view.layer?.mask = cutout
        window.contentView = view
        parent.addChildWindow(window, ordered: .below)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didMiniaturizeNotification, NSWindow.willStartLiveResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { if note.name == NSWindow.didExitFullScreenNotification { self?.fullScreen = false }; self?.synchronize() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fullScreen = true; self?.synchronize() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronize() }
        })
        appearanceObservation = parent.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.synchronize() }
        }
        synchronize()
    }
    func synchronize() {
        guard !stopped, let parent else { return }
        let frame = PanelShadowController.frame(for: parent.frame)
        if window.frame != frame { window.setFrame(frame, display: false) }
        window.level = parent.level; window.collectionBehavior = parent.collectionBehavior; window.alphaValue = parent.alphaValue
        let accessible = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let clearance = !accessible && usesOpticalClearance ? GlassSilhouette.expandedInset : 0
        let rect = CGRect(x: PanelShadowController.margin, y: PanelShadowController.margin, width: parent.frame.width, height: parent.frame.height).insetBy(dx: clearance, dy: clearance)
        let radius = accessible ? (accessibleCornerRadius ?? cornerRadius) : cornerRadius - clearance
        let shape = (rect: rect, radius: max(0, radius))
        let dark = parent.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        PanelShadowController.render(ambient: ambient, cutout: cutout, bounds: CGRect(origin: .zero, size: frame.size), rect: shape.rect, radius: shape.radius, dark: dark, compactProgress: 0)
        if parent.isVisible && !parent.isMiniaturized && !fullScreen && !parent.styleMask.contains(.fullScreen) {
            if !window.isVisible { window.order(.below, relativeTo: parent.windowNumber) }
        } else if window.isVisible { window.orderOut(nil) }
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        appearanceObservation = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll(); parent?.removeChildWindow(window); window.orderOut(nil); window.close()
    }
    deinit { MainActor.assumeIsolated { stop() } }
}
