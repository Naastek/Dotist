import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Screen coordinates, shared by the child window, hit testing and reorder preview.
enum SideTabGeometry {
    static let collapsedWidth: CGFloat = 10
    static let height: CGFloat = 34
    static let spacing: CGFloat = 4
    static let topInset: CGFloat = 40
    static let reorderDuration = 0.16
    static var stride: CGFloat { height + spacing }

    static func isRight(panelMinX: CGFloat, visibleMinX: CGFloat, expandedWidth: CGFloat) -> Bool {
        panelMinX - expandedWidth < visibleMinX
    }
    static func expandedWidth(textWidth: CGFloat) -> CGFloat { max(48, ceil(textWidth) + 28) }
    static func width(expanded: Bool, fullWidth: CGFloat) -> CGFloat { expanded ? fullWidth : collapsedWidth }
    static func frame(panel: CGRect, index: Int, width: CGFloat, right: Bool, offsetY: CGFloat = 0) -> CGRect {
        CGRect(x: right ? panel.maxX : panel.minX - width,
               y: panel.maxY - topInset - CGFloat(index) * stride - height + offsetY,
               width: width, height: height)
    }
    static func windowFrame(panel: CGRect, count: Int, width: CGFloat, right: Bool) -> CGRect {
        let total = CGFloat(max(1, count)) * stride - spacing
        return CGRect(x: right ? panel.maxX : panel.minX - width,
                      y: panel.maxY - topInset - total, width: width, height: total)
    }
    static func isDrag(_ delta: CGPoint) -> Bool { hypot(delta.x, delta.y) > 4 }
    /// Index is in visibleGroups; the fixed All tab is outside this coordinate space.
    static func destination(source: Int, screenDeltaY: CGFloat, count: Int) -> Int {
        min(max(0, source + Int((-screenDeltaY / stride).rounded())), max(0, count - 1))
    }
    static func reordered(_ ids: [String], id: String, to index: Int) -> [String] {
        guard let source = ids.firstIndex(of: id) else { return ids }
        var result = ids
        result.remove(at: source)
        result.insert(id, at: min(max(0, index), result.count))
        return result
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

private struct SideTabLayout: Equatable, Identifiable {
    let id: String
    let groupID: String?
    let name: String
    let rect: CGRect
    let dragged: Bool
}

@MainActor
private final class SideTabPresentation: ObservableObject {
    @Published var rows: [SideTabLayout] = []
    @Published var size: CGSize = .zero
    @Published var right = false
    @Published var expanded = false
    @Published var hovered: String?
    @Published var visible = false
}

private struct SideTabView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: TaskPanelState
    let row: SideTabLayout
    let right: Bool
    let expanded: Bool
    let hovered: Bool
    let pointer: (String, NSEvent.EventType, CGPoint) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var selected: Bool { state.groupID == row.groupID }

    var body: some View {
        let shape = SideTabShape(right: right)
        ZStack {
            if reduceTransparency {
                shape.fill(DotistDesign.paper)
                    .overlay(shape.fill(DotistTheme.tint(model.themeColor(forGroup: row.groupID), scheme)))
            } else {
                shape.fill(DotistDesign.paper.opacity(selected ? 0.28 : 0.06))
                    .glassEffect(.regular.tint(DotistTheme.tint(model.themeColor(forGroup: row.groupID), scheme)), in: shape)
                    .opacity(selected ? 1 : 0.72)
            }
            if expanded {
                Text(model.text(row.name))
                    .font(DotistDesign.font(13, weight: selected ? .semibold : .regular, serif: true, language: model.language))
                    .foregroundColor(selected ? DotistDesign.ink : hovered ? DotistDesign.muted : DotistDesign.faint)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: right ? .leading : .trailing)
                    .padding(.horizontal, 14)
                    .clipped()
            }
        }
        .frame(width: row.rect.width, height: row.rect.height)
        .shadow(color: .black.opacity(row.dragged ? 0.18 : 0), radius: row.dragged ? 7 : 0, y: row.dragged ? 3 : 0)
        .overlay(SideTabPointer { type, location in pointer(row.id, type, location) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(model.text(row.name)))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { state.groupID = row.groupID }
        .accessibilityIdentifier("side-tab:\(row.id)")
    }
}

private struct SideTabsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: TaskPanelState
    @ObservedObject var presentation: SideTabPresentation
    let pointer: (String, NSEvent.EventType, CGPoint) -> Void
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: SideTabGeometry.spacing) {
            ZStack(alignment: .topLeading) {
                ForEach(presentation.rows) { row in
                    SideTabView(model: model, state: state, row: row, right: presentation.right,
                                expanded: presentation.expanded, hovered: presentation.hovered == row.id, pointer: pointer)
                        .glassEffectID(row.id, in: glass)
                        .position(x: row.rect.midX, y: presentation.size.height - row.rect.midY)
                        .zIndex(row.dragged ? 1 : 0)
                        // The lifted tab follows the pointer directly. Only its neighbors make room.
                        .animation(reduceMotion || row.dragged ? nil : .easeOut(duration: SideTabGeometry.reorderDuration), value: row.rect.origin.y)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: presentation.expanded)
                }
            }
            .frame(width: presentation.size.width, height: presentation.size.height)
        }
        .modifier(DotistTheme(theme: model.settings.theme))
        .accessibilityHidden(!presentation.visible)
    }
}

