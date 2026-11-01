import AppKit
import DotistCore
import SwiftUI

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

    init(model: AppModel, groupID: String? = nil, fallbackTitle: String? = nil) {
        let open = model.topLevelTasks.filter { $0.parentId == nil && !$0.completed && (groupID == nil || $0.category == groupID) }
        let next = groupID == nil ? model.nextTask : model.ordered(open).first
        task = next
        remaining = open.count
        title = Self.clean(next?.title) ?? (next == nil ? Self.clean(fallbackTitle) ?? model.bubbleTitle : model.text("未命名任务"))
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

/// All task panels share one motion implementation, with independent window state.
@MainActor
final class PanelMotion: ObservableObject {
    @Published private(set) var bubble = false
    @Published private(set) var hovering = false
    @Published var bubbleOnRight = true
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

    init(model: AppModel, panel: DotistPanel, size: NSSize, title: @escaping () -> String, bubbleContent: (() -> BubbleContent)? = nil, rememberFrame: @escaping (NSRect) -> Void = { _ in }) {
        self.model = model
        self.panel = panel
        expandedSize = size
        transitionSize = size
        self.title = title
        self.bubbleContent = bubbleContent
        self.rememberFrame = rememberFrame
        panel.hasShadow = true
        closeObservation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }
    isolated deinit {
        hoverClose?.cancel()
        if let closeObservation { NotificationCenter.default.removeObserver(closeObservation) }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
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
        guard let area = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
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
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let target: NSRect
        if !bubble {
            hoverRequiresExit = true
            expandedSize = old.size
            transitionSize = old.size
            let x = min(max(old.maxX - 46, area.minX), area.maxX - 48)
            let y = min(max(old.maxY - 46, area.minY), area.maxY - 48)
            target = NSRect(x: x, y: y, width: 48, height: 48)
            bubbleOnRight = target.midX > area.midX
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
            transitionSize = target.size
            hovering = false
            bubble = false
        }
        refreshShadow()
        // Without a display AppKit may never deliver animation ticks/completion.
        if !animated || NSScreen.main == nil {
            panel.setFrame(target, display: true)
            finishBubbleTransition()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0 : (bubble ? 0.28 : 0.34)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            // AppKit owns the animator's target. A late completion must neither
            // keep its motion owner alive nor revive a closed panel's shadow.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                if self.panel.frame != target { self.panel.setFrame(target, display: false) }
                self.finishBubbleTransition()
            }
        }
    }

    private func finishBubbleTransition() {
        animationInProgress = false
        refreshShadow()
        if bubble {
            // A collapse click often leaves the pointer inside the new circle.
            // Only a fresh pointer entry should reveal the detail capsule.
            hoverRequiresExit = panel.frame.contains(NSEvent.mouseLocation)
            return
        }
        panel.minSize = NSSize(width: 320, height: 440)
        panel.styleMask.insert(.resizable)
        rememberFrame(panel.frame)
    }

    func setHover(_ active: Bool) {
        guard !stopped, !bubbleMenuOpen else { return }
        if !active && !panel.frame.contains(NSEvent.mouseLocation) { hoverRequiresExit = false }
        guard bubble, !animationInProgress, let screen = panel.screen ?? NSScreen.main else { return }
        if active && hoverRequiresExit { return }
        if active && !model.settings.hoverExpand { return }
        if active && NSEvent.pressedMouseButtons & 1 != 0 { return }
        if !active {
            guard hovering, hoverClose == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hoverClose = nil
                guard self.bubble, !self.bubbleMenuOpen, NSEvent.pressedMouseButtons & 1 == 0, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.setHover(false, in: (self.panel.screen ?? screen).visibleFrame)
            }
            hoverClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
            return
        }
        hoverClose?.cancel(); hoverClose = nil
        pendingHover = nil
        guard !hovering else { return }
        setHover(true, in: screen.visibleFrame)
    }

    // Immediate geometry handoff, also usable without a WindowServer display.
    func setHover(_ active: Bool, in area: NSRect) {
        guard !stopped, bubble, !animationInProgress else { return }
        if hoverAnimating { pendingHover = active; return }
        guard hovering != active else { return }
        hoverAnimating = true
        let frame = panel.frame
        let details = bubbleContent?() ?? BubbleContent(model: model, fallbackTitle: title())
        let width: CGFloat = active ? min(max(250, ceil(78 + details.textWidth(language: model.language))), min(440, area.width / 2)) : 48
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
        if !active && (bubbleMenuOpen || NSEvent.pressedMouseButtons & 1 != 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.finishHover(active) }
            return
        }
        if !active {
            let frame = panel.frame
            let coreX = bubbleOnRight ? frame.maxX - 24 : frame.minX + 24
            panel.setFrame(NSRect(x: coreX - 24, y: frame.minY, width: 48, height: 48), display: true)
            if let screen = panel.screen ?? NSScreen.main { bubbleOnRight = coreX > screen.visibleFrame.midX }
        }
        hoverAnimating = false
        refreshShadow()
        if pendingBubbleToggle {
            pendingBubbleToggle = false
            toggleBubble()
            return
        }
        if let next = pendingHover {
            pendingHover = nil
            if let screen = panel.screen ?? NSScreen.main { setHover(next, in: screen.visibleFrame) }
        }
    }

    func beginBubbleDrag() {
        guard !stopped, bubble, !animationInProgress else { return }
        hoverClose?.cancel(); hoverClose = nil
        pendingHover = nil
    }

    @discardableResult func finishBubbleMove() -> NSRect? {
        guard !stopped, bubble, !animationInProgress, let area = (panel.screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let frame = panel.frame
        let x = min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width))
        let y = min(max(frame.minY, area.minY), max(area.minY, area.maxY - frame.height))
        if x != frame.minX || y != frame.minY { panel.setFrameOrigin(NSPoint(x: x, y: y)) }
        if !hovering && !hoverAnimating && frame.width <= 49 { bubbleOnRight = x + frame.width / 2 > area.midX }
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
            setHover(panel.frame.contains(NSEvent.mouseLocation))
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    func updateIdleState() {
        guard !stopped else { return }
        let prefs = model.settings
        if bubble && hoverRequiresExit && !panel.frame.contains(NSEvent.mouseLocation) { hoverRequiresExit = false }
        if bubble && hovering && !panel.frame.contains(NSEvent.mouseLocation) && NSEvent.pressedMouseButtons & 1 == 0 { setHover(false) }
        let active = bubble || animationInProgress || panel.isKeyWindow || panel.frame.contains(NSEvent.mouseLocation) || NSEvent.pressedMouseButtons & 1 != 0
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
    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let width = compact && !transitioning ? 48 + (rect.width - 48) * min(1, max(0, reveal)) : rect.width
        let surface = CGRect(x: rect.minX + (onRight ? rect.width - width : 0), y: rect.minY, width: width, height: rect.height)
        return RoundedRectangle(cornerRadius: compact ? 24 : DotistDesign.windowCornerRadius, style: .continuous).path(in: surface)
    }
}

