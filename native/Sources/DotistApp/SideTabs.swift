import AppKit
import Combine
import SwiftUI

/// Geometry is kept independent of the window and view lifecycles.
enum SideTabGeometry {
    static let sensorWidth: CGFloat = 96
    static let windowMargin: CGFloat = 110
    static let height: CGFloat = 34
    static let spacing: CGFloat = 4
    static func isRight(panelMinX: CGFloat, visibleMinX: CGFloat) -> Bool {
        panelMinX - windowMargin < visibleMinX
    }
    static func width(selected: Bool, expanded: Bool, hovered: Bool) -> CGFloat {
        guard expanded else { return selected ? 26 : 8 }
        if selected { return 78 }
        return hovered ? 92 : 70
    }
}

private struct SideTabShape: Shape {
    let right: Bool
    func path(in rect: CGRect) -> Path {
        let r = min(8, rect.width / 2)
        var p = Path()
        if right {
            p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: rect.maxX - r, y: 0))
            p.addQuadCurve(to: .init(x: rect.maxX, y: r), control: .init(x: rect.maxX, y: 0))
            p.addLine(to: .init(x: rect.maxX, y: rect.maxY - r))
            p.addQuadCurve(to: .init(x: rect.maxX - r, y: rect.maxY), control: .init(x: rect.maxX, y: rect.maxY))
            p.addLine(to: .init(x: 0, y: rect.maxY))
        } else {
            p.move(to: .init(x: rect.maxX, y: 0)); p.addLine(to: .init(x: r, y: 0))
            p.addQuadCurve(to: .init(x: 0, y: r), control: .zero)
            p.addLine(to: .init(x: 0, y: rect.maxY - r))
            p.addQuadCurve(to: .init(x: r, y: rect.maxY), control: .init(x: 0, y: rect.maxY))
            p.addLine(to: .init(x: rect.maxX, y: rect.maxY))
        }
        p.closeSubpath(); return p
    }
}

private struct SideTabView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: TaskPanelState
    let id: String?
    let name: String
    let right: Bool
    let expanded: Bool
    let hovered: Bool
    var selected: Bool { state.groupID == id }
    var body: some View {
        Button { state.groupID = id } label: {
            GeometryReader { geometry in
                let shape = SideTabShape(right: right)
                ZStack {
                    shape.fill(DotistDesign.paper)
                    if !selected { shape.fill(DotistDesign.rule.opacity(0.45)) }
                    shape.stroke(DotistDesign.rule, lineWidth: 0.5)
                    if selected || expanded {
                        Text(model.text(name))
                            .font(DotistDesign.font(13, weight: selected ? .semibold : .regular, serif: true, language: model.language))
                            .foregroundColor(selected || hovered ? DotistDesign.ink : DotistDesign.faint)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: min(120, max(0, geometry.size.width - 6)), alignment: right ? .leading : .trailing)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }.frame(height: SideTabGeometry.height).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(model.text(name)))
        .accessibilityIdentifier("side-tab:\(id ?? "all")")
    }
}

/// One child window per ear leaves all spaces between ears truly click-through.
@MainActor
final class SideTabsController {
    private let parent: NSPanel
    private let model: AppModel
    private let state: TaskPanelState
    private let motion: PanelMotion
    private var windows: [String: NSPanel] = [:]
    private var targets: [String: NSRect] = [:]
    private var viewStates: [String: String] = [:]
    private var timer: Timer?
    private var shown = false

    init(parent: NSPanel, model: AppModel, state: TaskPanelState, motion: PanelMotion) {
        self.parent = parent; self.model = model; self.state = state; self.motion = motion
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        update()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        for window in windows.values { parent.removeChildWindow(window); window.close() }
        windows.removeAll()
    }
    private func update() {
        let visible = parent.isVisible && parent.isOnActiveSpace && !motion.bubble && !motion.animationInProgress
        guard visible else {
            if shown { windows.values.forEach { $0.orderOut(nil) }; shown = false }
            return
        }
        let items: [(String, String?, String)] = [("all", nil, "全部")] + model.groups.map { ($0.id, Optional($0.id), $0.name) }
        let ids = Set(items.map { $0.0 })
        for key in Array(windows.keys) where !ids.contains(key) {
            if let window = windows.removeValue(forKey: key) { parent.removeChildWindow(window); window.close() }
            targets.removeValue(forKey: key)
            viewStates.removeValue(forKey: key)
        }
        let frame = parent.frame
        let right = SideTabGeometry.isRight(panelMinX: frame.minX, visibleMinX: (parent.screen ?? NSScreen.main)?.visibleFrame.minX ?? frame.minX)
        let top = frame.maxY - 40
        let totalHeight = CGFloat(items.count) * SideTabGeometry.height + CGFloat(max(0, items.count - 1)) * SideTabGeometry.spacing
        let sensor = NSRect(x: right ? frame.maxX : frame.minX - SideTabGeometry.sensorWidth, y: top - totalHeight, width: SideTabGeometry.sensorWidth, height: totalHeight)
        let mouse = NSEvent.mouseLocation
        let expanded = sensor.contains(mouse)
        for (index, item) in items.enumerated() {
            let y = top - CGFloat(index) * (SideTabGeometry.height + SideTabGeometry.spacing) - SideTabGeometry.height
            let hovered = expanded && mouse.y >= y && mouse.y <= y + SideTabGeometry.height
            let width = SideTabGeometry.width(selected: state.groupID == item.1, expanded: expanded, hovered: hovered)
            let target = NSRect(x: right ? frame.maxX : frame.minX - width, y: y, width: width, height: SideTabGeometry.height)
            let window: NSPanel
            if let existing = windows[item.0] { window = existing }
            else {
                window = NSPanel(contentRect: target, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
                window.isReleasedWhenClosed = false; window.collectionBehavior = parent.collectionBehavior
                parent.addChildWindow(window, ordered: .below)
                windows[item.0] = window
            }
            window.appearance = parent.appearance
            window.level = parent.level
            let viewState = "\(item.2)|\(right)|\(expanded)|\(hovered)"
            if viewStates[item.0] != viewState {
                viewStates[item.0] = viewState
                let view = SideTabView(model: model, state: state, id: item.1, name: item.2, right: right, expanded: expanded, hovered: hovered)
                if let hosting = window.contentView as? DotistHostingView<SideTabView> { hosting.rootView = view }
                else { window.contentView = DotistHostingView(rootView: view) }
            }
            if targets[item.0] != target {
                let previous = targets[item.0]
                targets[item.0] = target
                // Parent movement follows immediately; only width changes animate.
                let animate = previous != nil && previous?.width != target.width && previous?.maxY == target.maxY && (right ? previous?.minX == target.minX : previous?.maxX == target.maxX) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if animate {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.18; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        window.animator().setFrame(target, display: true)
                    }
                } else { window.setFrame(target, display: true) }
            }
            if !shown || !window.isVisible { window.order(.below, relativeTo: parent.windowNumber) }
        }
        shown = true
    }
}
