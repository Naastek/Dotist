import AppKit
import CoreText
import DotistCore
import SwiftUI

/// The observed whole-rect animator produced integer frames with reversing
/// edges. Align edges at one shared progress before deriving the rect, keeping
/// those geometric invariants without assuming AppKit's internal rounding rule.
@MainActor
final class PanelFrameAnimation {
    private weak var window: NSWindow?
    private let start: NSRect
    private let target: NSRect
    private var previous: NSRect
    private var completion: (() -> Void)?
    let duration: TimeInterval
    private var task: Task<Void, Never>?
    private(set) var displayLink: CADisplayLink?
    private var began: TimeInterval = 0
    var isAnimating: Bool { task != nil || displayLink != nil }

    init(window: NSWindow, target: NSRect, duration: TimeInterval, completion: @escaping () -> Void) {
        self.window = window
        start = window.frame
        previous = window.frame
        self.target = target
        self.completion = completion
        self.duration = duration
    }
    isolated deinit { stopDrivers() }

    func startMotion() {
        guard completion != nil, !isAnimating else { return }
        if duration <= 0 { currentProgress = 1; return }
        guard let window else { cancel(); return }
        began = ProcessInfo.processInfo.systemUptime
        if window.isVisible, window.screen != nil {
            guard let view = window.contentView else { currentProgress = 1; return }
            let link = view.displayLink(target: PanelFrameDisplayTarget(animation: self),
                                        selector: #selector(PanelFrameDisplayTarget.tick(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
            return
        }
        // Unordered/no-screen fixtures have no display callbacks. This bounded
        // fallback is never started alongside a visible window's display link.
        let began = self.began
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let duration = self?.duration else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                self?.advanceFrame()
                if elapsed >= duration { self?.task = nil; return }
                do { try await Task.sleep(for: .seconds(min(1.0 / 60, duration - elapsed))) }
                catch { return }
            }
        }
    }
    func cancel() {
        completion = nil
        stopDrivers()
    }
    private func stopDrivers() {
        task?.cancel(); task = nil
        displayLink?.invalidate(); displayLink = nil
    }
    fileprivate func advanceFrame() {
        guard completion != nil, duration > 0 else { return }
        currentProgress = Float(min(1, (ProcessInfo.processInfo.systemUptime - began) / duration))
    }
    var currentProgress: Float = 0 {
        didSet {
            guard completion != nil else { return }
            guard let window else { cancel(); return }
            let progress = CGFloat(currentProgress)
            let frame = Self.frame(from: start, to: target, progress: progress, previous: previous)
            window.setFrame(frame, display: true)
            previous = window.frame
            if progress >= 1 {
                let done = completion
                completion = nil
                stopDrivers()
                done?()
            }
        }
    }

    /// Invert the x coordinate of CA's easeInEaseOut cubic (not smoothstep or
    /// NSAnimation's differently defined easeInOut curve).
    static func easedProgress(_ time: CGFloat) -> CGFloat {
        if time <= 0 { return 0 }; if time >= 1 { return 1 }
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        var a: [Float] = [0, 0], b: [Float] = [0, 0]
        timing.getControlPoint(at: 1, values: &a)
        timing.getControlPoint(at: 2, values: &b)
        func cubic(_ u: CGFloat, _ p: Float, _ q: Float) -> CGFloat {
            3 * (1 - u) * (1 - u) * u * CGFloat(p) + 3 * (1 - u) * u * u * CGFloat(q) + u * u * u
        }
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<30 {
            let u = (low + high) / 2
            if cubic(u, a[0], b[0]) < time { low = u } else { high = u }
        }
        return cubic((low + high) / 2, a[1], b[1])
    }

    static func frame(from start: NSRect, to target: NSRect, progress: CGFloat, previous: NSRect) -> NSRect {
        if progress <= 0 { return start }; if progress >= 1 { return target }
        let p = easedProgress(progress)
        func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat,
                  _ previousSize: CGFloat) -> (CGFloat, CGFloat) {
            var low = (a + (c - a) * p).rounded(), high = (b + (d - b) * p).rounded()
            // Edge rounding can otherwise reverse size when parallel edges move
            // by different amounts. Advance the dominant edge to preserve size.
            let size = min(max(high - low, min(previousSize, d - c)), max(previousSize, d - c))
            if abs(c - a) >= abs(d - b) { low = high - size } else { high = low + size }
            return (low, high - low)
        }
        let x = axis(start.minX, start.maxX, target.minX, target.maxX, previous.width)
        let y = axis(start.minY, start.maxY, target.minY, target.maxY, previous.height)
        return NSRect(x: x.0, y: y.0, width: x.1, height: y.1)
    }
}

