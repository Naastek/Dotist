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
    static let expansionDuration = 0.16
    static let collapseDelay = 0.12
    static let shadowInset: CGFloat = 24
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
    /// One sample drives the window, glass geometry, text reveal and mouse regions.
    struct Snapshot {
        let window: CGRect
        let tabs: [CGRect]
        let textOpacity: Double
    }
    static func snapshot(panel: CGRect, fullWidths: [CGFloat], progress: CGFloat, right: Bool) -> Snapshot {
        let progress = min(1, max(0, progress))
        let widths = fullWidths.map { collapsedWidth + ($0 - collapsedWidth) * progress }
        let bounds = windowFrame(panel: panel, count: widths.count, width: widths.max() ?? collapsedWidth, right: right)
            .insetBy(dx: -shadowInset, dy: -shadowInset)
        return Snapshot(window: bounds, tabs: widths.enumerated().map {
            frame(panel: panel, index: $0.offset, width: $0.element, right: right)
        }, textOpacity: Double(progress))
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

/// Retarget from the current presentation so quick pointer reversals never jump.
struct SideTabExpansion {
    private(set) var target: CGFloat = 0
    private var origin: CGFloat = 0
    private var started: TimeInterval = 0

    func progress(at time: TimeInterval) -> CGFloat {
        let t = min(1, max(0, (time - started) / SideTabGeometry.expansionDuration))
        let eased = UnitCurve.easeOut.value(at: t)
        return origin + (target - origin) * CGFloat(eased)
    }
    mutating func setExpanded(_ expanded: Bool, at time: TimeInterval, reduceMotion: Bool) {
        let next: CGFloat = expanded ? 1 : 0
        let current = progress(at: time)
        if next != target { origin = current; started = time; target = next }
        if reduceMotion { origin = next; target = next }
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
    let fullWidth: CGFloat
    let dragged: Bool
}

@MainActor
private final class SideTabPresentation: ObservableObject {
    @Published var rows: [SideTabLayout] = []
    @Published var size: CGSize = .zero
    @Published var right = false
    @Published var textOpacity = 0.0
    @Published var hovered: String?
    @Published var visible = false
}

private struct SideTabView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: TaskPanelState
    let row: SideTabLayout
    let right: Bool
    let textOpacity: Double
    let glass: Namespace.ID
    let hovered: Bool
    let pointer: (String, NSEvent.EventType, CGPoint) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var selected: Bool { state.groupID == row.groupID }

    var body: some View {
        let shape = SideTabShape(right: right)
        // Size the material before applying glass. Its ID belongs only to the
        // material: including the foreground in a glass morph can swallow text.
        Group {
            if reduceTransparency {
                shape.fill(DotistDesign.paper)
                    .overlay(shape.fill(DotistTheme.tint(model.themeColor(forGroup: row.groupID), scheme)))
            } else {
                Color.clear
                    .frame(width: row.rect.width, height: row.rect.height)
                    .glassEffect(.regular.tint(DotistTheme.tint(model.themeColor(forGroup: row.groupID), scheme)), in: shape)
                    .glassEffectID(row.id, in: glass)
            }
        }
        .frame(width: row.rect.width, height: row.rect.height)
        .overlay {
            // Always lay out the full label, outside the glass effect. Reveal it
            // inside the current width, never remeasure it at the narrow edge.
            SideTabLabel(name: model.text(row.name), language: model.language,
                         selected: selected, hovered: hovered, right: right,
                         width: row.rect.width, fullWidth: row.fullWidth, textOpacity: textOpacity)
        }
        .shadow(color: .black.opacity(row.dragged ? 0.18 : 0), radius: row.dragged ? 7 : 0, y: row.dragged ? 3 : 0)
        .overlay(SideTabPointer { type, location in pointer(row.id, type, location) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(model.text(row.name)))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { state.groupID = row.groupID }
        .accessibilityIdentifier("side-tab:\(row.id)")
    }
}

/// Foreground stays separate from the glass graph and keeps its expanded layout.
struct SideTabLabel: View {
    let name: String
    let language: String
    let selected: Bool
    let hovered: Bool
    let right: Bool
    let width: CGFloat
    let fullWidth: CGFloat
    let textOpacity: Double

    var body: some View {
        Text(name)
            .font(DotistDesign.font(13, weight: selected ? .semibold : .regular, serif: true, language: language))
            .foregroundStyle(selected || hovered ? DotistDesign.ink : DotistDesign.faint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: max(0, fullWidth - 28), height: SideTabGeometry.height,
                   alignment: right ? .leading : .trailing)
            .padding(.horizontal, 14)
            .frame(width: width, height: SideTabGeometry.height, alignment: right ? .leading : .trailing)
            .clipped()
            .opacity(textOpacity)
            .allowsHitTesting(false)
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
        GlassEffectContainer(spacing: SideTabGeometry.spacing * 2) {
            ZStack(alignment: .topLeading) {
                ForEach(presentation.rows) { row in
                    SideTabView(model: model, state: state, row: row, right: presentation.right,
                                textOpacity: presentation.textOpacity, glass: glass, hovered: presentation.hovered == row.id, pointer: pointer)
                        .position(x: row.rect.midX, y: 0)
                        // Scope animation to vertical reordering. Width, horizontal
                        // attachment and label opacity keep the controller's sample,
                        // even if a reorder starts before expansion has finished.
                        .animation(reduceMotion || row.dragged ? nil : .easeOut(duration: SideTabGeometry.reorderDuration)) { content in
                            content.offset(y: presentation.size.height - row.rect.midY)
                        }
                        .zIndex(row.dragged ? 1 : 0)
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

private final class SideTabHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    private var collapseWork: DispatchWorkItem?
    private var expansion = SideTabExpansion()
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
        let host = SideTabHostingView(rootView: SideTabsView(model: model, state: state, presentation: presentation) { [weak self] in self?.pointer($0, type: $1, at: $2) })
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.masksToBounds = false
        window.acceptsMouseMovedEvents = true
        parent.acceptsMouseMovedEvents = true
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
            guard event.type != .keyDown else { return event }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            self.synchronize(mouse: point)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.synchronize() }
        synchronize()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        collapseWork?.cancel(); collapseWork = nil
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
                expanded = true; collapseWork?.cancel(); collapseWork = nil
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
            collapseWork?.cancel(); collapseWork = nil
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
            visibleMinX: (parent.screen ?? NSScreen.main)?.visibleFrame.minX ?? frame.minX, expandedWidth: maxWidth + SideTabGeometry.shadowInset)
        let visible = parent.isVisible && parent.isOnActiveSpace && !motion.bubble && !motion.animationInProgress
        let now = CACurrentMediaTime()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let current = SideTabGeometry.snapshot(panel: frame, fullWidths: widths,
            progress: expansion.progress(at: now), right: right)
        let sensor = SideTabGeometry.windowFrame(panel: frame, count: items.count,
            width: expanded ? maxWidth : SideTabGeometry.collapsedWidth, right: right)
        let overTab = current.tabs.contains { $0.contains(mouse) }
        if !visible {
            expanded = false; collapseWork?.cancel(); collapseWork = nil; cancelDrag()
        } else if press != nil || overTab || (expanded && sensor.contains(mouse)) {
            expanded = true; collapseWork?.cancel(); collapseWork = nil
        } else if expanded && collapseWork == nil {
            // Event-triggered debounce; no extra polling interval is added.
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
                self.expanded = false
                // Keep the work present during synchronization, so it cannot
                // immediately schedule a second collapse while sampling motion.
                self.synchronize()
                self.collapseWork = nil
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + SideTabGeometry.collapseDelay, execute: work)
        }
        expansion.setExpanded(expanded, at: now, reduceMotion: reduceMotion || !visible)
        let sample = SideTabGeometry.snapshot(panel: frame, fullWidths: widths,
            progress: expansion.progress(at: now), right: right)
        let bounds = sample.window
        // AppKit moves child windows with the parent. Compare the actual frame,
        // then update frame + SwiftUI layout from the very same animation sample.
        if window.frame != bounds { window.setFrame(bounds, display: false) }
        if window.appearance != parent.appearance { window.appearance = parent.appearance }
        if window.level != parent.level { window.level = parent.level }
        var hitRects: [CGRect] = []
        let rows = items.enumerated().map { index, item -> SideTabLayout in
            let lifted = dragging && preview != nil && press?.id == item.id
            let slot = lifted ? (press!.order.firstIndex(of: item.id)! + 1) : index
            let rect = SideTabGeometry.frame(panel: frame, index: slot,
                width: sample.tabs[index].width, right: right,
                offsetY: lifted ? deltaY : 0)
            hitRects.append(rect)
            return SideTabLayout(id: item.id, groupID: item.groupID, name: item.name,
                rect: rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY), fullWidth: widths[index], dragged: lifted)
        }
        if presentation.size != bounds.size { presentation.size = bounds.size }
        if presentation.right != right { presentation.right = right }
        if presentation.textOpacity != sample.textOpacity { presentation.textOpacity = sample.textOpacity }
        if presentation.rows != rows { presentation.rows = rows }
        // Resolve the new SwiftUI layout before the resized child is composited.
        window.contentView?.layoutSubtreeIfNeeded()
        let hovered = zip(items, hitRects).first { $0.1.contains(mouse) }?.0.id
        if presentation.hovered != hovered { presentation.hovered = hovered }
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
            expanded = false; collapseWork?.cancel(); collapseWork = nil; cancelDrag()
        }
    }
}
