import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

@MainActor
final class TaskReorderRuntime: ObservableObject {
    enum Input {
        case begin(String, CGPoint), move(String, CGPoint), end(String, CGPoint), cancel
    }
    var handleInput: ((Input) -> Void)?
    func send(_ input: Input) { handleInput?(input) }
    @Published var drag: TaskListDrag?
    weak var scrollView: NSScrollView?
    var scrollOriginY: CGFloat { scrollView?.contentView.bounds.minY ?? 0 }

    private weak var pickupPanel: NSView?
    private weak var pickupViewport: NSView?
    private final class WeakPickupView {
        weak var view: NSView?
        let row: TaskListRowFrame?
        let group: TaskListGroupFrame?
        init(_ view: NSView, row: TaskListRowFrame? = nil, group: TaskListGroupFrame? = nil) { self.view = view; self.row = row; self.group = group }
    }
    private var pickupRows: [TaskInsertionSlot: WeakPickupView] = [:]
    private var pickupGroups: [String: WeakPickupView] = [:]
    func registerPickup(_ view: NSView, role: TaskPickupFrameProbe.Role, row: TaskListRowFrame? = nil, group: TaskListGroupFrame? = nil) {
        switch role {
        case .panel: pickupPanel = view
        case .viewport: pickupViewport = view
        case .row(let slot): pickupRows[slot] = WeakPickupView(view, row: row)
        case .group(let region): pickupGroups[region] = WeakPickupView(view, group: group)
        }
    }
    func removePickup(_ view: NSView, role: TaskPickupFrameProbe.Role) {
        switch role {
        case .panel: if pickupPanel === view { pickupPanel = nil }
        case .viewport: if pickupViewport === view { pickupViewport = nil }
        case .row(let slot): if pickupRows[slot]?.view === view { pickupRows[slot] = nil }
        case .group(let region): if pickupGroups[region]?.view === view { pickupGroups[region] = nil }
        }
    }
    private func pickupFrame(_ view: NSView?) -> CGRect? {
        guard let view, let panel = pickupPanel, panel.window != nil,
              view.window === panel.window else { return nil }
        return panel.convert(view.bounds, from: view)
    }
    var pickupViewportFrame: CGRect? { pickupFrame(pickupViewport) }
    func pickupFrames(_ cached: [TaskListRowFrame]) -> [TaskListRowFrame] {
        let cached = cached.filter { TaskRowVisibility.hasUsableFrame($0.frame) }
        guard pickupPanel != nil else { return cached }
        var seen: Set<TaskInsertionSlot> = []
        return cached.compactMap { old in
            let source = pickupRows[.before(old.task.id, region: old.region)]
            guard let source, var live = source.row, let frame = pickupFrame(source.view), TaskRowVisibility.hasUsableFrame(frame),
                  seen.insert(.before(live.task.id, region: live.region)).inserted else { return nil }
            live.frame = frame
            return live
        }
    }
    func pickupGroupFrames(_ cached: [TaskListGroupFrame]) -> [TaskListGroupFrame] {
        guard pickupPanel != nil else { return cached }
        return pickupGroups.values.compactMap { source in
            guard let group = source.group, let frame = pickupFrame(source.view) else { return nil }
            return .init(id: group.id, region: group.region, frame: frame, date: group.date)
        }
    }

    @discardableResult func scroll(by delta: CGFloat) -> Bool {
        guard let scrollView, let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        let old = clip.bounds.origin
        let limit = max(0, document.bounds.height - clip.bounds.height)
        let y = min(limit, max(0, old.y + (document.isFlipped ? delta : -delta)))
        guard abs(y - old.y) > 0.1 else { return false }
        clip.scroll(to: NSPoint(x: old.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        return true
    }
}

/// Read native source geometry at pickup, before collapsing the gesture owner.
/// SwiftUI preferences may still describe the previous scroll/viewport frame.
struct TaskPickupFrameProbe: NSViewRepresentable {
    enum Role: Equatable { case panel, viewport, row(TaskInsertionSlot), group(String) }
    @Environment(\.taskRowInteractive) private var rowInteractive
    let runtime: TaskReorderRuntime
    let role: Role
    var row: TaskListRowFrame? = nil
    var group: TaskListGroupFrame? = nil
    func makeCoordinator() -> Coordinator { Coordinator(runtime: runtime, role: role) }
    func makeNSView(context: Context) -> Probe {
        let view = Probe(); runtime.registerPickup(view, role: role, row: row, group: group); return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        if context.coordinator.role != role {
            runtime.removePickup(view, role: context.coordinator.role)
            context.coordinator.role = role
        }
        if row != nil && !rowInteractive { runtime.removePickup(view, role: role) }
        else { runtime.registerPickup(view, role: role, row: row, group: group) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Probe, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) { coordinator.runtime.removePickup(view, role: coordinator.role) }
    final class Coordinator {
        let runtime: TaskReorderRuntime
        var role: Role
        init(runtime: TaskReorderRuntime, role: Role) { self.runtime = runtime; self.role = role }
    }
    final class Probe: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

enum TaskInsertionSlot: Hashable {
    case before(String, region: String = ""), after(String, region: String = ""), empty(String)
    var region: String {
        switch self {
        case .before(_, let region), .after(_, let region), .empty(let region): region
        }
    }
}

struct TaskReorderScrollBridge: NSViewRepresentable {
    let runtime: TaskReorderRuntime
    func makeNSView(context: Context) -> ScrollProbe { ScrollProbe(runtime: runtime) }
    func updateNSView(_ view: ScrollProbe, context: Context) { view.resolveScrollView() }

    final class ScrollProbe: NSView {
        let runtime: TaskReorderRuntime
        init(runtime: TaskReorderRuntime) { self.runtime = runtime; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); resolveScrollView() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resolveScrollView() }
        func resolveScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                runtime.scrollView = enclosingScrollView
            }
        }
    }
}

