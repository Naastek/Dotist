import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

/// Panel coordinates, shared by live rows, editors and drag placeholders.
enum TaskRowMetrics {
    static let inset: CGFloat = 16
    static let indent: CGFloat = 22
    static func textX(_ depth: Int) -> CGFloat { 42 + indent * CGFloat(depth) }
    static func circleX(_ depth: Int) -> CGFloat { depth == 0 ? inset : textX(depth - 1) }
    static func diameter(_ depth: Int) -> CGFloat { depth == 0 ? 16 : 13 }
    static func height(_ depth: Int, titleHeight: CGFloat) -> CGFloat { max(depth == 0 ? 32 : 28, titleHeight) }
    static func circleFrame(_ depth: Int, titleHeight: CGFloat) -> CGRect {
        let size = diameter(depth)
        return CGRect(x: circleX(depth), y: (height(depth, titleHeight: titleHeight) - size) / 2, width: size, height: size)
    }
}

/// Action hit boxes share a fixed right edge, independent of metadata length.
enum TaskRowActionMetrics {
    static let reservedMetadataWidth: CGFloat = 88
    static func rightInset(metadataWidth: CGFloat) -> CGFloat {
        metadataWidth > reservedMetadataWidth ? metadataWidth + 8 : reservedMetadataWidth
    }
    static func width(count: Int) -> CGFloat { CGFloat(count * 22 + max(0, count - 1)) }
    static func frame(row: CGRect, metadataWidth: CGFloat, actionWidth: CGFloat) -> CGRect {
        CGRect(x: row.maxX - rightInset(metadataWidth: metadataWidth) - actionWidth,
               y: row.midY - 11, width: actionWidth, height: 22)
    }
}

enum TaskRowBackgroundState: Equatable {
    case idle, hovered, selected, editing
    init(hovered: Bool, selected: Bool, editing: Bool, dragging: Bool, carried: Bool = false) {
        if carried { self = .idle }
        else if editing { self = .editing }
        else if selected { self = .selected }
        else if hovered && !dragging { self = .hovered }
        else { self = .idle }
    }
    var opacity: Double {
        switch self { case .idle: 0; case .hovered: 0.10; case .selected: 0.16; case .editing: 0.18 }
    }
}

enum TaskDateFilterMetrics {
    static let rowHeight: CGFloat = 34
    static func opacity(distance: Int, hovered: Bool = false, focused: Bool = false,
                        increasedContrast: Bool = false, voiceOver: Bool = false) -> Double {
        guard !increasedContrast && !voiceOver && !focused else { return 1 }
        let values = [1.0, 0.78, 0.58, 0.42, 0.32]
        let value = values[min(max(distance, 0), 4)]
        return hovered ? max(0.9, value) : value
    }
    static func distance(of id: String, selected: String?, in filters: [String]) -> Int {
        guard let selected, let anchor = filters.firstIndex(of: selected), let index = filters.firstIndex(of: id) else { return 0 }
        return abs(index - anchor)
    }
    static func size(selected: Bool) -> CGFloat { selected ? 17 : 14 }
    static func weight(selected: Bool) -> NSFont.Weight { selected ? .medium : .regular }
    static func slotWidth(title: String, language: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: DotistDesign.nativeFont(17, weight: .medium, language: language)]).width)
    }
}

/// Display copy and creation defaults share the exact filter semantics. No UI or
/// clock dependency: tests supply a date/calendar, including the system week start.
struct TaskEmptyState: Equatable {
    let title: String
    let hint: String?
    let allowsAdding: Bool
    let groupID: String
    let dueDate: String?
    static let addTitle = "添加任务"
    static let addAccessibilityLabel = "在这里添加任务"

