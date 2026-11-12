import AppKit
import Combine
import DotistCore
import QuartzCore
import SwiftUI

/// Screen coordinates, shared by the child window, hit testing and reorder preview.
enum SideTabGeometry {
    static let collapsedWidth: CGFloat = 10
    static let selectedWidth: CGFloat = 15
    static let attachmentOverlap = ExpandedReadingMaterial.opticalClearance + 1
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
        let opacities: [Double]
    }
    static func paintedFrame(_ rect: CGRect, inward: Bool) -> CGRect {
        var painted = rect
        if !inward { painted.size.width += attachmentOverlap }
        return painted
    }
    static func shadowRects(rows: [SideTabLayout], bounds: CGRect, panel: CGRect, painted: Bool, visible: Bool, inward: Bool) -> [CGRect] {
        guard painted, visible, !inward else { return [] }
        return rows.filter { $0.opacity > 0 }.map {
            paintedFrame($0.rect, inward: false).offsetBy(dx: bounds.minX - panel.minX, dy: bounds.minY - panel.minY)
        }
    }
    static func snapshot(panel: CGRect, fullWidths: [CGFloat], progress: CGFloat, inward: Bool, visibleMinX: CGFloat? = nil,
                         selectedIndex: Int? = nil, entrance: [CGFloat]? = nil) -> Snapshot {
        let progress = min(1, max(0, progress))
        let opacities = fullWidths.indices.map { Double(min(1, max(0, entrance?[$0] ?? 1))) }
        let widths = fullWidths.enumerated().map { index, fullWidth in
            let resting = index == selectedIndex ? selectedWidth : collapsedWidth
            let width = resting + (fullWidth - resting) * progress
            return max(0, width - 8 * (1 - CGFloat(opacities[index])))
        }
        let bounds = windowFrame(panel: panel, count: widths.count, width: widths.max() ?? collapsedWidth, inward: inward, visibleMinX: visibleMinX)
            .insetBy(dx: -shadowInset, dy: -shadowInset)
        return Snapshot(window: bounds, tabs: widths.enumerated().map {
            frame(panel: panel, index: $0.offset, width: $0.element, inward: inward, visibleMinX: visibleMinX)
        }, textOpacity: Double(progress), opacities: opacities)
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

/// Placement is independent of hover animation. The 80pt hysteresis prevents
/// jitter; only native mouse capture postpones an anchor change until release.
struct SideTabPlacement {
    private(set) var inward = false
    private(set) var requestedInward = false
    private var initialized = false
    mutating func update(availableSpace: CGFloat, expandedWidth: CGFloat, canSwitch: Bool = true) {
        requestedInward = SideTabGeometry.expandsInward(availableSpace: availableSpace,
            expandedWidth: expandedWidth, wasInward: initialized && requestedInward)
        if !initialized || canSwitch { inward = requestedInward }
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

/// ID-keyed tracks share the controller's existing display-link clock. Repeated
/// samples never restart a track; reversals begin at its current presentation.
struct SideTabEntrance {
    static let duration = 0.18
    static let interval = 0.035
    static let maximumDelay = 0.28
    private struct Track {
        var origin: CGFloat = 0
        var target: CGFloat = 0
        var started: TimeInterval = 0
        func value(at time: TimeInterval) -> CGFloat {
            let t = min(1, max(0, (time - started) / SideTabEntrance.duration))
            return origin + (target - origin) * CGFloat(UnitCurve.easeOut.value(at: t))
        }
    }
    private var tracks: [String: Track] = [:]

    mutating func update(ids: [String], visible: Bool, at time: TimeInterval, reduceMotion: Bool) {
        let target: CGFloat = visible ? 1 : 0
        let interval = min(Self.interval, Self.maximumDelay / Double(max(1, ids.count - 1)))
        let retained = Set(ids)
        tracks = tracks.filter { retained.contains($0.key) }
        for (index, id) in ids.enumerated() {
            var track = tracks[id] ?? Track()
            let current = track.value(at: time)
            if track.target != target {
                track.origin = current
                track.target = target
                track.started = time + (visible && current == 0 ? Double(index) * interval : 0)
            }
            if reduceMotion { track.origin = target; track.target = target; track.started = time }
            tracks[id] = track
        }
    }
    func values(ids: [String], at time: TimeInterval) -> [CGFloat] {
        ids.map { tracks[$0]?.value(at: time) ?? 0 }
    }
}

struct SideTabShape: Shape {
    let inward: Bool
    func path(in rect: CGRect) -> Path {
        let radius = min(8, rect.width / 2, rect.height / 2)
        // Outward tabs attach on the right; inward tabs attach on the left.
        // The connection edge stays square at every sampled expansion width.
        return UnevenRoundedRectangle(topLeadingRadius: inward ? 0 : radius,
            bottomLeadingRadius: inward ? 0 : radius,
            bottomTrailingRadius: inward ? radius : 0,
            topTrailingRadius: inward ? radius : 0, style: .continuous).path(in: rect)
    }
}

struct SideTabLayout: Equatable, Identifiable {
    let id: String
    let groupID: String?
    let name: String
    let rect: CGRect
    let fullWidth: CGFloat
    let dragged: Bool
    var opacity: Double = 1
    var interactive: Bool = true
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
/// A tint fill is the reliable default there and in ImageRenderer. A host with a real
/// backdrop can opt into glass; only the background enters that effect graph.
enum SideTabSurfaceStyle {
    case tint
    case glass
}

private struct SideTabSurfaceStyleKey: EnvironmentKey {
    static let defaultValue = SideTabSurfaceStyle.tint
}

/// Explicit rendering context for offscreen snapshots. The live canvas reads
/// the system accessibility environment instead; those system keys are read-only.
fileprivate struct SideTabAccessibility: EnvironmentKey {
    static let defaultValue: SideTabAccessibility? = nil
    let reduceTransparency: Bool
    let contrast: ColorSchemeContrast
}

extension EnvironmentValues {
    var sideTabSurfaceStyle: SideTabSurfaceStyle {
        get { self[SideTabSurfaceStyleKey.self] }
        set { self[SideTabSurfaceStyleKey.self] = newValue }
    }

    fileprivate var sideTabAccessibility: SideTabAccessibility? {
        get { self[SideTabAccessibility.self] }
        set { self[SideTabAccessibility.self] = newValue }
    }
}

private struct SideTabBackground: View {
    let inward: Bool
    let color: DotistGroupColor
    let selected: Bool
    let opacity: UInt8
    @Environment(\.sideTabSurfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sideTabAccessibility) private var accessibility

    var body: some View {
        let shape = SideTabShape(inward: inward)
        let reduceTransparency = accessibility?.reduceTransparency ?? self.reduceTransparency
        let contrast = accessibility?.contrast ?? self.contrast
        let alpha = reduceTransparency || contrast == .increased ? 1 : Double(min(100, opacity)) / 100
        ZStack {
            // This underlay also protects contrast if a glass host loses sampling.
            // Resolve one fill before rasterizing its silhouette. Stacking two
            // antialiased shapes produces a darker seam at low background alpha.
            shape.fill(DotistDesign.paper.mix(with: color == .none ? DotistDesign.ink : DotistTheme.swatch(color),
                by: selected ? (contrast == .increased ? GlassTintMaterial.tabHighContrastSelectedTint : GlassTintMaterial.tabSelectedTint) : GlassTintMaterial.tabUnselectedTint, in: .device))
            if style == .glass && !reduceTransparency && contrast != .increased {
                Color.clear
                    .glassEffect(.regular.tint(DotistTheme.tint(color, scheme).opacity(selected ? 1 : 0.5)), in: shape)
            }
        }
        // Composite first so tint cannot raise the configured alpha.
        // Foreground text lives outside this background group.
        .compositingGroup()
        .opacity(alpha)
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
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.sideTabAccessibility) private var accessibility

    var body: some View {
        OpticalText(title: name, size: 13, weight: selected ? .semibold : .regular, serif: true, language: language)
            .foregroundStyle(selected || hovered || (accessibility?.contrast ?? contrast) == .increased ? DotistDesign.ink : DotistDesign.faint)
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
    let opacity: UInt8
    let attachmentOverlap: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            SideTabBackground(inward: inward, color: color, selected: selected, opacity: opacity)
                .frame(width: row.rect.width + attachmentOverlap, height: SideTabGeometry.height)
            SideTabLabel(name: row.name, language: language, selected: selected,
                         hovered: hovered, right: inward, width: row.rect.width,
                         fullWidth: row.fullWidth, textOpacity: textOpacity)
        }
        .frame(width: row.rect.width + attachmentOverlap, height: SideTabGeometry.height)
        .clipped()
    }
}

/// The live host and raster snapshots share this entire tree, including surfaces,
/// label clipping and absolute tab positions. Each tab has an independent surface.
struct SideTabsCanvas: View {
    let rows: [SideTabLayout]
    let size: CGSize
    let language: String
    let selectedGroupID: String?
    let hovered: String?
    let inward: Bool
    let textOpacity: Double
    let opacity: UInt8
    let color: (String?) -> DotistGroupColor
    var attachmentOverlap: CGFloat = 0
    var pointer: ((String, NSEvent.EventType, CGPoint) -> Void)?
    var select: ((String?) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: size.width, height: size.height)
            ForEach(rows.filter { $0.opacity > 0 }) { row in
                SideTabContent(row: row, language: language, color: color(row.groupID),
                    selected: selectedGroupID == row.groupID, hovered: hovered == row.id,
                    inward: inward, textOpacity: textOpacity, opacity: opacity, attachmentOverlap: attachmentOverlap)
                    .overlay(alignment: .leading) {
                        if row.interactive, let pointer {
                            SideTabPointer { type, location in pointer(row.id, type, location) }
                                .frame(width: row.rect.width)
                        }
                    }
                    .opacity(row.opacity)
                    .allowsHitTesting(row.interactive)
                    .accessibilityHidden(!row.interactive)
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
    @ObservedObject var motion: PanelMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let pointer: (String, NSEvent.EventType, CGPoint) -> Void

    var body: some View {
        SideTabsCanvas(rows: presentation.rows, size: presentation.size, language: model.language,
            selectedGroupID: state.groupID, hovered: presentation.hovered, inward: presentation.inward,
            textOpacity: presentation.textOpacity * (reduceTransparency || contrast == .increased ? 1 : motion.idleContentOpacity), opacity: model.settings.sideTabOpacity,
            color: { model.themeColor(forGroup: $0) },
            attachmentOverlap: presentation.inward ? 0 : SideTabGeometry.attachmentOverlap,
            pointer: pointer, select: { state.groupID = $0 })
            .environment(\.sideTabSurfaceStyle, .tint)
            .modifier(DotistTheme(theme: model.settings.theme))
            .accessibilityHidden(!presentation.visible)
    }
}

/// Callable offscreen entry point. Rectangles use bitmap coordinates (top down).
/// Rendering the tint fill is intentional: ImageRenderer cannot sample Liquid Glass.
@MainActor
struct SideTabsSnapshot {
    let image: CGImage
    let tabs: [CGRect]

    static func render(names: [String], language: String, scheme: ColorScheme,
                       inward: Bool, expanded: Bool, showLabels: Bool = true, opacity: UInt8 = 85,
                       reduceTransparency: Bool = false, contrast: ColorSchemeContrast = .standard,
                       selectedIndex: Int? = 0, entrance: [CGFloat]? = nil,
                       color: @escaping (String?) -> DotistGroupColor = { _ in .teal }) -> SideTabsSnapshot? {
        let widths = names.map { SideTabGeometry.expandedWidth(name: $0, language: language) }
        let panel = CGRect(x: widths.max() ?? 48, y: 0, width: 364, height: 620)
        let sample = SideTabGeometry.snapshot(panel: panel, fullWidths: widths, progress: expanded ? 1 : 0, inward: inward, selectedIndex: selectedIndex, entrance: entrance)
        let rows = names.enumerated().map { index, name in
            SideTabLayout(id: String(index), groupID: String(index), name: name,
                rect: sample.tabs[index].offsetBy(dx: -sample.window.minX, dy: -sample.window.minY),
                fullWidth: widths[index], dragged: false, opacity: sample.opacities[index],
                interactive: sample.opacities[index] > 0)
        }
        let content = SideTabsCanvas(rows: rows, size: sample.window.size, language: language,
            selectedGroupID: selectedIndex.map(String.init), hovered: nil, inward: inward, textOpacity: showLabels ? sample.textOpacity : 0,
            opacity: opacity, color: color)
            .environment(\.sideTabSurfaceStyle, .tint)
            .environment(\.colorScheme, scheme)
            .environment(\.sideTabAccessibility, SideTabAccessibility(reduceTransparency: reduceTransparency, contrast: contrast))
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
    /// Deterministic offscreen fixtures use the live synchronization path without
    /// ordering desktop windows, installing input monitors or reading the pointer.
    struct Environment {
        var time: () -> TimeInterval = { CACurrentMediaTime() }
        var mouse: () -> CGPoint = { NSEvent.mouseLocation }
        var mouseButtons: () -> Int = { NSEvent.pressedMouseButtons }
        var visible: (NSPanel) -> Bool = { $0.isVisible && $0.isOnActiveSpace }
        var visibleMinX: (NSPanel) -> CGFloat = { ($0.screen ?? NSScreen.main)?.visibleFrame.minX ?? $0.frame.minX }
        var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        var desktopEvents = true
        var inputMonitors = true
    }
    private let environment: Environment
    private var entrance = SideTabEntrance()
    private(set) var renderedRows: [SideTabLayout] = []
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

    init(parent: NSPanel, model: AppModel, state: TaskPanelState, motion: PanelMotion, environment: Environment = Environment()) {
        self.environment = environment
        self.parent = parent; self.model = model; self.state = state; self.motion = motion
        window = SideTabsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.identifier = NSUserInterfaceItemIdentifier("dotist.side-tabs")
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.alphaValue = 0
        window.isReleasedWhenClosed = false; window.isMovable = false; window.isMovableByWindowBackground = false
        window.collectionBehavior = parent.collectionBehavior
        let host = SideTabHostingView(rootView: SideTabsView(model: model, state: state, presentation: presentation, motion: motion) { [weak self] in self?.pointer($0, type: $1, at: $2) })
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
        if environment.desktopEvents && environment.inputMonitors {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown, event.keyCode == 53, self.press != nil {
                    self.cancelDrag(); self.synchronize(); return nil
                }
                guard event.type != .keyDown else { return event }
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                self.synchronize(mouse: point)
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] _ in self?.synchronize() }
        }
        synchronize()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        motion.shadowController?.setTabRects([])
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

    func synchronize(mouse: CGPoint? = nil) {
        guard !stopped else { return }
        let mouse = mouse ?? environment.mouse()
        let groups = model.visibleGroups
        let ids = groups.map(\.id)
        if let press, press.order != ids { cancelDrag() }
        if let pendingOrder, pendingOrder == ids || !model.busy { self.pendingOrder = nil }
        let order = preview ?? pendingOrder ?? ids
        let names = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        let items = [(id: "all", groupID: Optional<String>.none, name: model.text("全部"))] + order.compactMap { id in
            names[id].map { (id: id, groupID: Optional(id), name: $0) }
        }
        let widths = items.map { item -> CGFloat in
            let name = item.name
            let key = "\(DotistDesign.fontCacheKey)|\(model.language)|\(name)"
            if let measured = measuredWidths[key] { return measured }
            let measured = SideTabGeometry.expandedWidth(name: name, language: model.language)
            measuredWidths[key] = measured
            return measured
        }
        let maxWidth = widths.max() ?? SideTabGeometry.collapsedWidth
        let frame = parent.frame
        let visibleMinX = environment.visibleMinX(parent)
        let now = environment.time()
        placement.update(availableSpace: frame.minX - visibleMinX, expandedWidth: maxWidth,
            canSwitch: press == nil)
        let inward = placement.inward
        let hostVisible = environment.visible(parent)
        let visible = hostVisible && !motion.bubble && !motion.animationInProgress
        let reduceMotion = environment.reduceMotion()
        let selectedIndex = items.firstIndex { $0.groupID == state.groupID }
        let itemIDs = items.map(\.id)
        entrance.update(ids: itemIDs, visible: visible, at: now, reduceMotion: reduceMotion || !hostVisible)
        let arrivals = entrance.values(ids: itemIDs, at: now)
        let current = SideTabGeometry.snapshot(panel: frame, fullWidths: widths,
            progress: expansion.progress(at: now), inward: inward, visibleMinX: visibleMinX,
            selectedIndex: selectedIndex, entrance: arrivals)
        let sensor = SideTabGeometry.windowFrame(panel: frame, count: items.count,
            width: expanded ? maxWidth : SideTabGeometry.selectedWidth, inward: inward, visibleMinX: visibleMinX)
        let overTab = zip(current.tabs, current.opacities).contains { $0.1 > 0 && $0.0.contains(mouse) }
        if !visible {
            expanded = false; collapseWork?.cancel(); collapseWork = nil; cancelDrag()
        } else if press == nil && environment.mouseButtons() != 0 {
            // A moving or resizing parent can carry its tabs across a held pointer.
            // Preserve the target until release; captured tab gestures still follow
            // the normal press path below.
            collapseWork?.cancel(); collapseWork = nil
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
        expansion.setExpanded(expanded, at: now, reduceMotion: reduceMotion || !hostVisible)
        let sample = SideTabGeometry.snapshot(panel: frame, fullWidths: widths,
            progress: expansion.progress(at: now), inward: inward, visibleMinX: visibleMinX,
            selectedIndex: selectedIndex, entrance: arrivals)
        let bounds = SideTabGeometry.paintedFrame(sample.window, inward: inward)
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
            let interactive = visible && sample.opacities[index] > 0
            if interactive { hitRects.append(rect) }
            return SideTabLayout(id: item.id, groupID: item.groupID, name: item.name,
                rect: rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY), fullWidth: widths[index], dragged: lifted,
                opacity: sample.opacities[index], interactive: interactive)
        }
        if presentation.size != bounds.size { presentation.size = bounds.size }
        if presentation.inward != inward { presentation.inward = inward }
        if presentation.textOpacity != sample.textOpacity { presentation.textOpacity = sample.textOpacity }
        renderedRows = rows
        if presentation.rows != rows { presentation.rows = rows }
        (window.contentView as? SideTabHostingView<SideTabsView>)?.screenHitRects = hitRects
        // Resolve the new SwiftUI layout before the resized child is composited.
        window.contentView?.layoutSubtreeIfNeeded()
        let hovered = rows.first { $0.interactive && $0.rect.offsetBy(dx: bounds.minX, dy: bounds.minY).contains(mouse) }?.id
        if presentation.hovered != hovered { presentation.hovered = hovered }
        if presentation.visible != visible { presentation.visible = visible }
        window.ignoresMouseEvents = !visible || (press == nil && !hitRects.contains { $0.contains(mouse) })
        let painted = hostVisible && rows.contains { $0.opacity > 0 }
        let shadowTabs = SideTabGeometry.shadowRects(rows: rows, bounds: bounds, panel: frame, painted: painted, visible: visible, inward: inward)
        motion.shadowController?.setTabRects(shadowTabs)
        window.alphaValue = painted ? 1 : 0
        let ordering = SideTabGeometry.childOrder(inward: inward, expanded: expanded,
            progress: expansion.progress(at: now))
        if let restingHost {
            restingHost.frame = parent.contentView?.convert(parent.convertFromScreen(bounds), from: nil) ?? .zero
            restingHost.screenHitRects = hitRects
            restingHost.isHidden = !painted || !inward || ordering == .above || bounds.maxX <= frame.minX
            restingHost.layoutSubtreeIfNeeded()
        }
        if painted && environment.desktopEvents {
            if window.parent !== parent || childOrder != ordering {
                // AppKit preserves the ordering relationship established by
                // addChildWindow; order(relativeTo:) cannot change that side.
                // Reattach synchronously without hiding either window.
                window.parent?.removeChildWindow(window)
                parent.addChildWindow(window, ordered: ordering)
            }
            if !window.isVisible { window.order(ordering, relativeTo: parent.windowNumber) }
            childOrder = ordering
        } else if !visible {
            // Frames continue synchronizing while collapsed or animating. On expansion
            // there is never a stale child frame to flash at the old panel location.
            // orderOut removes an NSWindow from its parent. Keep an invisible child
            // instead, otherwise the first collapse silently breaks drag following.
            expanded = false; collapseWork?.cancel(); collapseWork = nil; cancelDrag()
        }
    }
}

// Internal so the selector contract can be checked without showing a window.
final class SideTabsPanel: NSPanel {
    @objc(_hasActiveAppearance) func dotistHasActiveAppearance() -> Bool { FloatingGlassAppearance.active(self) }
}
