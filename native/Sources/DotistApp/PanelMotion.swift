import AppKit
import CoreText
import DotistCore
import SwiftUI

/// All task panels share one motion implementation, with independent window state.
@MainActor
final class PanelMotion: ObservableObject {
    /// Production reads AppKit input and uses the main queue. Offscreen fixtures
    /// supply their own pointer, screen and scheduler instead of sampling the
    /// user's desktop while a transition is awaiting completion.
    struct Environment {
        typealias FrameAnimation = @MainActor (DotistPanel, NSRect, TimeInterval, @escaping @MainActor () -> Void) -> Void
        var now: @MainActor () -> Date = { Date() }
        var mouseLocation: @MainActor () -> NSPoint = { NSEvent.mouseLocation }
        var pressedMouseButtons: @MainActor () -> Int = { Int(NSEvent.pressedMouseButtons) }
        var visibleFrame: @MainActor (DotistPanel) -> NSRect? = { ($0.screen ?? NSScreen.main)?.visibleFrame }
        var schedule: @MainActor (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        var pointerEventsEnabled = true
        var hoverDidFinish: @MainActor (Bool) -> Void = { _ in }
        var frameAnimationDuration: @MainActor (Bool) -> TimeInterval = { compact in
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (compact ? 0.28 : 0.34)
        }
        // nil uses production visibility rules and the edge animation. Only an
        // explicit fixture driver can animate hidden windows without display ticks.
        var animateFrame: FrameAnimation? = nil
    }

    var environment: Environment
    @Published private(set) var idleContentOpacity: Double = 1
    @Published private(set) var bubble = false
    @Published private(set) var surfaceInsets = EdgeInsets()
    @Published private(set) var hovering = false
    @Published var bubbleOnRight = true
    /// Active-filter wording shown beside the collapsed ball (nil for "All").
    var filterLines: [String] = []
    weak var filterState: TaskPanelState?
    var filterExtra: CGFloat {
        guard !filterLines.isEmpty else { return 0 }
        let font = DotistDesign.nativeFont(12, language: model.language)
        let widest = filterLines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return 16 + min(150, ceil(widest))
    }
    var baseWidth: CGFloat { 48 + filterExtra }
    @Published private(set) var animationInProgress = false
    var expandedSize: NSSize
    private(set) var transitionSize: NSSize
    private(set) var hoverAnimating = false
    let panel: DotistPanel
    private let model: AppModel
    private let title: () -> String
    private let bubbleContent: (() -> BubbleContent)?
    private let rememberFrame: (NSRect) -> Void
    private var lastActive: Date
    private var hoverClose: DispatchWorkItem?
    private var pendingHover: Bool?
    private var pendingBubbleToggle = false
    private var hoverRequiresExit = false
    private var bubbleMenuOpen = false
    private var stopped = false
    private var closeObservation: NSObjectProtocol?
    private var frameAnimation: PanelFrameAnimation?
    private(set) var shadowController: PanelShadowController?
    private var insetTransition: PanelSurfaceTransition?
    private var insetObservations: [NSObjectProtocol] = []

