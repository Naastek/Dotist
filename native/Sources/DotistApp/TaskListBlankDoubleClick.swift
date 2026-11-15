import AppKit
import SwiftUI

/// Observe only this app's list viewport, without owning hit testing or dragging.
struct TaskListBlankDoubleClick: NSViewRepresentable {
    let enabled: Bool
    let origin: CGPoint
    let excluded: [CGRect]
    let add: () -> Void
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {
        view.enabled = enabled; view.origin = origin; view.excluded = excluded; view.add = add
    }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.stop() }

    final class Observer: NSView {
        var enabled = false
        var origin = CGPoint.zero
        var excluded: [CGRect] = []
        var add: () -> Void = {}
        private var monitor: Any?
        private var down: CGPoint?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.receive(event)
                return event
            }
        }
        func receive(_ event: NSEvent) {
            guard event.window === window, window != nil else { return }
            let local = convert(event.locationInWindow, from: nil)
            let point = CGPoint(x: local.x + origin.x, y: local.y + origin.y)
            let blank = enabled && bounds.contains(local) && !excluded.contains { $0.contains(point) }
            switch event.type {
            case .leftMouseDown: down = blank ? local : nil
            case .leftMouseDragged:
                if let start = down, hypot(local.x - start.x, local.y - start.y) >= 6 { down = nil }
            case .leftMouseUp:
                defer { down = nil }
                if let start = down, blank, event.clickCount == 2,
                   hypot(local.x - start.x, local.y - start.y) < 6 { add() }
            default: break
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil; down = nil
        }
    }
}
