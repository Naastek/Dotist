import AppKit
import Combine
import DotistCore
import SwiftUI

/// Panel coordinates, shared by live rows, editors and drag placeholders.
enum TaskRowMetrics {
    static let inset: CGFloat = 16
    static let indent: CGFloat = 22
    static func textX(_ depth: Int) -> CGFloat { 42 + indent * CGFloat(depth) }
    static func circleX(_ depth: Int) -> CGFloat { depth == 0 ? inset : textX(depth - 1) }
    static func diameter(_ depth: Int) -> CGFloat { depth == 0 ? 16 : 13 }
    static func height(_ depth: Int, titleHeight: CGFloat) -> CGFloat { max(20, titleHeight) + (depth == 0 ? 12 : 8) }
    static func circleFrame(_ depth: Int, titleHeight: CGFloat) -> CGRect {
        let size = diameter(depth)
        return CGRect(x: circleX(depth), y: (height(depth, titleHeight: titleHeight) - size) / 2, width: size, height: size)
    }
}

/// Three independent columns: the title owns the height and the circle is
/// centered on that whole block, including wrapped lines and inline tags.
struct TaskRowLayout: Layout {
    let depth: Int
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 332
        let title = subviews[1].sizeThatFits(.init(width: titleWidth(width, subviews), height: nil))
        return CGSize(width: width, height: TaskRowMetrics.height(depth, titleHeight: title.height))
    }
    private func titleWidth(_ width: CGFloat, _ subviews: Subviews) -> CGFloat {
        let meta = min(subviews[2].sizeThatFits(.unspecified).width, max(0, width * 0.4))
        return max(1, width - (TaskRowMetrics.textX(depth) - TaskRowMetrics.inset) - (meta > 0 ? meta + 8 : 0))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let titleWidth = titleWidth(bounds.width, subviews)
        let title = subviews[1].sizeThatFits(.init(width: titleWidth, height: nil))
        let circle = TaskRowMetrics.diameter(depth)
        subviews[0].place(at: CGPoint(x: bounds.minX + TaskRowMetrics.circleX(depth) - TaskRowMetrics.inset, y: bounds.midY - circle / 2), proposal: .init(width: circle, height: circle))
        subviews[1].place(at: CGPoint(x: bounds.minX + TaskRowMetrics.textX(depth) - TaskRowMetrics.inset, y: bounds.midY - title.height / 2), proposal: .init(width: titleWidth, height: title.height))
        let metadata = subviews[2].sizeThatFits(.init(width: max(0, bounds.width - titleWidth - (TaskRowMetrics.textX(depth) - TaskRowMetrics.inset) - 8), height: nil))
        subviews[2].place(at: CGPoint(x: bounds.maxX - metadata.width, y: bounds.midY - metadata.height / 2), proposal: .init(width: metadata.width, height: metadata.height))
    }
}

struct TaskSelection: Equatable {
    var ids: Set<String> = []
    var anchor: String?
    mutating func click(_ id: String, order: [String], shift: Bool, command: Bool) {
        if shift, let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
            ids = Set(order[min(a, b)...max(a, b)])
        } else if command {
            if !ids.insert(id).inserted { ids.remove(id) }
            anchor = id
        } else { ids = []; anchor = id }
    }
    mutating func clear() { ids = []; anchor = nil }
    func last(in order: [String]) -> String? { order.last { ids.contains($0) } }
}

@MainActor final class TaskRowSelection: ObservableObject {
    @Published var selected = false
    let focusRequest = PassthroughSubject<Void, Never>()
}

/// This object intentionally does not publish globally. Only rows whose bit
/// changes invalidate their title/checkmark, not the outline or its geometry.
@MainActor final class TaskSelectionController: ObservableObject {
    private(set) var value = TaskSelection()
    let navigation = PassthroughSubject<String, Never>()
    private var rows: [String: TaskRowSelection] = [:]
    func row(_ id: String) -> TaskRowSelection {
        if let row = rows[id] { return row }
        let row = TaskRowSelection(); row.selected = value.ids.contains(id); rows[id] = row
        return row
    }
    func update(_ operation: (inout TaskSelection) -> Void) {
        let old = value.ids
        operation(&value)
        for id in old.symmetricDifference(value.ids) { rows[id]?.selected = value.ids.contains(id) }
    }
}

struct TaskSelectableContent<Content: View>: View {
    @ObservedObject var selection: TaskRowSelection
    @FocusState private var focused: Bool
    let content: (Bool, Bool) -> Content
    var body: some View {
        content(selection.selected, focused)
            .focusable().focused($focused).focusEffectDisabled()
            .onReceive(selection.focusRequest) { _ in focused = true }
    }
}