    init(scope: String, groupID: String?, customRange: TaskDateRange? = nil,
         now: Date = Date(), calendar: Calendar = .current) {
        self.groupID = groupID ?? DotistGroup.inboxID
        allowsAdding = customRange != nil || !["done", "overdue"].contains(scope)
        hint = allowsAdding ? "写下一件小事，或在下方输入栏添加。" : nil
        if customRange != nil { title = "这个日期范围内没有任务" }
        else {
            switch scope {
            case "today": title = "今天没有安排"
            case "tomorrow": title = "明天没有任务"
            case "week": title = "本周没有任务"
            case "nextweek": title = "下周没有任务"
            case "next7": title = "未来 7 天没有任务"
            case "overdue": title = "没有已逾期的任务"
            case "undated": title = "没有无日期的任务"
            case "done": title = "还没有已完成的任务"
            default: title = groupID == nil ? "这里什么都没有" : "这个分组还没有任务"
            }
        }
        if let customRange { dueDate = customRange.start }
        else if ["today", "tomorrow", "week", "nextweek", "next7"].contains(scope) {
            dueDate = TaskFiltering([], now: now, calendar: calendar).range(scope: scope).start
        } else { dueDate = nil }
    }
}

/// Position the complete empty-state block at 38% of the list viewport. Layout
/// owns placement; text and native editors retain the optical centering wrappers.
struct TaskEmptyStateLayout: Layout {
    var viewportHeight: CGFloat? = nil
    var minimumTop: CGFloat = 0
    static func top(height: CGFloat, contentHeight: CGFloat, minimumTop: CGFloat = 0) -> CGFloat {
        max(minimumTop, min(height - contentHeight, height * 0.38 - contentHeight / 2))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 332
        let content = subviews[0].sizeThatFits(.init(width: width, height: nil))
        // Only an explicit empty-state viewport can reserve height. An incidental
        // proposal from a stack must not turn this into a vertically flexible row.
        return CGSize(width: width, height: max(content.height + minimumTop, viewportHeight ?? 0))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let content = subviews[0].sizeThatFits(.init(width: bounds.width, height: nil))
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + Self.top(height: bounds.height, contentHeight: content.height, minimumTop: minimumTop)),
                          proposal: .init(width: bounds.width, height: content.height))
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
        // Metadata is never compressed by the title, including at depth four.
        let meta = subviews[2].sizeThatFits(.unspecified).width
        return max(1, width - (TaskRowMetrics.textX(depth) - TaskRowMetrics.inset) - (meta > 0 ? meta + 8 : 0))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let titleWidth = titleWidth(bounds.width, subviews)
        let title = subviews[1].sizeThatFits(.init(width: titleWidth, height: nil))
        let circle = TaskRowMetrics.diameter(depth)
        subviews[0].place(at: CGPoint(x: bounds.minX + TaskRowMetrics.circleX(depth) - TaskRowMetrics.inset, y: bounds.midY - circle / 2), proposal: .init(width: circle, height: circle))
        subviews[1].place(at: CGPoint(x: bounds.minX + TaskRowMetrics.textX(depth) - TaskRowMetrics.inset, y: bounds.midY - title.height / 2), proposal: .init(width: titleWidth, height: title.height))
        let metadata = subviews[2].sizeThatFits(.unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX - metadata.width, y: bounds.midY - metadata.height / 2), proposal: .init(width: metadata.width, height: metadata.height))
        if subviews.count > 3 {
            let actions = subviews[3].sizeThatFits(.unspecified)
            let frame = TaskRowActionMetrics.frame(row: bounds, metadataWidth: metadata.width, actionWidth: actions.width)
            subviews[3].place(at: frame.origin, proposal: .init(width: frame.width, height: frame.height))
        }
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
                OpticalSymbol(name: "checkmark", size: depth == 0 ? 9 : 7.5, weight: .heavy).foregroundStyle(DotistDesign.paper)
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
    var frame: CGRect
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
    var initialTarget: TaskReorderEngine.Target?
    var baselineRows: [TaskListRowFrame] = []
    var baselineGroups: [TaskListGroupFrame] = []
    var scrollOriginY: CGFloat = 0
    var expandedDropGroup: String?
}