    init(model: AppModel, panel: DotistPanel, size: NSSize, title: @escaping () -> String, bubbleContent: (() -> BubbleContent)? = nil, environment: Environment = Environment(), rememberFrame: @escaping (NSRect) -> Void = { _ in }) {
        self.model = model
        self.panel = panel
        self.environment = environment
        lastActive = environment.now()
        expandedSize = size
        transitionSize = size
        self.title = title
        self.bubbleContent = bubbleContent
        self.rememberFrame = rememberFrame
        // Match the bubble throughout the task panel lifecycle; native glass
        // keeps its own optical edge without an extra AppKit window shadow.
        panel.hasShadow = false
        shadowController = PanelShadowController(parent: panel, motion: self)
        closeObservation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            insetObservations.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.stopped, let transition = self.insetTransition else { return }
                    // Publish even when size is unchanged: an anchor-only move
                    // must invalidate FloatingPanelView's observed motion.
                    self.surfaceInsets = transition.insets(at: self.panel.frame)
                    self.shadowController?.synchronize()
                }
            })
        }
    }
    isolated deinit {
        shadowController?.stop()
        frameAnimation?.cancel()
        hoverClose?.cancel()
        if let closeObservation { NotificationCenter.default.removeObserver(closeObservation) }
        insetObservations.forEach { NotificationCenter.default.removeObserver($0) }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        shadowController?.stop(); shadowController = nil
        frameAnimation?.cancel(); frameAnimation = nil
        insetTransition = nil
        insetObservations.forEach { NotificationCenter.default.removeObserver($0) }
        insetObservations.removeAll()
        hoverClose?.cancel(); hoverClose = nil
        pendingHover = nil
        pendingBubbleToggle = false
        hoverAnimating = false
        animationInProgress = false
        if let closeObservation { NotificationCenter.default.removeObserver(closeObservation) }
        closeObservation = nil
    }

    func refreshShadow() {
        guard !stopped else { return }
        shadowController?.synchronize()
        panel.invalidateShadow()
        // SwiftUI may not have committed its glass/tint change until the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.panel.invalidateShadow()
        }
    }

    func toggleBubble() {
        guard let area = environment.visibleFrame(panel) else { return }
        toggleBubble(in: area)
    }

    // A synchronous transition also supports callers without a live display and
    // lets geometry tests exercise the real collapse/expand state changes.
    func toggleBubble(in area: NSRect, animated: Bool = true) {
        guard !stopped, !animationInProgress else { return }
        if hoverAnimating {
            hoverClose?.cancel(); hoverClose = nil
            pendingHover = nil; pendingBubbleToggle = true
            return
        }
        hoverClose?.cancel(); hoverClose = nil
        panel.makeFirstResponder(nil)
        animationInProgress = true
        let old = panel.frame
        let target: NSRect
        if !bubble {
            hoverRequiresExit = true
            expandedSize = old.size
            transitionSize = old.size
            let ballX = min(max(old.maxX - 46, area.minX), area.maxX - 48)
            let y = min(max(old.maxY - 46, area.minY), area.maxY - 48)
            bubbleOnRight = ballX + 24 > area.midX
            let w = baseWidth
            target = NSRect(x: bubbleOnRight ? ballX + 48 - w : ballX, y: y, width: w, height: 48)
            prepareSurfaceTransition(from: old, to: target, compact: true)
            panel.minSize = NSSize(width: 48, height: 48)
            panel.styleMask.remove(.resizable)
            bubble = true
        } else {
            let width = min(expandedSize.width, area.width)
            let height = min(expandedSize.height, area.height)
            let center = bubbleOnRight ? old.maxX - 24 : old.minX + 24
            let right = min(max(center + 22, area.minX + width), area.maxX)
            let top = min(max(old.midY + 22, area.minY + height), area.maxY)
            target = NSRect(x: right - width, y: top - height, width: width, height: height)
            prepareSurfaceTransition(from: old, to: target, compact: false)
            transitionSize = target.size
            hovering = false
            bubble = false
        }
        refreshShadow()
        // Hidden windows have no visible movement to animate, and AppKit can
        // withhold their frame updates/completions even inside NSApplication.run.
        // A controlled test driver explicitly bypasses visibility/display checks.
        if !animated || (environment.animateFrame == nil && (!panel.isVisible || NSScreen.main == nil)) {
            panel.setFrame(target, display: true)
            finishBubbleTransition()
            return
        }
        let duration = environment.frameAnimationDuration(bubble)
        let complete: @MainActor () -> Void = { [weak self] in
            guard let self, !self.stopped else { return }
            if self.panel.frame != target { self.panel.setFrame(target, display: false) }
            self.finishBubbleTransition()
        }
        if let animate = environment.animateFrame {
            animate(panel, target, duration, complete)
            return
        }
        let animation = PanelFrameAnimation(window: panel, target: target, duration: duration) { [weak self] in
            self?.frameAnimation = nil
            complete()
        }
        frameAnimation = animation
        animation.startMotion()
    }

    private func prepareSurfaceTransition(from frame: NSRect, to target: NSRect, compact: Bool) {
        let end = FloatingSurface.opticalInsets(compact: compact, reduceTransparency: false, increasedContrast: false)
        let transition = PanelSurfaceTransition(start: frame, target: target, from: surfaceInsets, to: end, onRight: bubbleOnRight)
        insetTransition = transition
        surfaceInsets = transition.insets(at: frame)
    }

    private func finishBubbleTransition() {
        insetTransition = nil
        surfaceInsets = FloatingSurface.opticalInsets(compact: bubble, reduceTransparency: false, increasedContrast: false)
        animationInProgress = false
        refreshShadow()
        if bubble {
            // A collapse click often leaves the pointer inside the new circle.
            // Only a fresh pointer entry should reveal the detail capsule.
            hoverRequiresExit = panel.frame.contains(environment.mouseLocation())
            return
        }
        panel.minSize = NSSize(width: 320, height: 440)
        panel.styleMask.insert(.resizable)
        rememberFrame(panel.frame)
    }

    func setHover(_ active: Bool) {
        guard !stopped, !bubbleMenuOpen else { return }
        if !active && !panel.frame.contains(environment.mouseLocation()) { hoverRequiresExit = false }
        guard bubble, !animationInProgress, let area = environment.visibleFrame(panel) else { return }
        if active && hoverRequiresExit { return }
        if active && !model.settings.hoverExpand { return }
        if active && environment.pressedMouseButtons() & 1 != 0 { return }
        if !active {
            guard hovering, hoverClose == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hoverClose = nil
                guard self.bubble, !self.bubbleMenuOpen, self.environment.pressedMouseButtons() & 1 == 0, !self.panel.frame.contains(self.environment.mouseLocation()) else { return }
                self.setHover(false, in: self.environment.visibleFrame(self.panel) ?? area)
            }
            hoverClose = work
            environment.schedule(0.22, work)
            return
        }
        hoverClose?.cancel(); hoverClose = nil
        pendingHover = nil
        guard !hovering else { return }
        setHover(true, in: area)
    }

    // Immediate geometry handoff, also usable without a WindowServer display.
    func setHover(_ active: Bool, in area: NSRect) {
        guard !stopped, bubble, !animationInProgress else { return }
        if hoverAnimating { pendingHover = active; return }
        guard hovering != active else { return }
        hoverAnimating = true
        let frame = panel.frame
        let details = bubbleContent?() ?? BubbleContent(model: model, groupID: filterState?.groupID, fallbackTitle: title(), state: filterState)
        let width: CGFloat = active ? min(ceil(78 + details.textWidth(language: model.language)) + filterExtra, max(baseWidth, min(440, area.width / 2))) : baseWidth
        let coreX = bubbleOnRight ? frame.maxX - 24 : frame.minX + 24
        let target = NSRect(x: bubbleOnRight ? coreX + 24 - width : coreX - 24, y: frame.minY, width: width, height: 48)
        // Resize the coordinate space without animation; only the glass surface morphs.
        // Animating the whole tree also moves the hit target away from the pointer.
        if active { panel.setFrame(target, display: true) }
        hovering = active
        refreshShadow()
    }

    func finishHover(_ active: Bool) {
        // A delayed SwiftUI completion for the previous reveal can arrive after
        // retraction starts. It must not consume the new transition's completion.
        guard !stopped, bubble, hoverAnimating, hovering == active else { return }
        if !active && (bubbleMenuOpen || environment.pressedMouseButtons() & 1 != 0) {
            environment.schedule(0.1, DispatchWorkItem { [weak self] in self?.finishHover(active) })
            return
        }
        if !active {
            let frame = panel.frame
            let coreX = bubbleOnRight ? frame.maxX - 24 : frame.minX + 24
            panel.setFrame(NSRect(x: bubbleOnRight ? coreX + 24 - baseWidth : coreX - 24, y: frame.minY, width: baseWidth, height: 48), display: true)
            if let area = environment.visibleFrame(panel) { bubbleOnRight = coreX > area.midX }
        }
        hoverAnimating = false
        refreshShadow()
        environment.hoverDidFinish(active)
        if pendingBubbleToggle {
            pendingBubbleToggle = false
            toggleBubble()
            return
        }
        if let next = pendingHover {
            pendingHover = nil
            if let area = environment.visibleFrame(panel) { setHover(next, in: area) }
        }
    }

    /// The filter changed while collapsed: grow or shrink the strip, ball fixed.
    func refreshBaseWidth() {
        guard !stopped, bubble, !animationInProgress, !hovering, !hoverAnimating else { return }
        let frame = panel.frame
        let w = baseWidth
        guard abs(frame.width - w) > 0.5 else { return }
        let target = NSRect(x: bubbleOnRight ? frame.maxX - w : frame.minX, y: frame.minY, width: w, height: 48)
        if panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else { panel.setFrame(target, display: true) }
        refreshShadow()
    }

    func beginBubbleDrag() {
        guard !stopped, bubble, !animationInProgress else { return }
        hoverClose?.cancel(); hoverClose = nil
        pendingHover = nil
    }

    @discardableResult func finishBubbleMove() -> NSRect? {
        guard !stopped, bubble, !animationInProgress, let area = environment.visibleFrame(panel) else { return nil }
        let frame = panel.frame
        let x = min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width))
        let y = min(max(frame.minY, area.minY), max(area.minY, area.maxY - frame.height))
        if x != frame.minX || y != frame.minY { panel.setFrameOrigin(NSPoint(x: x, y: y)) }
        if !hovering && !hoverAnimating && frame.width <= baseWidth + 1 { bubbleOnRight = x + frame.width / 2 > area.midX }
        let width = min(expandedSize.width, area.width)
        let height = min(expandedSize.height, area.height)
        let center = bubbleOnRight ? x + frame.width - 24 : x + 24
        let right = min(max(center + 22, area.minX + width), area.maxX)
        let top = min(max(y + 46, area.minY + height), area.maxY)
        let expanded = NSRect(x: right - width, y: top - height, width: width, height: height)
        rememberFrame(expanded)
        refreshShadow()
        return expanded
    }

    func showMenu(_ menu: NSMenu, event: NSEvent, in view: NSView) {
        guard !stopped, bubble, !animationInProgress else { return }
        hoverClose?.cancel(); hoverClose = nil
        pendingHover = nil
        bubbleMenuOpen = true
        defer {
            bubbleMenuOpen = false
            setHover(panel.frame.contains(environment.mouseLocation()))
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    func updateIdleState() {
        guard !stopped else { return }
        let prefs = model.settings
        if bubble && hoverRequiresExit && !panel.frame.contains(environment.mouseLocation()) { hoverRequiresExit = false }
        if bubble && hovering && !panel.frame.contains(environment.mouseLocation()) && environment.pressedMouseButtons() & 1 == 0 { setHover(false) }
        let active = bubble || animationInProgress || panel.isKeyWindow || panel.frame.contains(environment.mouseLocation()) || environment.pressedMouseButtons() & 1 != 0
        let now = environment.now()
        if active || prefs.locked { lastActive = now }
        let idle = now.timeIntervalSince(lastActive)
        if !active && !prefs.locked && prefs.autoCollapse && idle >= Double(prefs.autoCollapseSecs) {
            toggleBubble()
            return
        }
        let faded = !active && !prefs.locked && prefs.idleFade && idle >= Double(prefs.idleDelaySecs)
        let target = faded ? Double(prefs.idleOpacity) / 100 : 1
        guard idleContentOpacity != target else { return }
        let duration = faded ? Double(prefs.idleFadeSecs) : 0.12
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: duration)) {
            idleContentOpacity = target
        }
    }

}