/// The link retains this target; its weak reference cannot retain the animation.
@MainActor
private final class PanelFrameDisplayTarget: NSObject {
    weak var animation: PanelFrameAnimation?
    init(animation: PanelFrameAnimation) { self.animation = animation }
    @objc func tick(_ link: CADisplayLink) {
        guard let animation else { link.invalidate(); return }
        animation.advanceFrame()
    }
}

/// One source for the strip's task, metadata, count and measured width. Group identity
/// is an ID, never a display name (names can be empty, duplicated or renamed).
@MainActor
struct BubbleContent {
    let task: DotistTask?
    let title: String
    let group: String?
    let due: String?
    let remaining: Int
    var subtitle: String { [group, due].compactMap { $0 }.joined(separator: " · ") }

    init(model: AppModel, groupID: String? = nil, fallbackTitle: String? = nil, state: TaskPanelState? = nil) {
        var open = model.topLevelTasks.filter { $0.parentId == nil && !$0.completed && (groupID == nil || $0.category == groupID) }
        var next = groupID == nil ? model.nextTask : model.ordered(open).first
        var filteredEmpty = false
        // The bubble counts what the panel shows when a date or tag filter is active.
        if let state, state.scope != "done", state.dateFilterActive || state.activeTag != nil {
            let range = state.customStart.map { TaskDateRange($0, state.customEnd ?? $0) }
            let matches = model.ordered(model.filteredTasks(scope: state.scope, groupID: groupID, tag: state.activeTag, customRange: range).matches)
            open = matches
            next = matches.first
            filteredEmpty = matches.isEmpty
        }
        task = next
        remaining = open.count
        // A selected empty group must not borrow the global next task's title.
        let emptyTitle = groupID.map { model.groupDisplayName($0) } ?? Self.clean(fallbackTitle) ?? model.bubbleTitle
        title = filteredEmpty ? model.text("没有符合筛选的任务") : Self.clean(next?.title) ?? (next == nil ? emptyTitle : model.text("未命名任务"))
        group = next.flatMap { model.group(for: $0) }.flatMap { Self.clean($0.name) }
        due = next?.dueDate.flatMap(Self.clean).flatMap { Self.clean(model.dueLabel($0)) }
    }

    static func clean(_ value: String?) -> String? {
        let text = value?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return text.isEmpty ? nil : text
    }

    func textWidth(language: String) -> CGFloat {
        let titleWidth = (title as NSString).size(withAttributes: [.font: DotistDesign.nativeFont(13, weight: .medium, language: language)]).width
        let groupWidth = ((group ?? "") as NSString).size(withAttributes: [.font: DotistDesign.nativeFont(12, weight: .semibold, serif: true, language: language)]).width
        let detail = (group != nil && due != nil ? " · " : "") + (due ?? "")
        let detailWidth = (detail as NSString).size(withAttributes: [.font: DotistDesign.nativeFont(12, language: language)]).width
        return max(titleWidth, groupWidth + detailWidth)
    }
}

/// Insets interpolate along actual window anchors, not elapsed time. A clipped
/// stationary anchor uses the other moving edges; an entirely stationary rect
/// has no geometric progress and resolves directly to its endpoint padding.
struct PanelSurfaceTransition {
    let start: NSRect
    let target: NSRect
    let from: EdgeInsets
    let to: EdgeInsets
    let onRight: Bool