/// Native mouse capture stays attached to the pressed tab while the preview reorders.
/// This view never calls performDrag, so a tab cannot move either NSPanel.
private struct SideTabPointer: NSViewRepresentable {
    let event: (NSEvent.EventType, CGPoint) -> Void
    func makeNSView(context: Context) -> PointerView { PointerView(event: event) }
    func updateNSView(_ view: PointerView, context: Context) { view.event = event }

    final class PointerView: NSView {
        var event: (NSEvent.EventType, CGPoint) -> Void
        init(event: @escaping (NSEvent.EventType, CGPoint) -> Void) { self.event = event; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) { send(event) }
        override func mouseDragged(with event: NSEvent) { send(event) }
        override func mouseUp(with event: NSEvent) { send(event) }
        private func send(_ value: NSEvent) {
            event(value.type, value.window?.convertPoint(toScreen: value.locationInWindow) ?? NSEvent.mouseLocation)
        }
    }
}

@MainActor
private final class SideTabDisplayTarget: NSObject {
    weak var controller: SideTabsController?
    @objc func tick(_ link: CADisplayLink) { controller?.synchronize() }
}

/// A single transparent child gives all tabs one glass container. Window-level mouse
/// passthrough keeps the unused area (including the gaps) out of the hit-test surface.
@MainActor
final class SideTabsController: NSObject {
    private let parent: NSPanel
    private let model: AppModel
    private let state: TaskPanelState
    private let motion: PanelMotion
    private let window: NSPanel
    private let presentation = SideTabPresentation()
    private let displayTarget = SideTabDisplayTarget()
    private var displayLink: CADisplayLink?
    private var observers: [NSObjectProtocol] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var expanded = false
    private var leftSensorAt: Date?
    private var press: (id: String, point: CGPoint, order: [String], expanded: Bool)?
    private var dragging = false
    private var deltaY: CGFloat = 0
    private var preview: [String]?
    private var pendingOrder: [String]?
    private var measuredWidths: [String: CGFloat] = [:]
    private var stopped = false