/// A draft never reads any previous editor's buffer. Tab changes only its
/// parent; an empty draft is discarded by commit/blur/Escape.
enum TaskDraftFlow {
    static func parent(reverse: Bool, current: String?, after task: DotistTask, tasks: [DotistTask]) -> String? {
        let hierarchy = TaskHierarchy(tasks)
        if reverse { return current.flatMap { id in tasks.first { $0.id == id }?.parentId } }
        let currentDepth = current.map { hierarchy.depth(of: $0) + 1 } ?? 0
        let wanted = min(currentDepth + 1, hierarchy.depth(of: task.id) + 1, DotistTask.maxDepth)
        guard wanted > currentDepth else { return current }
        return ([task] + hierarchy.ancestors(of: task.id)).first { hierarchy.depth(of: $0.id) == wanted - 1 }?.id ?? current
    }
    static func titleToSave(_ text: String) -> String? {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}

struct TaskProgressSegments {
    static func values(completed: [Bool]) -> [Bool] {
        guard completed.count > 12 else { return completed }
        let done = Int((Double(completed.filter { $0 }.count) / Double(completed.count) * 12).rounded())
        return (0..<12).map { $0 < done }
    }
}

struct TaskCheckmark: View {
    let depth: Int
    let completed: Bool
    let children: [Bool]
    let emphasized: Bool
    var body: some View {
        ZStack {
            if completed {
                Circle().fill(DotistDesign.accent)
                Image(systemName: "checkmark").font(.system(size: depth == 0 ? 9 : 7.5, weight: .heavy)).foregroundStyle(DotistDesign.paper)
            } else if children.isEmpty {
                Circle().strokeBorder(emphasized ? DotistDesign.accent : DotistDesign.checkStroke, lineWidth: 1.25)
            } else {
                let segments = TaskProgressSegments.values(completed: children)
                ForEach(segments.indices, id: \.self) { index in
                    let step = 360.0 / Double(segments.count)
                    let gap = segments.count == 1 ? 0.0 : 8.0
                    Circle().inset(by: 0.625)
                        .trim(from: (Double(index) * step + gap / 2) / 360, to: (Double(index + 1) * step - gap / 2) / 360)
                        .stroke(segments[index] ? DotistDesign.accent : emphasized ? DotistDesign.accent.opacity(0.5) : DotistDesign.checkStroke, lineWidth: 1.25)
                        .rotationEffect(.degrees(-90))
                }
            }
        }.frame(width: TaskRowMetrics.diameter(depth), height: TaskRowMetrics.diameter(depth))
    }
}

@MainActor final class TaskDragMotion: ObservableObject {
    @Published var location = CGPoint.zero
}

struct TaskLiftedLayer<Content: View>: View {
    @ObservedObject var motion: TaskDragMotion
    let origin: CGPoint
    let start: CGPoint
    let content: Content
    var body: some View {
        content.offset(x: origin.x, y: origin.y + motion.location.y - start.y)
    }
}

struct TaskGhostFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let next = nextValue(); if next != .zero { value = next } }
}

enum TaskDragBatch {
    /// Preflight every selected subtree before the first write. Core owns each
    /// subtree transaction; this adapter preserves displayed selection order.
    static func commit(ids: [String], target: TaskReorderEngine.Target, store: TaskStore) throws {
        let tasks = try store.listTasks()
        let hierarchy = TaskHierarchy(tasks)
        let carried = Set(ids.flatMap { [$0] + hierarchy.descendants(of: $0).map(\.id) })
        if let parent = target.parentID, carried.contains(parent) { throw TaskStoreError("不能将任务移到自己或自己的后代下面") }
        if let before = target.beforeID, carried.contains(before) { throw TaskStoreError("找不到任务") }
        let parentDepth = target.parentID.map { hierarchy.depth(of: $0) + 1 } ?? 0
        for id in ids {
            guard tasks.contains(where: { $0.id == id }) else { throw TaskStoreError("找不到任务") }
            guard parentDepth + hierarchy.subtreeHeight(of: id) <= DotistTask.maxDepth else { throw TaskStoreError("最多支持 5 层任务") }
        }
        for id in ids { try store.commitReorder(id, groupID: target.groupID, parentID: target.parentID, beforeID: target.beforeID) }
    }
}

struct TaskListRowFrame: Equatable {
    let task: DotistTask
    let frame: CGRect
    var sub = false
    var allTasks = false
    var hideDue = false
    struct Key: PreferenceKey {
        static let defaultValue: [TaskListRowFrame] = []
        static func reduce(value: inout [TaskListRowFrame], nextValue: () -> [TaskListRowFrame]) { value.append(contentsOf: nextValue()) }
    }
}

struct TaskListGroupFrame: Equatable {
    let id: String
    let region: String
    let frame: CGRect
    struct Key: PreferenceKey {
        static let defaultValue: [TaskListGroupFrame] = []
        static func reduce(value: inout [TaskListGroupFrame], nextValue: () -> [TaskListGroupFrame]) { value.append(contentsOf: nextValue()) }
    }
}

