import AppKit
import DotistCore
import SwiftUI

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
    var location: CGPoint
    var target: TaskReorderEngine.Target?
    var region: String?
    var ghostBeforeID: String?
    var ghostAfterID: String?
    var targetIsEmpty = false
    var committing = false
}

@MainActor
final class TaskReorderRuntime: ObservableObject {
    weak var scrollView: NSScrollView?

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
