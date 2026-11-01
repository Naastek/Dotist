import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class SearchDragTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testExpandedTaskPanelDoesNotHitItsWarmedInvisibleBubblePointer() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-warm-pointer-hit-\(UUID().uuidString)")
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addTask(title: "QA-warm-pointer-hit", category: DotistGroup.inboxID)
        let model = try AppModel(store: store)
        let state = TaskPanelState()
        let size = NSSize(width: 364, height: 620)
        let window = DotistPanel(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        let motion = PanelMotion(model: model, panel: window, size: size, title: { model.bubbleTitle })
        defer { motion.stop(); window.close(); try? FileManager.default.removeItem(at: directory) }
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let content = MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {},
            showGroupPanel: { _ in }, collapse: motion.toggleBubble)
        let hosting = DotistHostingView(rootView: FloatingPanelView(model: model, motion: motion, colorState: state, title: model.bubbleTitle,
            remaining: model.remainingCount, total: model.topLevelTasks.count, groupName: nil, contextMenu: { _, _ in }, content: content))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()

        XCTAssertFalse(motion.bubble)
        let pointers = descendants(container).compactMap { $0 as? BubblePointerView }
        XCTAssertEqual(pointers.count, 1, "The real bubble should remain mounted and warm")
        for pointer in pointers {
            var ancestor = pointer.superview
            var frames: [String] = []
            while let view = ancestor {
                frames.append("\(type(of: view)) frame=\(view.frame) inPanel=\(view.convert(view.bounds, to: container)) hidden=\(view.isHidden) alpha=\(view.alphaValue)")
                ancestor = view.superview
            }
            print("WARM_BUBBLE_POINTER frame=\(pointer.frame) inPanel=\(pointer.convert(pointer.bounds, to: container)) hidden=\(pointer.isHidden) ancestorHidden=\(pointer.isHiddenOrHasHiddenAncestor) alpha=\(pointer.alphaValue) ancestors=\(frames)")
        }
        // Header (44), group tabs (36), filters (42), Inbox header (32), then the first 32pt task row.
        let taskTitlePoint = NSPoint(x: 90, y: 450)
        let taskHit = try XCTUnwrap(container.hitTest(taskTitlePoint))
        print("WARM_BUBBLE_TASK_HIT \(type(of: taskHit)) at \(taskTitlePoint)")
        XCTAssertFalse(taskHit is BubblePointerView, "The invisible bubble must not intercept the task title")
        let collapseButtonPoint = NSPoint(x: 340, y: 598)
        let headerHit = try XCTUnwrap(container.hitTest(collapseButtonPoint))
        print("WARM_BUBBLE_HEADER_HIT \(type(of: headerHit)) at \(collapseButtonPoint)")
        XCTAssertFalse(headerHit is BubblePointerView, "The invisible bubble must not intercept expanded header controls")
    }

    func testSearchDragRegionsReceivePointerInputWithoutCoveringControls() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-search-drag-\(UUID().uuidString)")
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let window = QuickPanel(contentRect: NSRect(x: 200, y: 200, width: 600, height: 440), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 440))
        let hosting = DotistHostingView(rootView: CommandPalette(model: model, close: {}, reveal: { _ in }, revealGroup: { _ in }, showViews: {}))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()

        let pointerViews = descendants(container).compactMap { $0 as? BubblePointerView }
        XCTAssertEqual(pointerViews.count, 2)
        print("SEARCH_DRAG_REGIONS \(pointerViews.map { $0.convert($0.bounds, to: container) })")
        let headerPoint = NSPoint(x: 250, y: 422)
        let header = try XCTUnwrap(container.hitTest(headerPoint) as? BubblePointerView,
            "The header must hit the native pointer view rather than a covering hosting/glass view")
        XCTAssertFalse(header.mouseDownCanMoveWindow)
        XCTAssertFalse(container.hitTest(NSPoint(x: 250, y: 380)) is BubblePointerView,
            "The search field must remain interactive")
        XCTAssertFalse(container.hitTest(NSPoint(x: 572, y: 422)) is BubblePointerView,
            "The close button must remain interactive")
        XCTAssertTrue(container.hitTest(NSPoint(x: 250, y: 15)) is BubblePointerView)

        let source = window.convertPoint(toScreen: headerPoint)
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        header.mouseDown(with: event(.leftMouseDown, at: source))
        header.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: source.x + 40, y: source.y - 30)))
        XCTAssertEqual(window.frame.origin, NSPoint(x: 240, y: 170))
        header.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: source.x + 40, y: source.y - 30)))
    }
}
