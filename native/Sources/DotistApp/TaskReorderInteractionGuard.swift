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
    var dismissEditor: () -> Void = {}
    var onPointerDown: (Bool) -> Void = { _ in }
    var onPointerUp: () -> Void = {}
    func makeNSView(context: Context) -> GuardView { GuardView() }
    func updateNSView(_ view: GuardView, context: Context) {
        view.rowFrames = rowFrames
        view.dragging = dragging
        view.cancel = cancel
        view.undoRedo = undoRedo
        view.dismissEditor = dismissEditor
        view.onPointerDown = onPointerDown
        view.onPointerUp = onPointerUp
    }
    static func dismantleNSView(_ view: GuardView, coordinator: ()) { view.stop() }

    final class GuardView: NSView {
        var rowFrames: [CGRect] = []
        var dragging = false
        var cancel: () -> Void = {}
        var undoRedo: (Bool) -> Bool = { _ in false }
        var dismissEditor: () -> Void = {}
        var onPointerDown: (Bool) -> Void = { _ in }
        var onPointerUp: () -> Void = {}
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private weak var guardedWindow: NSWindow?
        private var originalBackgroundMovement: Bool?
        private var originalMovable: Bool?
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.restoreWindowMovement() }
                },
                center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.restoreWindowMovement() }
                }
            ]
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                self?.handleLocalEvent(event) ?? event
            }
            TaskDragDiagnostics.record("native.guard-installed", fields: ["windowNumber": "\(window.windowNumber)"])
        }

        private func hitTestWindowPoint(_ locationInWindow: NSPoint) -> NSView? {
            guard let content = self.window?.contentView else { return nil }
            let pointInSuperview = content.superview.map { $0.convert(locationInWindow, from: nil) } ?? locationInWindow
            return content.hitTest(pointInSuperview)
        }

        func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
            if TaskDragDiagnostics.enabled, event.window === self.window,
               [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) {
                let point = self.convert(event.locationInWindow, from: nil)
                let hit = hitTestWindowPoint(event.locationInWindow)
                TaskDragDiagnostics.record("native.\(event.type)", fields: [
                    "windowNumber": "\(event.windowNumber)", "windowPoint": "\(event.locationInWindow)",
                    "guardPoint": "\(point)", "guardFrame": "\(frame)", "windowFrame": "\(String(describing: self.window?.frame))",
                    "rowHits": "\(rowFrames.filter { $0.contains(point) }.count)", "rowCount": "\(rowFrames.count)",
                    "hitClass": hit.map { String(describing: type(of: $0)) } ?? "nil",
                    "dragging": "\(dragging)", "movableByBackground": "\(self.window?.isMovableByWindowBackground == true)"])
            }
            if event.type == .leftMouseUp { onPointerUp(); restoreWindowMovement(); return event }
            guard event.window === self.window else { return event }
            if let redo = TaskPanelUndoShortcut.redo(for: event, responder: self.window?.firstResponder), undoRedo(redo) {
                return nil
            }
            if event.type == .keyDown, event.keyCode == 53, dragging {
                TaskDragDiagnostics.record("native.escape-cancel")
                cancel()
                restoreWindowMovement()
                return nil
            }
            if event.type == .leftMouseDown {
                restoreWindowMovement()
                let hit = hitTestWindowPoint(event.locationInWindow)
                let activeEditor = self.window?.firstResponder as? TaskTextView
                let hitTaskEditor = (hit is TaskTextView) || (activeEditor.map { hit === $0 || hit?.isDescendant(of: $0) == true } ?? false)
                onPointerDown(hitTaskEditor)
                if !hitTaskEditor {
                    dismissEditor()
                    if activeEditor != nil, !(hit is NSTextField), !(hit is NSTextView) {
                        self.window?.makeFirstResponder(nil)
                    }
                }
                if rowFrames.contains(where: { $0.contains(self.convert(event.locationInWindow, from: nil)) }) {
                    guardedWindow = self.window
                    originalBackgroundMovement = self.window?.isMovableByWindowBackground
                    originalMovable = self.window?.isMovable
                    self.window?.isMovableByWindowBackground = false
                    // ⌘-drag otherwise moves the whole window before SwiftUI sees it.
                    if event.modifierFlags.contains(.command) { self.window?.isMovable = false }
                    TaskDragDiagnostics.record("native.disable-background-movement")
                }
            }
            return event
        }
        private func restoreWindowMovement() {
            onPointerUp()
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
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
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

