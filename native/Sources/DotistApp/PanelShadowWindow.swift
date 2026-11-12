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

/// The even-odd mask removes every shadow pixel beneath the glass surface.
@MainActor
final class PanelShadowController {
    static let margin: CGFloat = 48
    fileprivate enum Style {
        static let expandedBlur: CGFloat = 24, compactBlur: CGFloat = 10
        static let lightOpacity: Float = 0.20, darkOpacity: Float = 0.36
    }
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
        let frame: CGRect, rect: CGRect
        let radius: CGFloat, dark: Bool, compact: Bool, alpha: CGFloat
        let tabs: [CGRect]
    }
    private var lastLayerInputs: LayerInputs?
    private var reveal: CGFloat = 0, revealStart: CGFloat = 0, revealTarget: CGFloat = 0
    private var revealBegan: CFTimeInterval = 0
    private var lastHover = false

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
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.synchronize() }
            })
        }
        let target = PanelShadowDisplayTarget(self); self.target = target
        displayLink = parent.displayLink(target: target, selector: #selector(PanelShadowDisplayTarget.tick(_:)))
        displayLink?.isPaused = true
        displayLink?.add(to: .main, forMode: .common)
        motionObservation = motion.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.synchronize() }
        }
        synchronize()
    }

    func synchronize() {
        guard !stopped, let parent, let motion else { return }
        let now = CACurrentMediaTime()
        if motion.hovering != lastHover {
            revealStart = reveal; revealTarget = motion.hovering ? 1 : 0
            revealBegan = now; lastHover = motion.hovering
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { reveal = revealTarget }
        else {
            let progress = min(1, max(0, (now - revealBegan) / 0.26))
            reveal = revealStart + (revealTarget - revealStart) * PanelFrameAnimation.easedProgress(CGFloat(progress))
        }
        displayLink?.isPaused = !(motion.animationInProgress || reveal != revealTarget || parent.inLiveResize)
        let compact = motion.bubble, transitioning = motion.animationInProgress
        let tabs = compact || transitioning ? [] : tabRects
        let screenTabs = tabs.map { $0.offsetBy(dx: parent.frame.minX, dy: parent.frame.minY) }
        let silhouetteBounds = screenTabs.reduce(parent.frame) { $0.union($1) }
        let scale = max(1, parent.backingScaleFactor)
        func pixelCeil(_ value: CGFloat) -> CGFloat { ceil(max(0, value) * scale) / scale }
        let left = pixelCeil(parent.frame.minX - silhouetteBounds.minX)
        let bottom = pixelCeil(parent.frame.minY - silhouetteBounds.minY)
        let right = pixelCeil(silhouetteBounds.maxX - parent.frame.maxX)
        let top = pixelCeil(silhouetteBounds.maxY - parent.frame.maxY)
        let frame = CGRect(x: parent.frame.minX - Self.margin - left, y: parent.frame.minY - Self.margin - bottom,
                           width: parent.frame.width + 2 * Self.margin + left + right,
                           height: parent.frame.height + 2 * Self.margin + bottom + top)
        if window.frame != frame { window.setFrame(frame, display: false) }
        if window.level != parent.level { window.level = parent.level }
        if window.collectionBehavior != parent.collectionBehavior { window.collectionBehavior = parent.collectionBehavior }
        window.alphaValue = parent.alphaValue
        let bounds = CGRect(origin: .zero, size: frame.size)
        let accessible = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let inset = accessible ? EdgeInsets() : motion.surfaceInsets
        let width = compact && !transitioning ? min(parent.frame.width, motion.baseWidth + (parent.frame.width - motion.baseWidth) * reveal) : parent.frame.width
        var rect = CGRect(x: parent.frame.minX - frame.minX + (motion.bubbleOnRight ? parent.frame.width - width : 0), y: parent.frame.minY - frame.minY, width: width, height: parent.frame.height)
        rect = CGRect(x: rect.minX + inset.leading, y: rect.minY + inset.bottom,
                      width: max(0, rect.width - inset.leading - inset.trailing), height: max(0, rect.height - inset.top - inset.bottom))
        // Expanded glass sits inside the optical clearance; hug it so no unshadowed band shows.
        let clearance = !accessible && !compact && !transitioning ? ExpandedReadingMaterial.opticalClearance : 0
        rect = rect.insetBy(dx: clearance, dy: clearance)
        let transitionProgress = min(1, max(0, motion.surfaceInsets.top / FloatingSurface.compactOpticalInset))
        let radius = transitioning ? DotistDesign.windowCornerRadius + (24 - DotistDesign.windowCornerRadius) * transitionProgress : (compact ? 24 : DotistDesign.windowCornerRadius - clearance)
        let dark = parent.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let localTabs = screenTabs.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        let inputs = LayerInputs(frame: frame, rect: rect, radius: radius, dark: dark, compact: compact, alpha: parent.alphaValue, tabs: localTabs)
        if inputs != lastLayerInputs {
            lastLayerInputs = inputs
            Self.render(ambient: ambient, cutout: cutout, bounds: bounds, rect: rect, radius: radius, dark: dark, compact: compact, tabs: localTabs)
        }
        if parent.isVisible && !parent.isMiniaturized {
            if !window.isVisible { window.order(.below, relativeTo: parent.windowNumber) }
        } else if window.isVisible { window.orderOut(nil) }
    }

    fileprivate static func render(ambient: CALayer, cutout: CAShapeLayer, bounds: CGRect, rect: CGRect, radius: CGFloat, dark: Bool, compact: Bool, tabs: [CGRect] = []) {
        let outline = silhouette(rect: rect, radius: radius, tabs: tabs)
        let mask = CGMutablePath(); mask.addRect(bounds); mask.addPath(outline)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cutout.frame = bounds; cutout.path = mask
        ambient.frame = bounds; ambient.backgroundColor = NSColor.clear.cgColor
        ambient.shadowColor = NSColor.black.cgColor; ambient.shadowPath = outline
        ambient.shadowRadius = compact ? Style.compactBlur : Style.expandedBlur
        ambient.shadowOffset = CGSize(width: 0, height: compact ? -3 : -8)
        ambient.shadowOpacity = dark ? Style.darkOpacity : Style.lightOpacity
        CATransaction.commit()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
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

    static func silhouette(size: CGSize, accessible: Bool) -> (rect: CGRect, radius: CGFloat) {
        let clearance = accessible ? 0 : ExpandedReadingMaterial.opticalClearance
        return (CGRect(x: PanelShadowController.margin, y: PanelShadowController.margin, width: size.width, height: size.height).insetBy(dx: clearance, dy: clearance), DotistDesign.windowCornerRadius - clearance)
    }
    init(parent: NSWindow) {
        self.parent = parent
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
        let shape = Self.silhouette(size: parent.frame.size, accessible: accessible)
        let dark = parent.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        PanelShadowController.render(ambient: ambient, cutout: cutout, bounds: CGRect(origin: .zero, size: frame.size), rect: shape.rect, radius: shape.radius, dark: dark, compact: false)
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
