import AppKit
import XCTest
@testable import DotistApp

@MainActor
final class TaskDragDropTests: XCTestCase {
    private func source() -> TaskDragSourceView {
        _ = NSApplication.shared
        let window = DotistPanel(contentRect: NSRect(x: 200, y: 200, width: 200, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let view = TaskDragSourceView(id: "task-id", title: "A task", font: .systemFont(ofSize: 13))
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        window.contentView = view
        addTeardownBlock { window.close() }
        return view
    }
    private func event(_ type: NSEvent.EventType, point: NSPoint, in view: NSView, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    func testTitleAcceptsFirstClickAndDoesNotDragThePanel() {
        let view = source()
        var clicks = 0
        var begins = 0
        view.click = { clicks += 1 }
        view.begin = { begins += 1 }
        let before = view.window!.frame
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertFalse(view.mouseDownCanMoveWindow)
        view.mouseDown(with: event(.leftMouseDown, point: NSPoint(x: 40, y: 20), in: view))
        view.mouseUp(with: event(.leftMouseUp, point: NSPoint(x: 40, y: 20), in: view))
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(begins, 0)
        XCTAssertEqual(view.window!.frame, before)
    }

    func testSmallPointerMovementStillEditsOnceWithoutStartingDrag() {
        let view = source()
        var clicks = 0
        var begins = 0
        view.click = { clicks += 1 }
        view.begin = { begins += 1 }
        view.mouseDown(with: event(.leftMouseDown, point: NSPoint(x: 40, y: 20), in: view))
        view.mouseDragged(with: event(.leftMouseDragged, point: NSPoint(x: 42, y: 19), in: view))
        view.mouseUp(with: event(.leftMouseUp, point: NSPoint(x: 42, y: 19), in: view))
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(begins, 0)
    }

    func testReleasingOutsideTitleDoesNotEdit() {
        let view = source()
        var clicks = 0
        view.click = { clicks += 1 }
        view.mouseDown(with: event(.leftMouseDown, point: NSPoint(x: 40, y: 20), in: view))
        view.mouseUp(with: event(.leftMouseUp, point: NSPoint(x: 250, y: 20), in: view))
        XCTAssertEqual(clicks, 0)
        view.mouseDown(with: event(.leftMouseDown, point: NSPoint(x: 40, y: 20), in: view))
        view.mouseUp(with: event(.leftMouseUp, point: NSPoint(x: 40, y: 20), in: view))
        XCTAssertEqual(clicks, 1)
    }
}
