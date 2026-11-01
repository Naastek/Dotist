import AppKit
import DotistCore
import SwiftUI

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
    private let rememberFrame: (NSRect) -> Void
    private var lastActive = Date()
    private var hoverClose: DispatchWorkItem?
    private var pendingHover: Bool?
    private var pendingBubbleToggle = false
    private var hoverRequiresExit = false
    private var bubbleMenuOpen = false

    init(model: AppModel, panel: DotistPanel, size: NSSize, title: @escaping () -> String, rememberFrame: @escaping (NSRect) -> Void = { _ in }) {
        self.model = model
        self.panel = panel
        expandedSize = size
        transitionSize = size
        self.title = title
        self.rememberFrame = rememberFrame
    }
    deinit { hoverClose?.cancel() }
    func stop() { hoverClose?.cancel(); hoverClose = nil }

    func toggleBubble() {
        guard !animationInProgress, let screen = panel.screen ?? NSScreen.main else { return }
        if hoverAnimating {
            hoverClose?.cancel(); hoverClose = nil
            pendingHover = nil; pendingBubbleToggle = true
            return
        }
        hoverClose?.cancel(); hoverClose = nil
        panel.makeFirstResponder(nil)
        animationInProgress = true
        let area = screen.visibleFrame
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0 : (bubble ? 0.28 : 0.34)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.animationInProgress = false
                if self.bubble {
                    // A collapse click often leaves the pointer inside the new circle.
                    // Only a fresh pointer entry should reveal the detail capsule.
                    self.hoverRequiresExit = self.panel.frame.contains(NSEvent.mouseLocation)
                    return
                }
                self.panel.minSize = NSSize(width: 320, height: 440)
                self.panel.styleMask.insert(.resizable)
                self.rememberFrame(self.panel.frame)
            }
        }
    }

    func setHover(_ active: Bool) {
        guard !bubbleMenuOpen else { return }
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
                self.setHoverNow(false, screen: self.panel.screen ?? screen)
            }
            hoverClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
            return
        }
        hoverClose?.cancel(); hoverClose = nil
        pendingHover = nil
        guard !hovering else { return }
        setHoverNow(true, screen: screen)
    }

    private func setHoverNow(_ active: Bool, screen: NSScreen) {
        guard bubble, !animationInProgress else { return }
        if hoverAnimating { pendingHover = active; return }
        guard hovering != active else { return }
        hoverAnimating = true
        let frame = panel.frame
        let titleWidth = (title() as NSString).size(withAttributes: [.font: DotistDesign.nativeFont(13, weight: .medium, language: model.language)]).width
        let width: CGFloat = active ? min(max(120, ceil(48 + 12 + titleWidth + 18)), min(440, screen.visibleFrame.width / 2)) : 48
        let coreX = bubbleOnRight ? frame.maxX - 24 : frame.minX + 24
        let target = NSRect(x: bubbleOnRight ? coreX + 24 - width : coreX - 24, y: frame.minY, width: width, height: 48)
        // Resize the coordinate space without animation; only the glass surface morphs.
        // Animating the whole tree also moves the hit target away from the pointer.
        if active { panel.setFrame(target, display: true) }
        hovering = active
    }

    func finishHover(_ active: Bool) {
        guard bubble, hoverAnimating else { return }
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
        if pendingBubbleToggle {
            pendingBubbleToggle = false
            toggleBubble()
            return
        }
        if let next = pendingHover {
            pendingHover = nil
            if let screen = panel.screen ?? NSScreen.main { setHoverNow(next, screen: screen) }
        }
    }

    func beginBubbleDrag() {
        guard bubble, !animationInProgress else { return }
        hoverClose?.cancel(); hoverClose = nil
        pendingHover = nil
    }

    @discardableResult func finishBubbleMove() -> NSRect? {
        guard bubble, !animationInProgress, let area = (panel.screen ?? NSScreen.main)?.visibleFrame else { return nil }
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
        return expanded
    }

    func showMenu(_ menu: NSMenu, event: NSEvent, in view: NSView) {
        guard bubble, !animationInProgress else { return }
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

struct FloatingPanelView<Content: View>: View {
    @ObservedObject var model: AppModel
    @ObservedObject var motion: PanelMotion
    let title: String
    let remaining: Int
    let total: Int
    let groupName: String?
    let contextMenu: (NSEvent, NSView) -> Void
    let content: Content
    @State private var hoverReveal: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                FloatingBubble(model: model, motion: motion, title: title, remaining: remaining, total: total, groupName: groupName, contextMenu: contextMenu, width: motion.bubble && !motion.animationInProgress ? geometry.size.width : 48, reveal: hoverReveal)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: motion.animationInProgress || motion.bubbleOnRight ? .topTrailing : .topLeading)
                    .opacity(motion.bubble ? 1 : 0)
                    .allowsHitTesting(motion.bubble && !motion.animationInProgress)
                    .accessibilityHidden(!motion.bubble)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
            .background(FloatingSurface(model: model, motion: motion, size: geometry.size, reveal: hoverReveal))
            .clipped()
        }
        .onChange(of: motion.hovering) { active in
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

private struct FloatingSurface: View {
    @ObservedObject var model: AppModel
    @ObservedObject var motion: PanelMotion
    let size: CGSize
    let reveal: CGFloat

    var body: some View {
        FloatingMaterial(opacity: model.settings.opacity, frost: model.settings.frost, compact: motion.bubble)
            .frame(width: motion.bubble && !motion.animationInProgress ? 48 + (size.width - 48) * reveal : size.width, height: size.height)
            .frame(width: size.width, height: size.height, alignment: motion.bubbleOnRight ? .topTrailing : .topLeading)
    }
}

private struct FloatingBubble: View {
    @ObservedObject var model: AppModel
    @ObservedObject var motion: PanelMotion
    let title: String
    let remaining: Int
    let total: Int
    let groupName: String?
    let contextMenu: (NSEvent, NSView) -> Void
    let width: CGFloat
    let reveal: CGFloat
    var body: some View {
        Button(action: motion.toggleBubble) {
            ZStack(alignment: motion.bubbleOnRight ? .trailing : .leading) {
                VStack(alignment: .leading, spacing: 1) {
                    let next = model.ordered(model.topLevelTasks.filter { !$0.completed && (groupName == nil || model.group(for: $0)?.name == groupName) }).first
                    Text(next?.title ?? title).font(DotistDesign.font(13, weight: .medium, language: model.language)).foregroundColor(DotistDesign.ink).lineLimit(1)
                    if let next {
                        let details = [model.group(for: next)?.name, next.dueDate.map(model.dueLabel)].compactMap { $0 }.joined(separator: " · ")
                        if !details.isEmpty { Text(details).font(DotistDesign.font(12, language: model.language)).foregroundColor(DotistDesign.muted).lineLimit(1) }
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
                    Text("\(remaining)").font(DotistDesign.font(20, weight: .semibold, language: model.language)).monospacedDigit().foregroundColor(DotistDesign.ink)
                }.frame(width: 48, height: 48).contentShape(Circle())
            }.frame(width: width, height: 48, alignment: motion.bubbleOnRight ? .trailing : .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(DotistFocusRing())
        .overlay(BubblePointer(action: motion.toggleBubble, drag: motion.beginBubbleDrag, hover: motion.setHover, contextMenu: contextMenu, dragEnd: { motion.finishBubbleMove() }).accessibilityHidden(true))
        .accessibilityLabel(Text(groupName.map { model.text("展开分组 {name}").replacingOccurrences(of: "{name}", with: $0) } ?? (remaining > 0 ? model.text("还有 {n} 件，点击展开").replacingOccurrences(of: "{n}", with: "\(remaining)") : model.text("全部完成，点击展开"))))
    }
}