@MainActor
final class TaskReorderRuntime: ObservableObject {
    @Published var drag: TaskListDrag?
    weak var scrollView: NSScrollView?
    var scrollOriginY: CGFloat { scrollView?.contentView.bounds.minY ?? 0 }

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
    var undoRedo: (Bool) -> Bool = { _ in false }
    func makeNSView(context: Context) -> GuardView { GuardView() }
    func updateNSView(_ view: GuardView, context: Context) {
        view.rowFrames = rowFrames
        view.dragging = dragging
        view.cancel = cancel
        view.undoRedo = undoRedo
    }
    static func dismantleNSView(_ view: GuardView, coordinator: ()) { view.stop() }

    final class GuardView: NSView {
        var rowFrames: [CGRect] = []
        var dragging = false
        var cancel: () -> Void = {}
        var undoRedo: (Bool) -> Bool = { _ in false }
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
                if let redo = TaskPanelUndoShortcut.redo(for: event, responder: window?.firstResponder), undoRedo(redo) {
                    return nil
                }
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

enum TaskPanelUndoShortcut {
    /// Native text editing keeps its own undo manager, including field editors
    /// and editors in group/tag management. Other windows never reach this gate.
    static func redo(for event: NSEvent, responder: NSResponder?) -> Bool? {
        guard event.type == .keyDown,
              event.charactersIgnoringModifiers?.lowercased() == "z" else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == [.command] || flags == [.command, .shift] else { return nil }
        if let editor = responder as? NSTextView, editor.isEditable { return nil }
        if let field = responder as? NSTextField, field.isEditable { return nil }
        return flags.contains(.shift)
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
        let image = TaskDragPreview.image(title: title, font: font)
        let size = image.size
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

/// A pure countdown: callers inject monotonic timestamps, so tests need no sleeps.
struct PausableToastLifetime {
    let duration: TimeInterval
    private var remaining: TimeInterval = 0
    private var resumedAt: TimeInterval?
    private var hovered = false

    mutating func restart(at now: TimeInterval) {
        remaining = duration
        resumedAt = hovered ? nil : now
    }
    mutating func setHovered(_ value: Bool, at now: TimeInterval) {
        guard value != hovered else { return }
        if value {
            if let resumedAt { remaining = max(0, remaining - max(0, now - resumedAt)) }
            resumedAt = nil
        } else { resumedAt = now }
        hovered = value
    }
    func isVisible(at now: TimeInterval) -> Bool {
        remaining - (resumedAt.map { max(0, now - $0) } ?? 0) > 0
    }
}

/// Toolbar buttons are 28pt wide with 4pt spacing. The dragged icon follows
/// the pointer; only neighbors between its original and target slots move.
enum ToolbarDragLayout {
    static let step: CGFloat = 32
    static func targetIndex(from source: Int, translation: CGFloat, count: Int) -> Int {
        guard count > 0, translation.isFinite else { return source }
        let displacement = (translation / step).rounded()
        return Int(min(CGFloat(count - 1), max(0, CGFloat(source) + displacement)))
    }
    static func offset(index: Int, source: Int, target: Int, translation: CGFloat) -> CGFloat {
        if index == source { return translation }
        if source < target && index > source && index <= target { return -step }
        if target < source && index >= target && index < source { return step }
        return 0
    }
}

struct ToolbarDragSession {
    let item: ToolbarItem
    let items: [ToolbarItem]
    var translation: CGFloat = 0
    var source: Int { items.firstIndex(of: item) ?? 0 }
    var target: Int { ToolbarDragLayout.targetIndex(from: source, translation: translation, count: items.count) }
    func offset(for item: ToolbarItem) -> CGFloat {
        guard let index = items.firstIndex(of: item) else { return 0 }
        return ToolbarDragLayout.offset(index: index, source: source, target: target, translation: translation)
    }
}

struct ToolbarFrameKey: PreferenceKey {
    static let defaultValue: [ToolbarItem: CGRect] = [:]
    static func reduce(value: inout [ToolbarItem: CGRect], nextValue: () -> [ToolbarItem: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TaskGhostConnector: Shape {
    var start: CGPoint
    var end: CGPoint
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(start.x, start.y), .init(end.x, end.y)) }
        set { start = .init(x: newValue.first.first, y: newValue.first.second); end = .init(x: newValue.second.first, y: newValue.second.second) }
    }
    func path(in rect: CGRect) -> Path {
        guard end.y > start.y, end.x > start.x else { return Path() }
        let radius = min(4, (end.y - start.y) / 2, (end.x - start.x) / 2)
        return Path { path in
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x, y: end.y - radius))
            path.addQuadCurve(to: CGPoint(x: start.x + radius, y: end.y), control: CGPoint(x: start.x, y: end.y))
            path.addLine(to: end)
        }
    }
}

/// Erases only title glyphs behind the floating row actions. It never paints
/// paper over the panel tint, and leaves the transparent title hit region intact.
struct TaskTitleFade: View {
    let trailing: CGFloat
    var rowRight: CGFloat? = nil
    var coordinateSpace: String = "dotist-task-list"
    var body: some View {
        GeometryReader { geometry in
            let title = geometry.frame(in: .named(coordinateSpace))
            let metadata = rowRight.map { max(0, $0 - title.maxX - 8) } ?? 0
            let rawEnd = max(0, rowRight.map { $0 - TaskRowActionMetrics.rightInset(metadataWidth: metadata) - trailing - title.minX } ?? (geometry.size.width - trailing))
            let end = min(geometry.size.width, rawEnd)
            let start = max(0, end - 24)
            let width = max(1, geometry.size.width)
            LinearGradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: start / width),
                .init(color: .clear, location: end / width),
                .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        }
    }
}

/// Convert the pointer to the frozen outline by removing the one live gap.
/// A pointer inside the placeholder keeps the same insertion boundary.
enum TaskDragGeometry {
    static func pointerY(_ y: CGFloat, excludingGhost frame: CGRect) -> CGFloat {
        guard !frame.isEmpty else { return y }
        return y - min(frame.height, max(0, y - frame.minY))
    }
}

/// The board/calendar adapters use exactly the same geometry as native fields.
/// Unlike a fixed y origin this remains centered for every preview font size.
enum TaskDragPreview {
    static func image(title: String, font: NSFont) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.8)]
        let size = NSSize(width: min(348, max(120, ceil((title as NSString).size(withAttributes: attributes).width) + 42)), height: 32)
        return NSImage(size: size, flipped: false) { _ in
            NSColor.secondaryLabelColor.withAlphaComponent(0.8).setStroke()
            let circle = NSBezierPath(ovalIn: NSRect(x: 1, y: 8, width: 16, height: 16))
            circle.lineWidth = 1.25
            circle.stroke()
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let line = TextLineGeometry(font: font, in: CGRect(x: 26, y: 0, width: size.width - 26, height: size.height), sample: title)
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 26, y: size.height - line.baseline)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: attributes)), context)
            context.restoreGState()
            return true
        }
    }
}