struct FloatingPanelView<Content: View>: View {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            let fixed = motion.bubble || motion.animationInProgress
            let width = fixed ? motion.transitionSize.width : geometry.size.width
            let height = fixed ? motion.transitionSize.height : geometry.size.height
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
                    details: BubbleContent(model: model, groupID: groupName == nil ? nil : colorState.groupID, fallbackTitle: title),
                    groupName: groupName, contextMenu: contextMenu, width: motion.bubble && !motion.animationInProgress ? geometry.size.width : 48, reveal: hoverReveal)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: motion.animationInProgress || motion.bubbleOnRight ? .topTrailing : .topLeading)
                    .opacity(motion.bubble ? 1 : 0)
                    .allowsHitTesting(motion.bubble && !motion.animationInProgress)
                    .accessibilityHidden(!motion.bubble)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
            .background(FloatingSurface(opacity: model.settings.opacity, frost: model.settings.frost,
                compact: motion.bubble, transitioning: motion.animationInProgress, onRight: motion.bubbleOnRight,
                size: geometry.size, reveal: hoverReveal, color: model.themeColor(forGroup: colorState.groupID)))
            .clipShape(FloatingPanelShape(compact: motion.bubble, transitioning: motion.animationInProgress,
                onRight: motion.bubbleOnRight, reveal: hoverReveal))
            .background(WindowShadowInvalidation())
        }
        .onAppear { motion.refreshShadow() }
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
    let opacity: UInt8
    let frost: UInt8
    let compact: Bool
    let transitioning: Bool
    let onRight: Bool
    let size: CGSize
    var reveal: CGFloat
    let color: DotistGroupColor
    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    var body: some View {
        FloatingPanelMaterial(opacity: opacity, frost: frost, compact: compact, color: color)
            .frame(width: compact && !transitioning ? 48 + (size.width - 48) * min(1, max(0, reveal)) : size.width, height: size.height)
            .frame(width: size.width, height: size.height, alignment: onRight ? .topTrailing : .topLeading)
            .clipShape(FloatingPanelShape(compact: compact, transitioning: transitioning, onRight: onRight, reveal: reveal))
    }
}