    init(parent: NSPanel, model: AppModel, state: TaskPanelState, motion: PanelMotion) {
        self.parent = parent; self.model = model; self.state = state; self.motion = motion
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.alphaValue = 0
        window.isReleasedWhenClosed = false; window.isMovable = false; window.isMovableByWindowBackground = false
        window.collectionBehavior = parent.collectionBehavior
        let host = DotistHostingView(rootView: SideTabsView(model: model, state: state, presentation: presentation) { [weak self] in self?.pointer($0, type: $1, at: $2) })
        host.sizingOptions = []
        window.contentView = host
        parent.addChildWindow(window, ordered: .below)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.synchronize() }
            })
        }
        // Unlike a default-mode Timer, this runs during live dragging, live resize,
        // and every frame of PanelMotion's animator().setFrame animation.
        displayTarget.controller = self
        displayLink = parent.displayLink(target: displayTarget, selector: #selector(SideTabDisplayTarget.tick(_:)))
        displayLink?.add(to: .main, forMode: .common)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53, self.press != nil {
                self.cancelDrag(); self.synchronize(); return nil
            }
            self.synchronize()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.synchronize() }
        synchronize()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        displayLink?.invalidate(); displayLink = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        parent.removeChildWindow(window); window.close()
    }

    private func cancelDrag() {
        press = nil; dragging = false; deltaY = 0; preview = nil
    }

    private func pointer(_ id: String, type: NSEvent.EventType, at point: CGPoint) {
        switch type {
        case .leftMouseDown:
            press = (id, point, model.visibleGroups.map(\.id), expanded)
        case .leftMouseDragged:
            guard let press else { return }
            let delta = CGPoint(x: point.x - press.point.x, y: point.y - press.point.y)
            if SideTabGeometry.isDrag(delta) { dragging = true }
            if dragging, press.expanded, let source = press.order.firstIndex(of: press.id) {
                expanded = true; leftSensorAt = nil
                deltaY = min(max(delta.y, -CGFloat(press.order.count - 1 - source) * SideTabGeometry.stride), CGFloat(source) * SideTabGeometry.stride)
                preview = SideTabGeometry.reordered(press.order, id: press.id,
                    to: SideTabGeometry.destination(source: source, screenDeltaY: deltaY, count: press.order.count))
            }
        case .leftMouseUp:
            guard let press else { return }
            if dragging, let preview, let destination = preview.firstIndex(of: press.id), preview != press.order {
                pendingOrder = preview
                model.moveGroup(press.id, toIndex: destination)
            } else if !dragging {
                state.groupID = press.id == "all" ? nil : press.id
            }
            cancelDrag()
            leftSensorAt = nil
        default: break
        }
        synchronize()
    }

    func synchronize(mouse: CGPoint = NSEvent.mouseLocation) {
        guard !stopped else { return }
        let groups = model.visibleGroups
        let ids = groups.map(\.id)
        if let press, press.order != ids { cancelDrag() }
        if let pendingOrder, pendingOrder == ids || !model.busy { self.pendingOrder = nil }
        let order = preview ?? pendingOrder ?? ids
        let names = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        let items = [(id: "all", groupID: Optional<String>.none, name: "全部")] + order.compactMap { id in
            names[id].map { (id: id, groupID: Optional(id), name: $0) }
        }
        let widths = items.map { item -> CGFloat in
            let name = model.text(item.name) as NSString
            let key = "\(model.language)|\(name)"
            if let measured = measuredWidths[key] { return measured }
            let regular = DotistDesign.nativeFont(13, serif: true, language: model.language)
            let semibold = DotistDesign.nativeFont(13, weight: .semibold, serif: true, language: model.language)
            let measured = SideTabGeometry.expandedWidth(textWidth: max(name.size(withAttributes: [.font: regular]).width, name.size(withAttributes: [.font: semibold]).width))
            measuredWidths[key] = measured
            return measured
        }
        let maxWidth = widths.max() ?? SideTabGeometry.collapsedWidth
        let frame = parent.frame
        let right = SideTabGeometry.isRight(panelMinX: frame.minX,
            visibleMinX: (parent.screen ?? NSScreen.main)?.visibleFrame.minX ?? frame.minX, expandedWidth: maxWidth)
        let bounds = SideTabGeometry.windowFrame(panel: frame, count: items.count, width: maxWidth, right: right)
        // Compare to the actual child frame: AppKit already translates child windows
        // when the parent moves, so cached last-target frames are not authoritative.
        if window.frame != bounds { window.setFrame(bounds, display: true) }
        window.appearance = parent.appearance; window.level = parent.level

        let currentRects = items.indices.map { SideTabGeometry.frame(panel: frame, index: $0,
            width: SideTabGeometry.width(expanded: expanded, fullWidth: widths[$0]), right: right) }
        let sensor = SideTabGeometry.windowFrame(panel: frame, count: items.count,
            width: expanded ? maxWidth : SideTabGeometry.collapsedWidth, right: right)
        let overTab = currentRects.contains { $0.contains(mouse) }
        if press != nil {
            leftSensorAt = nil
        } else if sensor.contains(mouse) && (expanded || overTab) {
            expanded = true; leftSensorAt = nil
        } else if expanded {
            if let leftSensorAt {
                if Date().timeIntervalSince(leftSensorAt) >= 0.15 { expanded = false; self.leftSensorAt = nil }
            } else { leftSensorAt = Date() }
        }
        var hitRects: [CGRect] = []
        let rows = items.enumerated().map { index, item -> SideTabLayout in
            let lifted = dragging && preview != nil && press?.id == item.id
            let slot = lifted ? (press!.order.firstIndex(of: item.id)! + 1) : index
            let rect = SideTabGeometry.frame(panel: frame, index: slot,
                width: SideTabGeometry.width(expanded: expanded, fullWidth: widths[index]), right: right,
                offsetY: lifted ? deltaY : 0)
            hitRects.append(rect)
            return SideTabLayout(id: item.id, groupID: item.groupID, name: item.name,
                rect: rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY), dragged: lifted)
        }
        if presentation.size != bounds.size { presentation.size = bounds.size }
        if presentation.right != right { presentation.right = right }
        if presentation.expanded != expanded { presentation.expanded = expanded }
        if presentation.rows != rows { presentation.rows = rows }
        let hovered = zip(items, hitRects).first { $0.1.contains(mouse) }?.0.id
        if presentation.hovered != hovered { presentation.hovered = hovered }
        let visible = parent.isVisible && parent.isOnActiveSpace && !motion.bubble && !motion.animationInProgress
        if presentation.visible != visible { presentation.visible = visible }
        window.ignoresMouseEvents = !visible || (press == nil && !hitRects.contains { $0.contains(mouse) })
        window.alphaValue = visible ? parent.alphaValue : 0
        if visible {
            if window.parent !== parent { parent.addChildWindow(window, ordered: .below) }
            if !window.isVisible { window.order(.below, relativeTo: parent.windowNumber) }
        } else {
            // Frames continue synchronizing while collapsed or animating. On expansion
            // there is never a stale child frame to flash at the old panel location.
            // orderOut removes an NSWindow from its parent. Keep an invisible child
            // instead, otherwise the first collapse silently breaks drag following.
            expanded = false; leftSensorAt = nil; cancelDrag()
        }
    }
}
