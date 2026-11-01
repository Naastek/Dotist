import AppKit
import Combine
import DotistCore
import QuartzCore
import SwiftUI

/// Screen coordinates, shared by the child window, hit testing and reorder preview.
enum SideTabGeometry {
    static let collapsedWidth: CGFloat = 10
    static let height: CGFloat = 34
    static let spacing: CGFloat = 6
    static let topInset: CGFloat = 40
    static let reorderDuration = 0.16
    static let expansionDuration = 0.16
    static let collapseDelay = 0.12
    static let shadowInset: CGFloat = 0
    static var stride: CGFloat { height + spacing }

    static let modeHysteresis: CGFloat = 80

    static func expandsInward(availableSpace: CGFloat, expandedWidth: CGFloat, wasInward: Bool) -> Bool {
        wasInward ? availableSpace <= expandedWidth + modeHysteresis : availableSpace < expandedWidth
    }
    static func x(panel: CGRect, width: CGFloat, inward: Bool, visibleMinX: CGFloat?) -> CGFloat {
        inward ? max(panel.minX - collapsedWidth, visibleMinX ?? panel.minX) : panel.minX - width
    }
    static func childOrder(inward: Bool, expanded: Bool, progress: CGFloat) -> NSWindow.OrderingMode {
        inward && (expanded || progress > 0) ? .above : .below
    }
    static func expandedWidth(textWidth: CGFloat) -> CGFloat { max(48, ceil(textWidth) + 28) }
    static func expandedWidth(name: String, language: String) -> CGFloat {
        let text = name as NSString
        return expandedWidth(textWidth: max(
            text.size(withAttributes: [.font: DotistDesign.nativeFont(13, serif: true, language: language)]).width,
            text.size(withAttributes: [.font: DotistDesign.nativeFont(13, weight: .semibold, serif: true, language: language)]).width))
    }
    static func width(expanded: Bool, fullWidth: CGFloat) -> CGFloat { expanded ? fullWidth : collapsedWidth }
    static func frame(panel: CGRect, index: Int, width: CGFloat, inward: Bool, visibleMinX: CGFloat? = nil, offsetY: CGFloat = 0) -> CGRect {
        CGRect(x: x(panel: panel, width: width, inward: inward, visibleMinX: visibleMinX),
               y: panel.maxY - topInset - CGFloat(index) * stride - height + offsetY,
               width: width, height: height)
    }
    static func windowFrame(panel: CGRect, count: Int, width: CGFloat, inward: Bool, visibleMinX: CGFloat? = nil) -> CGRect {
        let total = CGFloat(max(1, count)) * stride - spacing
        return CGRect(x: x(panel: panel, width: width, inward: inward, visibleMinX: visibleMinX),
                      y: panel.maxY - topInset - total, width: width, height: total)
    }
    /// One sample drives the window, glass geometry, text reveal and mouse regions.
    struct Snapshot {
        let window: CGRect
        let tabs: [CGRect]
        let textOpacity: Double
    }
    static func snapshot(panel: CGRect, fullWidths: [CGFloat], progress: CGFloat, inward: Bool, visibleMinX: CGFloat? = nil) -> Snapshot {
        let progress = min(1, max(0, progress))
        let widths = fullWidths.map { collapsedWidth + ($0 - collapsedWidth) * progress }
        let bounds = windowFrame(panel: panel, count: widths.count, width: widths.max() ?? collapsedWidth, inward: inward, visibleMinX: visibleMinX)
            .insetBy(dx: -shadowInset, dy: -shadowInset)
        return Snapshot(window: bounds, tabs: widths.enumerated().map {
            frame(panel: panel, index: $0.offset, width: $0.element, inward: inward, visibleMinX: visibleMinX)
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

/// Latch the requested direction independently of the displayed direction. Small
/// reversals while retracting cannot cancel a switch or flip the shape mid-flight.
struct SideTabPlacement {
    private(set) var inward = false
    private(set) var requestedInward = false
    private var initialized = false
    var needsCollapse: Bool { inward != requestedInward }

    mutating func update(availableSpace: CGFloat, expandedWidth: CGFloat, progress: CGFloat, canSwitch: Bool = true) {
        requestedInward = SideTabGeometry.expandsInward(availableSpace: availableSpace,
            expandedWidth: expandedWidth, wasInward: initialized && requestedInward)
        if !initialized || (progress == 0 && canSwitch) { inward = requestedInward }
        initialized = true
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
    let inward: Bool
    func path(in rect: CGRect) -> Path {
        let r = min(8, rect.width, rect.height / 2)
        var p = Path()
        if inward {
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
    @Published var inward = false
    @Published var textOpacity = 0.0
    @Published var hovered: String?
    @Published var visible = false
}

/// A detached, transparent child panel has no in-window backdrop to sample.
/// Paper is the reliable default there and in ImageRenderer. A host with a real
/// backdrop can opt into glass; only the background enters that effect graph.
enum SideTabSurfaceStyle {
    case paper
    case glass
}

private struct SideTabSurfaceStyleKey: EnvironmentKey {
    static let defaultValue = SideTabSurfaceStyle.paper
}

extension EnvironmentValues {
    var sideTabSurfaceStyle: SideTabSurfaceStyle {
        get { self[SideTabSurfaceStyleKey.self] }
        set { self[SideTabSurfaceStyleKey.self] = newValue }
    }
}

private struct SideTabBackground: View {
    let color: DotistGroupColor
    let selected: Bool
    let inward: Bool
    @Environment(\.sideTabSurfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = SideTabShape(inward: inward)
        ZStack {
            // This underlay also protects contrast if a glass host loses sampling.
            shape.fill(DotistDesign.paper.opacity(reduceTransparency || contrast == .increased ? 1 : selected ? 0.92 : 0.85))
            shape.fill(DotistTheme.swatch(color).opacity(selected ? 0.12 : 0.06))
            if style == .glass && !reduceTransparency && contrast != .increased {
                Color.clear
                    .glassEffect(.regular.tint(DotistTheme.tint(color, scheme).opacity(selected ? 1 : 0.5)), in: shape)
            }
            shape.stroke(DotistDesign.faint.opacity(selected ? 0.45 : 0.35), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }
}

/// Foreground is an ordinary sibling of the material, never part of a glass ID,
/// mask or effect container. Its layout always uses the expanded width.
struct SideTabLabel: View {
    let name: String
    let language: String
    let selected: Bool
    let hovered: Bool
    // Compatibility with the optical label harness: this is the reveal direction,
    // never a choice of which side of the panel hosts the tabs.
    let right: Bool
    let width: CGFloat
    let fullWidth: CGFloat
    let textOpacity: Double

    var body: some View {
        OpticalText(title: name, size: 13, weight: selected ? .semibold : .regular, serif: true, language: language)
            .foregroundStyle(selected || hovered ? DotistDesign.ink : DotistDesign.faint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(width: fullWidth, height: SideTabGeometry.height, alignment: .leading)
            .frame(width: width, height: SideTabGeometry.height, alignment: right ? .leading : .trailing)
            .clipped()
            .opacity(textOpacity)
            .allowsHitTesting(false)
    }
}

private struct SideTabContent: View {
    let row: SideTabLayout
    let language: String
    let color: DotistGroupColor
    let selected: Bool
    let hovered: Bool
    let inward: Bool
    let textOpacity: Double

    var body: some View {
        ZStack(alignment: inward ? .leading : .trailing) {
            SideTabBackground(color: color, selected: selected, inward: inward)
                .frame(width: row.rect.width, height: SideTabGeometry.height)
            SideTabLabel(name: row.name, language: language, selected: selected,
                         hovered: hovered, right: inward, width: row.rect.width,
                         fullWidth: row.fullWidth, textOpacity: textOpacity)
        }
        .frame(width: row.rect.width, height: SideTabGeometry.height)
        .clipped()
    }
}

/// The live host and raster snapshots share this entire tree, including surfaces,
/// label clipping and absolute tab positions. Each tab has an independent surface.
private struct SideTabsCanvas: View {
    let rows: [SideTabLayout]
    let size: CGSize
    let language: String
    let selectedGroupID: String?
    let hovered: String?
    let inward: Bool
    let textOpacity: Double
    let color: (String?) -> DotistGroupColor
    var pointer: ((String, NSEvent.EventType, CGPoint) -> Void)?
    var select: ((String?) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: size.width, height: size.height)
            ForEach(rows) { row in
                SideTabContent(row: row, language: language, color: color(row.groupID),
                    selected: selectedGroupID == row.groupID, hovered: hovered == row.id,
                    inward: inward, textOpacity: textOpacity)
                    .overlay {
                        if let pointer {
                            SideTabPointer { type, location in pointer(row.id, type, location) }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(row.name))
                    .accessibilityAddTraits(selectedGroupID == row.groupID ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { select?(row.groupID) }
                    .accessibilityIdentifier("side-tab:\(row.id)")
                    .offset(x: row.rect.minX)
                    // Width and horizontal attachment use the controller's sample
                    // directly; only reorder movement gets a SwiftUI animation.
                    .animation(reduceMotion || row.dragged ? nil : .easeOut(duration: SideTabGeometry.reorderDuration)) { content in
                        content.offset(y: size.height - row.rect.maxY)
                    }
                    .zIndex(row.dragged ? 1 : 0)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private struct SideTabsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: TaskPanelState
    @ObservedObject var presentation: SideTabPresentation
    let pointer: (String, NSEvent.EventType, CGPoint) -> Void

    var body: some View {
        SideTabsCanvas(rows: presentation.rows, size: presentation.size, language: model.language,
            selectedGroupID: state.groupID, hovered: presentation.hovered, inward: presentation.inward,
            textOpacity: presentation.textOpacity, color: { model.themeColor(forGroup: $0) },
            pointer: pointer, select: { state.groupID = $0 })
            .environment(\.sideTabSurfaceStyle, .paper)
            .modifier(DotistTheme(theme: model.settings.theme))
            .accessibilityHidden(!presentation.visible)
    }
}

/// Callable offscreen entry point. Rectangles use bitmap coordinates (top down).
/// Rendering paper is intentional: ImageRenderer cannot sample Liquid Glass.
@MainActor
struct SideTabsSnapshot {
    let image: CGImage
    let tabs: [CGRect]

    static func render(names: [String], language: String, scheme: ColorScheme,
                       inward: Bool, expanded: Bool, showLabels: Bool = true) -> SideTabsSnapshot? {
        let widths = names.map { SideTabGeometry.expandedWidth(name: $0, language: language) }
        let panel = CGRect(x: widths.max() ?? 48, y: 0, width: 364, height: 620)
        let sample = SideTabGeometry.snapshot(panel: panel, fullWidths: widths, progress: expanded ? 1 : 0, inward: inward)
        let rows = names.enumerated().map { index, name in
            SideTabLayout(id: String(index), groupID: String(index), name: name,
                rect: sample.tabs[index].offsetBy(dx: -sample.window.minX, dy: -sample.window.minY),
                fullWidth: widths[index], dragged: false)
        }
        let content = SideTabsCanvas(rows: rows, size: sample.window.size, language: language,
            selectedGroupID: "0", hovered: nil, inward: inward, textOpacity: showLabels ? sample.textOpacity : 0,
            color: { _ in .teal })
            .environment(\.sideTabSurfaceStyle, .paper)
            .environment(\.colorScheme, scheme)
            .transaction { $0.disablesAnimations = true }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(sample.window.size)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        var image: CGImage?
        appearance?.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        guard let image else { return nil }
        return SideTabsSnapshot(image: image, tabs: rows.map {
            CGRect(x: $0.rect.minX, y: sample.window.height - $0.rect.maxY,
                   width: $0.rect.width, height: $0.rect.height)
        })
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
    var screenHitRects: [CGRect]?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let screenHitRects, let window {
            let windowPoint = superview?.convert(point, to: nil) ?? point
            let screenPoint = window.convertPoint(toScreen: windowPoint)
            guard screenHitRects.contains(where: { $0.contains(screenPoint) }) else { return nil }
        }
        return super.hitTest(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class SideTabDisplayTarget: NSObject {
    weak var controller: SideTabsController?
    @objc func tick(_ link: CADisplayLink) { controller?.synchronize() }
}

/// A transparent child hosts independently painted tabs. Window-level mouse
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
    private var placement = SideTabPlacement()
    private var childOrder: NSWindow.OrderingMode = .below
    private var restingHost: SideTabHostingView<SideTabsView>?

    init(parent: NSPanel, model: AppModel, state: TaskPanelState, motion: PanelMotion) {
        self.parent = parent; self.model = model; self.state = state; self.motion = motion
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.identifier = NSUserInterfaceItemIdentifier("dotist.side-tabs")
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
        // The actual tab window rests below the parent. At the screen edge its
        // 10pt ear would be covered by the panel, so paint just that resting ear
        // in the parent's content view, using the same tree and native capture.
        // This host disappears as soon as the child is promoted for expansion.
        let resting = SideTabHostingView(rootView: host.rootView)
        resting.identifier = NSUserInterfaceItemIdentifier("dotist.side-tabs-rest")
        resting.sizingOptions = []
        resting.safeAreaRegions = []
        resting.isHidden = true
        restingHost = resting
        parent.contentView?.addSubview(resting)
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
        restingHost?.removeFromSuperview(); restingHost = nil
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
            let name = model.text(item.name)
            let key = "\(DotistDesign.fontCacheKey)|\(model.language)|\(name)"
            if let measured = measuredWidths[key] { return measured }
            let measured = SideTabGeometry.expandedWidth(name: name, language: model.language)
            measuredWidths[key] = measured
            return measured
        }
        let maxWidth = widths.max() ?? SideTabGeometry.collapsedWidth
        let frame = parent.frame
        let visibleMinX = (parent.screen ?? NSScreen.main)?.visibleFrame.minX ?? frame.minX
        let now = CACurrentMediaTime()
        placement.update(availableSpace: frame.minX - visibleMinX, expandedWidth: maxWidth,
            progress: expansion.progress(at: now), canSwitch: press == nil)
        var inward = placement.inward
        let visible = parent.isVisible && parent.isOnActiveSpace && !motion.bubble && !motion.animationInProgress
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let current = SideTabGeometry.snapshot(panel: frame, fullWidths: widths,
            progress: expansion.progress(at: now), inward: inward, visibleMinX: visibleMinX)
        let sensor = SideTabGeometry.windowFrame(panel: frame, count: items.count,
            width: expanded ? maxWidth : SideTabGeometry.collapsedWidth, inward: inward, visibleMinX: visibleMinX)
        let overTab = current.tabs.contains { $0.contains(mouse) }
        if !visible {
            expanded = false; collapseWork?.cancel(); collapseWork = nil; cancelDrag()
        } else if placement.needsCollapse && press == nil {
            expanded = false; collapseWork?.cancel(); collapseWork = nil
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
        if placement.needsCollapse && expansion.progress(at: now) == 0 && press == nil {
            // Reduced motion can finish retraction in this call. Apply the new
            // collapsed anchor before compositing, avoiding an offscreen frame.
            placement.update(availableSpace: frame.minX - visibleMinX, expandedWidth: maxWidth, progress: 0)
            inward = placement.inward
        }
        let sample = SideTabGeometry.snapshot(panel: frame, fullWidths: widths,
            progress: expansion.progress(at: now), inward: inward, visibleMinX: visibleMinX)
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
                width: sample.tabs[index].width, inward: inward, visibleMinX: visibleMinX,
                offsetY: lifted ? deltaY : 0)
            hitRects.append(rect)
            return SideTabLayout(id: item.id, groupID: item.groupID, name: model.text(item.name),
                rect: rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY), fullWidth: widths[index], dragged: lifted)
        }
        if presentation.size != bounds.size { presentation.size = bounds.size }
        if presentation.inward != inward { presentation.inward = inward }
        if presentation.textOpacity != sample.textOpacity { presentation.textOpacity = sample.textOpacity }
        if presentation.rows != rows { presentation.rows = rows }
        // Resolve the new SwiftUI layout before the resized child is composited.
        window.contentView?.layoutSubtreeIfNeeded()
        let hovered = zip(items, hitRects).first { $0.1.contains(mouse) }?.0.id
        if presentation.hovered != hovered { presentation.hovered = hovered }
        if presentation.visible != visible { presentation.visible = visible }
        window.ignoresMouseEvents = !visible || (press == nil && !hitRects.contains { $0.contains(mouse) })
        window.alphaValue = visible ? parent.alphaValue : 0
        let ordering = SideTabGeometry.childOrder(inward: inward, expanded: expanded,
            progress: expansion.progress(at: now))
        if let restingHost {
            restingHost.frame = parent.contentView?.convert(parent.convertFromScreen(bounds), from: nil) ?? .zero
            restingHost.screenHitRects = hitRects
            restingHost.isHidden = !visible || !inward || ordering == .above || bounds.maxX <= frame.minX
            restingHost.layoutSubtreeIfNeeded()
        }
        if visible {
            if window.parent !== parent || childOrder != ordering {
                // AppKit preserves the ordering relationship established by
                // addChildWindow; order(relativeTo:) cannot change that side.
                // Reattach synchronously without hiding either window.
                window.parent?.removeChildWindow(window)
                parent.addChildWindow(window, ordered: ordering)
            }
            if !window.isVisible { window.order(ordering, relativeTo: parent.windowNumber) }
            childOrder = ordering
        } else {
            // Frames continue synchronizing while collapsed or animating. On expansion
            // there is never a stale child frame to flash at the old panel location.
            // orderOut removes an NSWindow from its parent. Keep an invisible child
            // instead, otherwise the first collapse silently breaks drag following.
            expanded = false; collapseWork?.cancel(); collapseWork = nil; cancelDrag()
        }
    }
}
