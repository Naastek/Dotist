import AppKit
import XCTest
@testable import DotistApp

@MainActor
final class BubblePointerTests: XCTestCase {
    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    private func panel(width: CGFloat = 48) -> DotistPanel {
        _ = NSApplication.shared
        let panel = DotistPanel(contentRect: NSRect(x: 200, y: 200, width: width, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = BubblePointerView(frame: NSRect(origin: .zero, size: panel.frame.size))
        addTeardownBlock { panel.close() }
        return panel
    }

    func testDragMovesTheWindowWithoutSystemDraggingAndDoesNotClick() {
        let panel = panel()
        let pointer = panel.contentView as! BubblePointerView
        var clicks = 0
        var starts = 0
        pointer.action = { clicks += 1 }
        pointer.drag = { starts += 1 }
        pointer.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 224, y: 224), in: panel))
        pointer.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 236, y: 218), in: panel))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 212, y: 194))
        pointer.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 144, y: 209), in: panel))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 120, y: 185))
        pointer.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 144, y: 209), in: panel))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(clicks, 0)
        XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))
        XCTAssertFalse(pointer.mouseDownCanMoveWindow)
        pointer.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 144, y: 209), in: panel))
        pointer.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 144, y: 209), in: panel))
        XCTAssertEqual(clicks, 1)
    }

    func testSmallPointerMovementStillClicksWithoutMovingTheWindow() {
        let panel = panel()
        let pointer = panel.contentView as! BubblePointerView
        var clicks = 0
        var starts = 0
        pointer.action = { clicks += 1 }
        pointer.drag = { starts += 1 }
        pointer.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 224, y: 224), in: panel))
        pointer.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 226, y: 226), in: panel))
        pointer.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 226, y: 226), in: panel))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 200, y: 200))
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(clicks, 1)
    }

    func testHoverCapsuleCanBeDraggedToScreenEdgesWithoutResizing() {
        let panel = panel(width: 280)
        let pointer = panel.contentView as! BubblePointerView
        let area = NSScreen.main!.visibleFrame
        for point in [NSPoint(x: area.minX + 24, y: area.midY), NSPoint(x: area.maxX - 24, y: area.midY), NSPoint(x: area.midX, y: area.maxY - 24), NSPoint(x: area.midX, y: area.minY + 24)] {
            panel.setFrameOrigin(NSPoint(x: 200, y: 200))
            pointer.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 224, y: 224), in: panel))
            pointer.mouseDragged(with: event(.leftMouseDragged, at: point, in: panel))
            XCTAssertEqual(panel.frame.origin, NSPoint(x: point.x - 24, y: point.y - 24))
            pointer.mouseUp(with: event(.leftMouseUp, at: point, in: panel))
            XCTAssertEqual(panel.frame.size, NSSize(width: 280, height: 48))
        }
    }
}
