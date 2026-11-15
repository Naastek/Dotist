import AppKit
import XCTest
@testable import DotistApp

@MainActor
final class BlankDraftClickTests: XCTestCase {
    func testBlankClickPassesThroughAndDragDoesNotDismiss() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let observer = TaskListBlankDoubleClick.Observer(frame: window.contentView!.bounds)
        window.contentView!.addSubview(observer)
        var dismissals = 0
        observer.dismissEmptyDraft = { dismissals += 1 }
        func send(_ type: NSEvent.EventType, _ x: CGFloat) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 80), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            observer.receive(event)
        }
        XCTAssertNil(observer.hitTest(NSPoint(x: 30, y: 80)))
        try send(.leftMouseDown, 30); try send(.leftMouseUp, 30)
        XCTAssertEqual(dismissals, 1)
        try send(.leftMouseDown, 30); try send(.leftMouseDragged, 60); try send(.leftMouseUp, 60)
        XCTAssertEqual(dismissals, 1)
        observer.stop()
    }
}