/// Only this layer observes pointer frames; the document's row tree stays still.
struct TaskLiftedBlock<Content: View>: View {
    let drag: TaskListDrag
    @ObservedObject var motion: TaskDragMotion
    @ViewBuilder let content: (TaskListRowFrame) -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(drag.visibleBlock, id: \.task.id) { row in content(row).frame(height: row.frame.height) }
        }.frame(width: drag.startFrame.width, height: drag.startFrame.height, alignment: .topLeading)
            .offset(x: drag.startFrame.minX, y: drag.startFrame.minY + motion.location.y - drag.startLocation.y)
            .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Collapsed groups accept a complete subtree as a new final root.
enum TaskCollapsedGroupDrop {
    static func target(groupID: String) -> TaskReorderEngine.Target {
        .init(groupID: groupID, slot: Int.max, level: 0, parentID: nil, beforeID: nil)
    }
    static func removingGap(_ frame: CGRect, gap: CGRect) -> CGRect {
        guard !gap.isEmpty else { return frame }
        let minY = TaskDragGeometry.pointerY(frame.minY, excludingGhost: gap)
        let maxY = TaskDragGeometry.pointerY(frame.maxY, excludingGhost: gap)
        return CGRect(x: frame.minX, y: minY, width: frame.width, height: maxY - minY)
    }
}

struct TaskSectionHeadingKey: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value.append(contentsOf: nextValue()) }
}
