import AppKit
import DotistCore
import SwiftUI

/// Native drag sessions start directly from the title's mouse event. SwiftUI keeps
/// rendering the title and owns the existing drop destinations and mutations.
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
