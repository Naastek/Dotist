import AppKit
import CoreText
import DotistCore
import SwiftUI

/// Only the material and silhouette observe the animation clock. The task
/// list keeps its expanded layout inside the fixed host.
@MainActor
final class PanelSurfaceState: ObservableObject {
    @Published var value = EdgeInsets()
    @Published var transitionFrame: NSRect?
}

/// All task panels share one motion implementation, with independent window state.
@MainActor
final class PanelMotion: ObservableObject {
    /// Production reads AppKit input and uses the main queue. Offscreen fixtures
    /// supply their own pointer, screen and scheduler instead of sampling the
    /// user's desktop while a transition is awaiting completion.
    struct Environment {
        typealias FrameAnimation = @MainActor (DotistPanel, NSRect, TimeInterval, @escaping @MainActor () -> Void) -> Void
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
    @Published private(set) var bubble = false
    let surface = PanelSurfaceState()
    var surfaceInsets: EdgeInsets { surface.value }
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
    private(set) var transitionHost: TransitionHost?
    private(set) var preparingExpansion = false

    struct TransitionHost {
        let expanded: NSRect
        let compact: NSRect
        let frame: NSRect

        init(expanded: NSRect, compact: NSRect) {
            self.expanded = expanded
            self.compact = compact
            frame = expanded.union(compact)
        }

        func local(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY,
                   width: rect.width, height: rect.height)
        }
    }
    private(set) var hoverAnimating = false
    let panel: DotistPanel
    private let model: AppModel
    private let title: () -> String
    private let bubbleContent: (() -> BubbleContent)?
    private let rememberFrame: (NSRect) -> Void
    private var lastActive = Date()
    private var hoverClose: DispatchWorkItem?
    private var pendingHover: Bool?
    private var pendingBubbleToggle = false
    private var hoverRequiresExit = false
    private var bubbleMenuOpen = false
    private var stopped = false
    private var closeObservation: NSObjectProtocol?
    private var frameAnimation: PanelFrameAnimation?
    var idleAlphaDidChange: ((CGFloat, TimeInterval) -> Void)?
    var onIdlePollingChange: (() -> Void)?
    var needsIdlePolling: Bool {
        !stopped && (panel.alphaValue < 0.99 || (bubble && (hoverRequiresExit || hovering)))
    }

    init(model: AppModel, panel: DotistPanel, size: NSSize, title: @escaping () -> String, bubbleContent: (() -> BubbleContent)? = nil, environment: Environment = Environment(), rememberFrame: @escaping (NSRect) -> Void = { _ in }) {
        self.model = model
        self.panel = panel
        self.environment = environment
        expandedSize = size
        transitionSize = size
        self.title = title
        self.bubbleContent = bubbleContent
        self.rememberFrame = rememberFrame
        // Match the bubble throughout the task panel lifecycle; native glass
        // keeps its own optical edge without an extra AppKit window shadow.
        panel.hasShadow = false
        closeObservation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }
    isolated deinit {
        frameAnimation?.cancel()
        hoverClose?.cancel()
        if let closeObservation { NotificationCenter.default.removeObserver(closeObservation) }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        frameAnimation?.cancel(); frameAnimation = nil
        hoverClose?.cancel(); hoverClose = nil
        clearSurfaceTransition()
        pendingHover = nil
        pendingBubbleToggle = false
        hoverAnimating = false
        animationInProgress = false
        if let closeObservation { NotificationCenter.default.removeObserver(closeObservation) }
        closeObservation = nil
    }