    func insets(at frame: NSRect) -> EdgeInsets {
        let a = [start.minX, start.maxX, start.minY, start.maxY]
        let b = [target.minX, target.maxX, target.minY, target.maxY]
        let c = [frame.minX, frame.maxX, frame.minY, frame.maxY]
        var dot: CGFloat = 0, length: CGFloat = 0
        for i in a.indices { dot += (c[i] - a[i]) * (b[i] - a[i]); length += (b[i] - a[i]) * (b[i] - a[i]) }
        let fallback = length > 0 ? min(1, max(0, dot / length)) : 1
        func progress(_ index: Int) -> CGFloat {
            let distance = b[index] - a[index]
            return distance == 0 ? fallback : min(1, max(0, (c[index] - a[index]) / distance))
        }
        let x = progress(onRight ? 1 : 0), y = progress(3)
        func mix(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * p }
        return EdgeInsets(top: mix(from.top, to.top, y), leading: mix(from.leading, to.leading, x),
                          bottom: mix(from.bottom, to.bottom, y), trailing: mix(from.trailing, to.trailing, x))
    }
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
    private var lastActive = Date()
    private var hoverClose: DispatchWorkItem?
    private var pendingHover: Bool?
    private var pendingBubbleToggle = false
    private var hoverRequiresExit = false
    private var bubbleMenuOpen = false
    private var stopped = false
    private var closeObservation: NSObjectProtocol?
    private var frameAnimation: PanelFrameAnimation?
    private var insetTransition: PanelSurfaceTransition?
    private var insetObservations: [NSObjectProtocol] = []

    init(model: AppModel, panel: DotistPanel, size: NSSize, title: @escaping () -> String, bubbleContent: (() -> BubbleContent)? = nil, environment: Environment = Environment(), rememberFrame: @escaping (NSRect) -> Void = { _ in }) {
        self.model = model
        self.panel = panel
        self.environment = environment
        expandedSize = size
        transitionSize = size
        self.title = title
        self.bubbleContent = bubbleContent
        self.rememberFrame = rememberFrame
        panel.hasShadow = true
        // Panel state owns the window shadow even when glass debugging is enabled.
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
                }
            })
        }
    }
    isolated deinit {
        frameAnimation?.cancel()
        hoverClose?.cancel()
        if let closeObservation { NotificationCenter.default.removeObserver(closeObservation) }
        insetObservations.forEach { NotificationCenter.default.removeObserver($0) }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
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
            panel.hasShadow = false
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
            panel.hasShadow = true
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
        if active || prefs.locked { lastActive = Date() }
        let idle = Date().timeIntervalSince(lastActive)
        if !active && !prefs.locked && prefs.autoCollapse && idle >= Double(prefs.autoCollapseSecs) {
            toggleBubble()
            return
        }
        let faded = !active && !prefs.locked && prefs.idleFade && idle >= Double(prefs.idleDelaySecs)
        let target = faded ? CGFloat(prefs.idleOpacity) / 100 : 1
        guard abs(panel.alphaValue - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (faded ? Double(prefs.idleFadeSecs) : 0.12)
            panel.animator().alphaValue = target
        }
    }

}

/// Refresh AppKit's alpha-derived shadow after SwiftUI commits and throughout
/// its longest surface/frame animation. This view draws no pixels and owns no window.
struct ShadowTrackedContent<Content: View>: View {
    @ObservedObject var model: AppModel
    let content: Content
    var body: some View {
        content.background(WindowShadowInvalidation(settings: model.settings))
    }
}

struct WindowShadowInvalidation: NSViewRepresentable {
    var settings: DotistSettings? = nil
    func makeNSView(context: Context) -> ShadowInvalidationView { ShadowInvalidationView() }
    func updateNSView(_ view: ShadowInvalidationView, context: Context) { view.refresh() }
    static func dismantleNSView(_ view: ShadowInvalidationView, coordinator: ()) { view.stop() }
}