/// Keep the color wash above paper/frost so user opacity never erases the tint.
/// Shared by the expanded panel, circle and hover strip.
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
    let opacity: UInt8
    let frost: UInt8
    let compact: Bool
    let color: DotistGroupColor
    let solid: Bool
    let scheme: ColorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 24 : DotistDesign.windowCornerRadius, style: .continuous)
        Group {
            if solid {
                DotistDesign.paper
            } else if compact {
                Color.clear.glassEffect(.regular.tint(DotistTheme.tint(color, scheme)).interactive(), in: shape)
                    .overlay(paperOverlay)
            } else {
                Color.clear.glassEffect(.regular.tint(DotistTheme.tint(color, scheme)), in: shape)
                    .overlay(paperOverlay)
            }
        }
        .overlay(DotistTheme.swatch(color).opacity(solid ? 0.08 : (scheme == .dark ? 0.18 : 0.16)))
        .clipShape(shape)
    }

    private var paperOverlay: some View {
        DotistDesign.paper.opacity(DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false))
            .overlay(DotistDesign.paper.opacity(Double(frost) / 100 * 0.12))
    }
}

private struct FloatingBubble: View {
    @ObservedObject var model: AppModel
    @ObservedObject var motion: PanelMotion
    let details: BubbleContent
    let groupName: String?
    let contextMenu: (NSEvent, NSView) -> Void
    let width: CGFloat
    let reveal: CGFloat
    var body: some View {
        Button(action: motion.toggleBubble) {
            ZStack(alignment: motion.bubbleOnRight ? .trailing : .leading) {
                VStack(alignment: .leading, spacing: 1) {
                    OpticalText(title: details.title, size: 13, weight: .medium, language: model.language).foregroundColor(DotistDesign.ink).lineLimit(1)
                    if !details.subtitle.isEmpty {
                        HStack(alignment: .opticalCenter, spacing: 0) {
                            if let group = details.group {
                                OpticalText(title: group, size: 12, weight: .semibold, serif: true, language: model.language)
                            }
                            if details.group != nil && details.due != nil { OpticalText(title: " · ", size: 12, language: model.language) }
                            if let due = details.due { OpticalText(title: due, size: 12, language: model.language) }
                        }.font(DotistDesign.textFont(12, language: model.language)).foregroundColor(DotistDesign.muted).lineLimit(1)
                    }
                }
                    .frame(width: max(40, width - 78),
                           alignment: motion.bubbleOnRight ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(motion.bubbleOnRight ? .leading : .trailing, 12)
                    .padding(motion.bubbleOnRight ? .trailing : .leading, 18)
                    .offset(x: (1 - reveal) * max(0, width - 48) * (motion.bubbleOnRight ? 1 : -1))
                    .frame(width: max(0, width - 48), height: 48)
                    .clipped()
                    .opacity(Double(reveal))
                    .frame(width: width, height: 48, alignment: motion.bubbleOnRight ? .leading : .trailing)
                    .accessibilityHidden(true)
                ZStack {
                    OpticalText(title: "\(details.remaining)", size: 20, weight: .semibold, language: model.language).monospacedDigit().foregroundColor(DotistDesign.ink)
                }.frame(width: 48, height: 48).contentShape(Circle())
            }.frame(width: width, height: 48, alignment: motion.bubbleOnRight ? .trailing : .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(DotistFocusRing())
        .overlay(BubblePointer(action: motion.toggleBubble, drag: motion.beginBubbleDrag, hover: motion.setHover, contextMenu: contextMenu, dragEnd: { motion.finishBubbleMove() }).accessibilityHidden(true))
        .accessibilityLabel(Text(groupName.map { model.text("展开分组 {name}").replacingOccurrences(of: "{name}", with: $0) } ?? (details.remaining > 0 ? model.text("还有 {n} 件，点击展开").replacingOccurrences(of: "{n}", with: "\(details.remaining)") : model.text("全部完成，点击展开"))))
    }
}
