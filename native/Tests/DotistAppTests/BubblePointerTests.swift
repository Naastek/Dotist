import AppKit
import XCTest
@testable import DotistApp

@MainActor
final class BubblePointerTests: XCTestCase {
    func testUnpluggedDisplayPlacementDoesNotOverwriteThePreferredFrame() {
        let main = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let external = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        let preferred = NSRect(x: 2100, y: 260, width: 364, height: 620)
        let parked = DotistDelegate.screenPlacement(for: preferred, screens: [main], main: main)
        XCTAssertTrue(main.contains(parked))
        XCTAssertEqual(DotistDelegate.screenPlacement(for: preferred, screens: [main, external], main: main), preferred)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
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
        var ends = 0
        pointer.action = { clicks += 1 }
        pointer.drag = { starts += 1 }
        pointer.dragEnd = { ends += 1 }
        pointer.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 224, y: 224), in: panel))
        pointer.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 236, y: 218), in: panel))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 212, y: 194))
        pointer.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 144, y: 209), in: panel))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 120, y: 185))
        pointer.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 144, y: 209), in: panel))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(clicks, 0)
        XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))
        XCTAssertFalse(pointer.mouseDownCanMoveWindow)
        pointer.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 144, y: 209), in: panel))
        pointer.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 144, y: 209), in: panel))
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(ends, 1)
    }

    func testSmallPointerMovementStillClicksWithoutMovingTheWindow() {
        let panel = panel()
        let pointer = panel.contentView as! BubblePointerView
        var clicks = 0
        var starts = 0
        var ends = 0
        pointer.action = { clicks += 1 }
        pointer.drag = { starts += 1 }
        pointer.dragEnd = { ends += 1 }
        pointer.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 224, y: 224), in: panel))
        pointer.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 226, y: 226), in: panel))
        pointer.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 226, y: 226), in: panel))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 200, y: 200))
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(ends, 0)
        XCTAssertEqual(clicks, 1)
    }

    func testHoverTracksEntryAndExitWithoutRequiringAKeyWindow() throws {
        let panel = panel()
        let pointer = panel.contentView as! BubblePointerView
        var changes: [Bool] = []
        pointer.hover = { changes.append($0) }
        pointer.updateTrackingAreas()
        let tracking = try XCTUnwrap(pointer.trackingAreas.first)
        XCTAssertTrue(tracking.options.contains([.activeAlways, .inVisibleRect, .mouseEnteredAndExited]))
        XCTAssertFalse(panel.isKeyWindow)
        for type in [NSEvent.EventType.mouseEntered, .mouseExited, .mouseEntered] {
            let event = NSEvent.enterExitEvent(with: type, location: NSPoint(x: 24, y: 24), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, trackingNumber: 1, userData: nil)!
            if type == .mouseEntered { pointer.mouseEntered(with: event) }
            if type == .mouseExited { pointer.mouseExited(with: event) }
        }
        XCTAssertEqual(changes, [true, false, true])
        pointer.setFrameSize(NSSize(width: 280, height: 48))
        pointer.updateTrackingAreas()
        XCTAssertEqual(pointer.trackingAreas.count, 1)
    }

    func testSecondaryClickOpensMenuWithoutClickingOrDraggingInBothShapes() {
        for width: CGFloat in [48, 280] {
            let panel = panel(width: width)
            let pointer = panel.contentView as! BubblePointerView
            let point = NSPoint(x: 200 + width / 2, y: 224)
            var clicks = 0
            var starts = 0
            var ends = 0
            var menus = 0
            pointer.action = { clicks += 1 }
            pointer.drag = { starts += 1 }
            pointer.dragEnd = { ends += 1 }
            pointer.contextMenu = { [weak pointer] event, view in
                XCTAssertEqual(event.type, .rightMouseDown)
                XCTAssertTrue(view === pointer)
                menus += 1
            }
            pointer.rightMouseDown(with: event(.rightMouseDown, at: point, in: panel))
            pointer.rightMouseUp(with: event(.rightMouseUp, at: point, in: panel))
            XCTAssertEqual(menus, 1)
            XCTAssertEqual(clicks, 0)
            XCTAssertEqual(starts, 0)
            XCTAssertEqual(ends, 0)
            XCTAssertEqual(panel.frame, NSRect(x: 200, y: 200, width: width, height: 48))
            pointer.mouseDown(with: event(.leftMouseDown, at: point, in: panel))
            pointer.mouseUp(with: event(.leftMouseUp, at: point, in: panel))
            XCTAssertEqual(clicks, 1)
            XCTAssertEqual(ends, 0)
        }
    }

    func testControlClickOpensMenuWithoutArmingPrimaryDrag() {
        let panel = panel(width: 280)
        let pointer = panel.contentView as! BubblePointerView
        let point = NSPoint(x: 340, y: 224)
        var menus = 0
        var clicks = 0
        var starts = 0
        var ends = 0
        pointer.contextMenu = { event, _ in
            XCTAssertTrue(event.modifierFlags.contains(.control))
            menus += 1
        }
        pointer.action = { clicks += 1 }
        pointer.drag = { starts += 1 }
        pointer.dragEnd = { ends += 1 }
        pointer.mouseDown(with: event(.leftMouseDown, at: point, in: panel, modifiers: .control))
        pointer.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 380, y: 224), in: panel, modifiers: .control))
        pointer.mouseUp(with: event(.leftMouseUp, at: point, in: panel, modifiers: .control))
        XCTAssertEqual(menus, 1)
        XCTAssertEqual(clicks, 0)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(ends, 0)
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 200, y: 200))
    }

    func testHoverCapsuleCanBeDraggedToScreenEdgesWithoutResizing() throws {
        guard let area = NSScreen.main?.visibleFrame else { throw XCTSkip("Screen-edge placement requires a WindowServer display") }
        let panel = panel(width: 280)
        let pointer = panel.contentView as! BubblePointerView
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