final class ShadowInvalidationView: NSView {
    private var timer: Timer?
    private var refreshDisplayLink: CADisplayLink?
    private var deadline = Date.distantPast
    private var closed = false
    private var observations: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        closed = false
        guard let window else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed = true; self?.stopFrames() }
        })
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Settings/search windows are retained and may reopen after close.
                self?.closed = false
                self?.refresh()
            }
        })
        refresh()
    }

    func refresh() {
        guard !closed, let window else { return }
        window.invalidateShadow()
        deadline = Date().addingTimeInterval(0.45)
        guard timer == nil, refreshDisplayLink == nil else { return }
        if window.isVisible, window.screen != nil {
            // Follow the display cadence (including ProMotion), rather than
            // sampling a 120 Hz glass animation with a fixed 60 Hz timer.
            let link = displayLink(target: ShadowRefreshTarget(view: self), selector: #selector(ShadowRefreshTarget.tick(_:)))
            refreshDisplayLink = link
            link.add(to: .main, forMode: .common)
            return
        }
        // Offscreen test hosts have no display ticks; still refresh their commits.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.refreshFrame()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    fileprivate func refreshFrame() {
        window?.invalidateShadow()
        if window == nil || Date() >= deadline {
            timer?.invalidate(); timer = nil
            refreshDisplayLink?.invalidate(); refreshDisplayLink = nil
        }
    }

    private func stopFrames() {
        timer?.invalidate(); timer = nil
        refreshDisplayLink?.invalidate(); refreshDisplayLink = nil
    }

    func stop() {
        stopFrames()
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
    }
    isolated deinit { stop() }
}

/// CADisplayLink retains its target. A weak forwarding target lets removing a
/// hosting view release its refresh driver without waiting for a final frame.
private final class ShadowRefreshTarget: NSObject {
    weak var view: ShadowInvalidationView?
    init(view: ShadowInvalidationView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.refreshFrame()
    }
}

/// The content and material share the same animated silhouette, including the
/// unused transparent area of the already-resized hover window.
struct FloatingPanelShape: Shape {
    let compact: Bool
    let transitioning: Bool
    let onRight: Bool
    var reveal: CGFloat
    var base: CGFloat = 48
    var debug: GlassDebugParameters? = nil
    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let width = compact && !transitioning ? base + (rect.width - base) * min(1, max(0, reveal)) : rect.width
        let surface = CGRect(x: rect.minX + (onRight ? rect.width - width : 0), y: rect.minY, width: width, height: rect.height)
        if compact, let debug {
            if debug.shape == .capsule { return Capsule().path(in: surface) }
            return RoundedRectangle(cornerRadius: CGFloat(debug.radius.rawValue), style: .continuous).path(in: surface)
        }
        return RoundedRectangle(cornerRadius: compact ? 24 : DotistDesign.windowCornerRadius, style: .continuous).path(in: surface)
    }
}