struct TaskShelfFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}

struct TaskListDrag {
    let taskID: String
    let blockIDs: Set<String>
    let visibleBlock: [TaskListRowFrame]
    let startFrame: CGRect
    let startLocation: CGPoint
    var target: TaskReorderEngine.Target?
    var region: String?
    var ghostBeforeID: String?
    var ghostAfterID: String?
    var targetIsEmpty = false
    var committing = false
    var rootIDs: [String] = []
    var sourceDepth = 0
    var subtreeHeight = 0
}

@MainActor
final class TaskReorderRuntime: ObservableObject {
    weak var scrollView: NSScrollView?
    var ghostFrame = CGRect.zero

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

/// Observes native events without intercepting controls or context menus. Window
/// background movement must be disabled at mouse-down, before the 6pt gesture
/// threshold, and restored on release/cancellation or when the view unmounts.
struct TaskReorderInteractionGuard: NSViewRepresentable {
    let rowFrames: [CGRect]
    let dragging: Bool
    let cancel: () -> Void
    func makeNSView(context: Context) -> GuardView { GuardView() }
    func updateNSView(_ view: GuardView, context: Context) {
        view.rowFrames = rowFrames
        view.dragging = dragging
        view.cancel = cancel
    }
    static func dismantleNSView(_ view: GuardView, coordinator: ()) { view.stop() }

    final class GuardView: NSView {
        var rowFrames: [CGRect] = []
        var dragging = false
        var cancel: () -> Void = {}
        private var monitor: Any?
        private weak var guardedWindow: NSWindow?
        private var originalBackgroundMovement: Bool?
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .leftMouseUp { restoreWindowMovement(); return event }
                guard event.window === window else { return event }
                if event.type == .keyDown, event.keyCode == 53, dragging {
                    cancel()
                    restoreWindowMovement()
                    return nil
                }
                if event.type == .leftMouseDown, rowFrames.contains(where: { $0.contains(self.convert(event.locationInWindow, from: nil)) }) {
                    restoreWindowMovement()
                    guardedWindow = window
                    originalBackgroundMovement = window?.isMovableByWindowBackground
                    window?.isMovableByWindowBackground = false
                }
                return event
            }
        }
        private func restoreWindowMovement() {
            if let originalBackgroundMovement { guardedWindow?.isMovableByWindowBackground = originalBackgroundMovement }
            originalBackgroundMovement = nil
            guardedWindow = nil
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            restoreWindowMovement()
        }
    }
}

// Compatibility for the calendar and board views in ViewsWindow.swift.
// MainWindow uses only the direct gesture and never creates this adapter.
struct TaskDragSource: NSViewRepresentable {
    let model: AppModel
    let task: DotistTask
    let scope: String
    let font: NSFont
    var click: () -> Void = {}

    func makeNSView(context: Context) -> TaskDragSourceView {
        TaskDragSourceView(id: task.id, title: task.title, font: font)
    }
    func updateNSView(_ view: TaskDragSourceView, context: Context) {
        view.taskID = task.id
        view.title = task.title
        view.font = font
        view.click = click
        view.begin = { model.beginDrag(task.id, scope: scope) }
        view.finish = { model.endDrag() }
    }
}

final class TaskDragSourceView: NSView, NSDraggingSource {
    var taskID: String
    var title: String
    var font: NSFont
    var click: () -> Void = {}
    var begin: () -> Void = {}
    var finish: () -> Void = {}
    private var down: NSPoint?
    private var dragging = false

    init(id: String, title: String, font: NSFont) {
        taskID = id
        self.title = title
        self.font = font
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { return nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let the existing SwiftUI row context menu receive secondary clicks.
        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control) { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { rightMouseDown(with: event); return }
        down = event.locationInWindow
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down, !dragging,
              hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) > 4 else { return }
        dragging = true
        self.down = nil
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.8)]
        let size = NSSize(width: min(348, max(120, ceil((title as NSString).size(withAttributes: attributes).width) + 42)), height: 32)
        let image = NSImage(size: size, flipped: false) { [title] _ in
            NSColor.secondaryLabelColor.withAlphaComponent(0.8).setStroke()
            let circle = NSBezierPath(ovalIn: NSRect(x: 1, y: 8, width: 16, height: 16))
            circle.lineWidth = 1.25
            circle.stroke()
            (title as NSString).draw(at: NSPoint(x: 26, y: 8), withAttributes: attributes)
            return true
        }
        let item = NSDraggingItem(pasteboardWriter: taskID as NSString)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 26, y: point.y - size.height / 2, width: size.width, height: size.height), contents: image)
        begin()
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) {
        guard down != nil, !dragging else { return }
        down = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) { click() }
    }
    override func rightMouseDown(with event: NSEvent) {
        down = nil
        super.rightMouseDown(with: event)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        down = nil
        dragging = false
        finish()
    }
}
