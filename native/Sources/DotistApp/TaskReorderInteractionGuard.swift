import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

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
        private var originalMovable: Bool?
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if TaskDragDiagnostics.enabled, event.window === window,
                   [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) {
                    let point = self.convert(event.locationInWindow, from: nil)
                    let content = window?.contentView
                    let hit = content.flatMap { $0.hitTest($0.convert(event.locationInWindow, from: nil)) }
                    TaskDragDiagnostics.record("native.\(event.type)", fields: [
                        "windowNumber": "\(event.windowNumber)", "windowPoint": "\(event.locationInWindow)",
                        "guardPoint": "\(point)", "guardFrame": "\(frame)", "windowFrame": "\(String(describing: window?.frame))",
                        "rowHits": "\(rowFrames.filter { $0.contains(point) }.count)", "rowCount": "\(rowFrames.count)",
                        "hitClass": hit.map { String(describing: type(of: $0)) } ?? "nil",
                        "dragging": "\(dragging)", "movableByBackground": "\(window?.isMovableByWindowBackground == true)"])
                }
                if event.type == .leftMouseUp { restoreWindowMovement(); return event }
                guard event.window === window else { return event }
                if let redo = TaskPanelUndoShortcut.redo(for: event, responder: window?.firstResponder), undoRedo(redo) {
                    return nil
                }
                if event.type == .keyDown, event.keyCode == 53, dragging {
                    TaskDragDiagnostics.record("native.escape-cancel")
                    cancel()
                    restoreWindowMovement()
                    return nil
                }
                if event.type == .leftMouseDown, rowFrames.contains(where: { $0.contains(self.convert(event.locationInWindow, from: nil)) }) {
                    restoreWindowMovement()
                    guardedWindow = window
                    originalBackgroundMovement = window?.isMovableByWindowBackground
                    originalMovable = window?.isMovable
                    window?.isMovableByWindowBackground = false
                    // ⌘-drag otherwise moves the whole window before SwiftUI sees it.
                    if event.modifierFlags.contains(.command) { window?.isMovable = false }
                    TaskDragDiagnostics.record("native.disable-background-movement")
                }
                return event
            }
            TaskDragDiagnostics.record("native.guard-installed", fields: ["windowNumber": "\(window?.windowNumber ?? -1)"])
        }
        private func restoreWindowMovement() {
            if let originalBackgroundMovement { guardedWindow?.isMovableByWindowBackground = originalBackgroundMovement }
            if let originalMovable { guardedWindow?.isMovable = originalMovable }
            originalMovable = nil
            originalBackgroundMovement = nil
            guardedWindow = nil
        }
        func stop() {
            if monitor != nil { TaskDragDiagnostics.record("native.guard-stopped") }
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