struct FloatingPanelView<Content: View>: View {
    @ObservedObject private var glassDebug = GlassDebugState.shared
    @ObservedObject var model: AppModel
    @ObservedObject var motion: PanelMotion
    @ObservedObject var colorState: TaskPanelState
    let title: String
    let remaining: Int
    let total: Int
    let groupName: String?
    let contextMenu: (NSEvent, NSView) -> Void
    let content: Content
    @State private var hoverReveal: CGFloat = 0
    var filter: [String] { colorState.filterParts(in: model, includeGroup: groupName == nil) }
    var bubbleContent: BubbleContent {
        // groupName controls panel wording, never the selected task scope.
        BubbleContent(model: model, groupID: colorState.groupID, fallbackTitle: title, state: colorState)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            let fixed = motion.bubble || motion.animationInProgress
            let width = fixed ? motion.transitionSize.width : geometry.size.width
            let height = fixed ? motion.transitionSize.height : geometry.size.height
            let extra = motion.animationInProgress ? 0 : motion.filterExtra
            ZStack(alignment: .topTrailing) {
                content
                    .frame(width: width, height: height)
                    .opacity(motion.bubble ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14).delay(motion.bubble ? 0 : 0.1), value: motion.bubble)
                    .allowsHitTesting(!motion.bubble)
                    .accessibilityHidden(motion.bubble)
                // Keep text, font cascade and SwiftUI metadata warm before the first
                // collapse. The circle's content never lays out at intermediate widths.
                FloatingBubble(model: model, motion: motion,
                    details: bubbleContent,
                    groupName: groupName, contextMenu: contextMenu, width: motion.bubble && !motion.animationInProgress ? geometry.size.width : 48, reveal: hoverReveal,
                    extra: extra, filter: filter)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: motion.animationInProgress || motion.bubbleOnRight ? .topTrailing : .topLeading)
                    .opacity(motion.bubble ? 1 : 0)
                    .allowsHitTesting(motion.bubble && !motion.animationInProgress)
                    .accessibilityHidden(!motion.bubble)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
            // Clip the animated content, then attach glass. Masking the combined
            // result also cuts the system material's light at the silhouette.
            .clipShape(FloatingPanelShape(compact: motion.bubble, transitioning: motion.animationInProgress,
                onRight: motion.bubbleOnRight, reveal: hoverReveal, base: 48 + extra,
                debug: glassDebug.enabled && !reduceTransparency && contrast != .increased ? glassDebug.parameters : nil))
            .background(FloatingSurface(opacity: model.settings.opacity, frost: model.settings.frost,
                compact: motion.bubble, transitioning: motion.animationInProgress, onRight: motion.bubbleOnRight,
                size: geometry.size, reveal: hoverReveal, color: model.themeColor(forGroup: colorState.groupID), base: 48 + extra,
                frameInsets: motion.surfaceInsets))
            .background(WindowShadowInvalidation())
        }
        .environment(\.glassDebugParameters, glassDebug.enabled ? glassDebug.parameters : nil)
        .onAppear { motion.refreshShadow(); motion.filterState = colorState; motion.filterLines = filter }
        .onChange(of: filter) { motion.filterLines = filter; motion.refreshBaseWidth() }
        .onChange(of: model.settings) { motion.refreshShadow() }
        .onChange(of: model.groups) { motion.refreshShadow() }
        .onChange(of: colorState.groupID) { motion.refreshShadow() }
        .onChange(of: title) { motion.refreshShadow() }
        .onChange(of: scheme) { motion.refreshShadow() }
        .onChange(of: reduceTransparency) { motion.refreshShadow() }
        .onChange(of: contrast) { motion.refreshShadow() }
        .onChange(of: motion.hovering) { _, active in
            // The window already has its final width. Reveal text and glass in the
            // same transaction, then shrink the window after both have settled.
            if reduceMotion {
                hoverReveal = active ? 1 : 0
                motion.finishHover(active)
            } else {
                withAnimation(.easeInOut(duration: 0.26), completionCriteria: .removed) {
                    hoverReveal = active ? 1 : 0
                } completion: {
                    motion.finishHover(active)
                }
            }
        }
        .modifier(DotistTheme(theme: model.settings.theme))
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
        if compact && !reduceTransparency && contrast != .increased {
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

/// Informational bubble labels use the bounds of the final, possibly truncated
/// native glyph runs. Centering SwiftUI line boxes (and calibrating them with
/// ImageRenderer) leaves a different ink axis in a window-backed NSHostingView.
private struct BubbleText: NSViewRepresentable {
    let lines: [NSAttributedString]
    var centered = false
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> BubbleTextView { BubbleTextView() }
    func updateNSView(_ view: BubbleTextView, context: Context) {
        view.lines = lines
        view.centered = centered
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.needsDisplay = true
    }
}

private final class BubbleTextView: NSView {
    var lines: [NSAttributedString] = []
    var centered = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        context.textPosition = .zero
        let runs = lines.compactMap { text -> (CTLine, CGRect)? in
            guard text.length > 0 else { return nil }
            let full = CTLineCreateWithAttributedString(text)
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: text.attributes(at: 0, effectiveRange: nil)))
            let line = CTLineGetTypographicBounds(full, nil, nil, nil) > bounds.width
                ? CTLineCreateTruncatedLine(full, bounds.width, .end, token) ?? token : full
            let ink = CTLineGetImageBounds(line, context)
            return ink.isEmpty || ink.isNull ? nil : (line, ink)
        }
        // Space actual ink, rather than font ascender/descender boxes. This also
        // keeps mixed serif group / sans date metadata on a common visual axis.
        let gap: CGFloat = 6
        let height = runs.reduce(CGFloat(0)) { $0 + $1.1.height } + CGFloat(max(0, runs.count - 1)) * gap
        var top = bounds.midY + height / 2
        for (line, ink) in runs {
            context.textPosition = CGPoint(x: centered ? bounds.midX - ink.midX : 0, y: top - ink.maxY)
            CTLineDraw(line, context)
            top -= ink.height + gap
        }
    }
}