    func refreshShadow() {
        guard !stopped, panel.hasShadow else { return }
        panel.invalidateShadow()
        // SwiftUI may not have committed its glass/tint change until the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.panel.invalidateShadow()
        }
    }

    func prepareExpansionOnPress() {
        guard !stopped, bubble, !animationInProgress, !hoverAnimating, !hovering,
              !bubbleMenuOpen, !preparingExpansion, environment.animateFrame == nil,
              environment.frameAnimationDuration(false) > 0,
              panel.isVisible, panel.screen != nil,
              let area = environment.visibleFrame(panel) else { return }
        let compact = panel.frame
        let host = TransitionHost(expanded: expandedFrame(from: compact, in: area), compact: compact)
        preparingExpansion = true
        transitionHost = host
        transitionSize = host.expanded.size
        surface.transitionFrame = host.local(compact)
        panel.setFrame(host.frame, display: false)
    }

    func cancelExpansionOnPress() {
        guard preparingExpansion, let host = transitionHost else { return }
        panel.setFrame(host.compact, display: false)
        clearSurfaceTransition()
    }

    func toggleBubble() {
        guard let area = environment.visibleFrame(panel) else { cancelExpansionOnPress(); return }
        toggleBubble(in: area)
    }

    // A synchronous transition also supports callers without a live display and
    // lets geometry tests exercise the real collapse/expand state changes.
    func toggleBubble(in area: NSRect, animated: Bool = true) {
        guard !stopped else { return }
        if animationInProgress {
            guard let host = transitionHost, let current = surface.transitionFrame else { return }
            bubble.toggle()
            prepareSurfaceTransition(compact: bubble)
            startSurfaceAnimation(from: current, to: host.local(bubble ? host.compact : host.expanded),
                                  endpoint: bubble ? host.compact : host.expanded,
                                  duration: animated ? environment.frameAnimationDuration(bubble) : 0)
            return
        }
        if hoverAnimating {
            hoverClose?.cancel(); hoverClose = nil
            pendingHover = nil; pendingBubbleToggle = true
            return
        }
        #if DOTIST_BENCH
        if BenchPerf.enabled, animated, environment.animateFrame == nil, panel.isVisible, panel.screen != nil {
            BenchPerf.begin(bubble ? "expand" : "collapse")
        }
        #endif
        let beganAt = CACurrentMediaTime()
        hoverClose?.cancel(); hoverClose = nil
        panel.makeFirstResponder(nil)
        animationInProgress = true
        let prepared = preparingExpansion ? transitionHost : nil
        preparingExpansion = false
        let old = prepared?.compact ?? panel.frame
        let target: NSRect
        if !bubble {
            hoverRequiresExit = true
            expandedSize = old.size
            transitionSize = old.size
            let ballX = min(max(old.maxX - 48, area.minX), area.maxX - 48)
            let y = min(max(old.maxY - 48, area.minY), area.maxY - 48)
            bubbleOnRight = ballX + 24 > area.midX
            let w = baseWidth
            target = NSRect(x: bubbleOnRight ? ballX + 48 - w : ballX, y: y, width: w, height: 48)
            prepareSurfaceTransition(compact: true)
            panel.minSize = NSSize(width: 48, height: 48)
            panel.styleMask.remove(.resizable)
            bubble = true
        } else {
            target = expandedFrame(from: old, in: area)
            prepareSurfaceTransition(compact: false)
            transitionSize = target.size
            hovering = false
            bubble = false
        }
        // Hidden windows have no visible movement to animate, and AppKit can
        // withhold their frame updates/completions even inside NSApplication.run.
        // A controlled test driver explicitly bypasses visibility/display checks.
        if !animated || (environment.animateFrame == nil && (!panel.isVisible || panel.screen == nil)) {
            panel.setFrame(target, display: true)
            clearSurfaceTransition()
            finishBubbleTransition()
            return
        }
        let duration = environment.frameAnimationDuration(bubble)
        let complete: @MainActor () -> Void = { [weak self] in
            guard let self, !self.stopped else { return }
            if self.panel.frame != target { self.panel.setFrame(target, display: false) }
            self.clearSurfaceTransition()
            self.finishBubbleTransition()
        }
        if let animate = environment.animateFrame {
            animate(panel, target, duration, complete)
            return
        }
        guard duration > 0 else { complete(); return }
        let host = TransitionHost(expanded: bubble ? old : target, compact: bubble ? target : old)
        transitionHost = host
        surface.transitionFrame = host.local(old)
        if panel.frame != host.frame { panel.setFrame(host.frame, display: false) }
        let refreshPeriod = 1 / Double(max(60, panel.screen?.maximumFramesPerSecond ?? 60))
        let lead = prepared == nil ? 0 : min(refreshPeriod, duration / 4)
        startSurfaceAnimation(from: host.local(old), to: host.local(target), endpoint: target,
                              duration: duration, beganAt: beganAt, initialLead: lead)
    }

    private func expandedFrame(from compact: NSRect, in area: NSRect) -> NSRect {
        let width = min(expandedSize.width, area.width)
        let height = min(expandedSize.height, area.height)
        let center = bubbleOnRight ? compact.maxX - 24 : compact.minX + 24
        let right = min(max(center + 24, area.minX + width), area.maxX)
        let top = min(max(compact.midY + 24, area.minY + height), area.maxY)
        return NSRect(x: right - width, y: top - height, width: width, height: height)
    }

    private func startSurfaceAnimation(from start: NSRect, to target: NSRect, endpoint: NSRect,
                                       duration: TimeInterval, beganAt: CFTimeInterval? = nil, initialLead: TimeInterval = 0) {
        frameAnimation?.cancel()
        let animation = PanelFrameAnimation(window: panel, target: target, duration: duration, from: start,
            settleBeforeResize: bubble && panel.frame != endpoint, applyFrame: { [weak self] frame in self?.surface.transitionFrame = frame }) { [weak self] in
            guard let self, !self.stopped else { return }
            self.frameAnimation = nil
            if self.panel.frame != endpoint { self.panel.setFrame(endpoint, display: false) }
            self.clearSurfaceTransition()
            self.finishBubbleTransition()
        }
        frameAnimation = animation
        animation.startMotion(beganAt: beganAt, initialLead: initialLead)
    }

    private func clearSurfaceTransition() {
        preparingExpansion = false
        transitionHost = nil
        surface.transitionFrame = nil
    }

    private func prepareSurfaceTransition(compact: Bool) {
        // Both compact (FloatingSurface outer padding) and expanded
        // (ExpandedReadingMaterial.opticalClearance) share the same 2pt optical
        // clearance in normal mode and 0pt in accessibility solid mode. Switch
        // surfaceInsets immediately with `compact` so total visible clearance
        // never double-pads (4pt) on expand or drops to 0pt on collapse.
        surface.value = FloatingSurface.opticalInsets(compact: compact, reduceTransparency: false, increasedContrast: false)
    }

    private func finishBubbleTransition() {
        surface.value = FloatingSurface.opticalInsets(compact: bubble, reduceTransparency: false, increasedContrast: false)
        animationInProgress = false
        refreshShadow()
        if bubble {
            // A collapse click often leaves the pointer inside the new circle.
            // Only a fresh pointer entry should reveal the detail capsule.
            hoverRequiresExit = panel.frame.contains(environment.mouseLocation())
            onIdlePollingChange?()
            return
        }
        panel.minSize = NSSize(width: 320, height: 440)
        panel.styleMask.insert(.resizable)
        rememberFrame(panel.frame)
        onIdlePollingChange?()
    }

    func setHover(_ active: Bool) {
        guard !stopped, !bubbleMenuOpen else { return }
        if !active && !panel.frame.contains(environment.mouseLocation()) { hoverRequiresExit = false }
        guard bubble, !animationInProgress, !preparingExpansion, let area = environment.visibleFrame(panel) else { return }
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
        onIdlePollingChange?()
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
        guard !stopped, bubble, !animationInProgress, !preparingExpansion, !hovering, !hoverAnimating else { return }
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
        let right = min(max(center + 24, area.minX + width), area.maxX)
        let top = min(max(y + 48, area.minY + height), area.maxY)
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
        if active || prefs.locked { lastActive = Date() }
        let idle = Date().timeIntervalSince(lastActive)
        if !active && !prefs.locked && prefs.autoCollapse && idle >= Double(prefs.autoCollapseSecs) {
            toggleBubble()
            return
        }
        let faded = !active && !prefs.locked && prefs.idleFade && idle >= Double(prefs.idleDelaySecs)
        let target = faded ? CGFloat(prefs.idleOpacity) / 100 : 1
        guard abs(panel.alphaValue - target) > 0.01 else { return }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (faded ? Double(prefs.idleFadeSecs) : 0.12)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = target
        }
        idleAlphaDidChange?(target, duration)
    }

}