struct FloatingBubble: View {
    @ObservedObject private var typography = DotistTypography.shared
    @ObservedObject var model: AppModel
    @ObservedObject var motion: PanelMotion
    let details: BubbleContent
    let groupName: String?
    let contextMenu: (NSEvent, NSView) -> Void
    let width: CGFloat
    let reveal: CGFloat
    var extra: CGFloat = 0
    var filter: [String] = []

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, serif: Bool = false, color: Color) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: DotistDesign.nativeFont(size, weight: weight, serif: serif, language: model.language),
            .foregroundColor: NSColor(color)
        ])
    }

    private var textLines: [NSAttributedString] {
        let title = label(details.title, size: 13, weight: .medium, color: DotistDesign.ink)
        guard !details.subtitle.isEmpty else { return [title] }
        let metadata = NSMutableAttributedString(string: "")
        if let group = details.group { metadata.append(label(group, size: 12, weight: .semibold, serif: true, color: DotistDesign.muted)) }
        if details.group != nil && details.due != nil { metadata.append(label(" · ", size: 12, color: DotistDesign.muted)) }
        if let due = details.due { metadata.append(label(due, size: 12, color: DotistDesign.muted)) }
        return [title, metadata]
    }

    var body: some View {
        Button(action: motion.toggleBubble) {
            ZStack(alignment: motion.bubbleOnRight ? .trailing : .leading) {
                BubbleText(lines: textLines)
                    .frame(width: max(0, width - 78 - extra), height: 48, alignment: .leading)
                    .padding(motion.bubbleOnRight ? .leading : .trailing, 12)
                    .padding(motion.bubbleOnRight ? .trailing : .leading, 18 + extra)
                    .offset(x: (1 - reveal) * max(0, width - 48) * (motion.bubbleOnRight ? 1 : -1))
                    .frame(width: max(0, width - 48), height: 48)
                    .clipped()
                    .opacity(Double(reveal))
                    .frame(width: width, height: 48, alignment: motion.bubbleOnRight ? .leading : .trailing)
                    .accessibilityHidden(true)
                if !filter.isEmpty, extra > 0 {
                    // One line per condition, the block centered on the ball's axis.
                    BubbleText(lines: filter.map { label($0, size: 12, color: DotistDesign.muted) })
                        .frame(width: max(0, extra - 16), height: 48, alignment: .leading)
                        .padding(motion.bubbleOnRight ? .trailing : .leading, 52)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
                ZStack {
                    BubbleText(lines: [label("\(details.remaining)", size: 20, weight: .semibold, color: DotistDesign.ink)], centered: true)
                }.frame(width: 48, height: 48).contentShape(Circle())
            }.frame(width: width, height: 48, alignment: motion.bubbleOnRight ? .trailing : .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(DotistFocusRing())
        .overlay {
            if motion.environment.pointerEventsEnabled {
                // Also gate retained callbacks: removing a hosting view can
                // deliver a tracking exit from its old AppKit pointer overlay.
                BubblePointer(action: {
                    if motion.environment.pointerEventsEnabled { motion.toggleBubble() }
                }, drag: {
                    if motion.environment.pointerEventsEnabled { motion.beginBubbleDrag() }
                }, hover: { active in
                    if motion.environment.pointerEventsEnabled { motion.setHover(active) }
                }, contextMenu: { event, view in
                    if motion.environment.pointerEventsEnabled { contextMenu(event, view) }
                }, dragEnd: {
                    if motion.environment.pointerEventsEnabled { motion.finishBubbleMove() }
                }).accessibilityHidden(true)
            }
        }
        .accessibilityLabel(Text(groupName.map { model.text("展开分组 {name}").replacingOccurrences(of: "{name}", with: $0) } ?? (details.remaining > 0 ? model.text("还有 {n} 件，点击展开").replacingOccurrences(of: "{n}", with: "\(details.remaining)") : model.text("全部完成，点击展开"))))
    }
}
