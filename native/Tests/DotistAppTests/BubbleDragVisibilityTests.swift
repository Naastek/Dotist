import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

/// Deterministic geometry and event tests ensuring the compact floating bubble's
/// task count stays inside the visible 48x48 circle throughout press, drag,
/// cancel-release, hover-capsule drag, and group-panel drag.
@MainActor
final class BubbleDragVisibilityTests: XCTestCase {
    private func makeModel(hoverExpand: Bool = false, groupID: String? = nil) throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dotist-bubble-drag-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        var settings = DotistSettingsPatch()
        settings.hoverExpand = hoverExpand
        _ = try store.updateSettings(settings)
        if let groupID {
            _ = try store.addTask(title: "Group task", category: groupID)
        } else {
            _ = try store.addTask(title: "Inbox task", category: DotistGroup.inboxID)
        }
        return try AppModel(store: store)
    }

    private func makeFixture(
        initialFrame: NSRect,
        area: NSRect,
        hoverExpand: Bool = false,
        groupID: String? = nil
    ) throws -> (AppModel, DotistPanel, PanelMotion, DotistHostingView<FloatingPanelView<Color>>) {
        _ = NSApplication.shared
        let model = try makeModel(hoverExpand: hoverExpand, groupID: groupID)
        let panel = DotistPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.orderBack(nil)

        var environment = PanelMotion.Environment()
        environment.visibleFrame = { _ in area }
        environment.frameAnimationDuration = { _ in 0.34 }
        environment.pointerEventsEnabled = true
        environment.mouseLocation = { NSPoint(x: area.midX, y: area.midY) }
        environment.pressedMouseButtons = { 0 }

        let state = TaskPanelState(groupID: groupID)
        let motion = PanelMotion(
            model: model,
            panel: panel,
            size: initialFrame.size,
            title: { model.bubbleTitle },
            environment: environment
        )
        let host = DotistHostingView(
            rootView: FloatingPanelView(
                model: model,
                motion: motion,
                colorState: state,
                title: model.bubbleTitle,
                remaining: 1,
                total: 1,
                groupName: groupID == nil ? nil : "Work",
                contextMenu: { _, _ in },
                content: Color.clear
            )
        )
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: initialFrame.size)
        panel.contentView = host
        addTeardownBlock {
            motion.stop()
            panel.close()
        }
        return (model, panel, motion, host)
    }

    private func findViews(named className: String, in root: NSView) -> [NSView] {
        var result: [NSView] = []
        if String(describing: type(of: root)) == className {
            result.append(root)
        }
        for subview in root.subviews {
            result.append(contentsOf: findViews(named: className, in: subview))
        }
        return result
    }

    private func countTextView(in host: NSView) throws -> NSView {
        let candidates = findViews(named: "BubbleTextView", in: host)
        // The count badge always sits in a 48x48 container; hover/filter text views are either 0-width or != 48 width.
        let countView = candidates.first { abs($0.bounds.width - 48) < 0.5 && abs($0.bounds.height - 48) < 0.5 }
        return try XCTUnwrap(countView, "Expected 48x48 BubbleTextView for the count badge; found \(candidates.map(\.bounds))")
    }

    private func pointerView(in host: NSView) throws -> BubblePointerView {
        let pointers = findViews(named: "BubblePointerView", in: host).compactMap { $0 as? BubblePointerView }
        return try XCTUnwrap(pointers.first, "Expected BubblePointerView in FloatingPanelView")
    }

    private func mouseEvent(_ type: NSEvent.EventType, screenPoint: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: window.convertPoint(fromScreen: screenPoint),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func flushLayout(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
    }

    func testDraggingRightSideBubbleKeepsCountInsideWindowDuringAndAfterDrag() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("Requires a WindowServer display") }
        let area = screen.visibleFrame
        let expanded = NSRect(x: area.maxX - 380, y: area.maxY - 640, width: 364, height: 620)
        let (_, panel, motion, host) = try makeFixture(initialFrame: expanded, area: area, hoverExpand: false)

        motion.toggleBubble(in: area, animated: false)
        try await flushLayout(host)
        XCTAssertTrue(motion.bubble)
        XCTAssertTrue(motion.bubbleOnRight)
        XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))

        let pointer = try pointerView(in: host)
        let startOrigin = panel.frame.origin
        let downPoint = NSPoint(x: startOrigin.x + 24, y: startOrigin.y + 24)

        // Press prepares the expanded host window while keeping the compact surface pinned.
        pointer.mouseDown(with: mouseEvent(.leftMouseDown, screenPoint: downPoint, in: panel))
        try await flushLayout(host)
        XCTAssertTrue(motion.preparingExpansion)
        XCTAssertNotNil(motion.transitionHost)
        XCTAssertEqual(panel.frame.size, expanded.size)

        // Dragging past 4pt cancels expansion prep and shrinks the window back to 48x48.
        // The count badge must immediately return to (0, 0, 48, 48) inside the 48x48 window
        // while the drag is still in progress (before mouseUp).
        let dragPoint1 = NSPoint(x: downPoint.x - 40, y: downPoint.y - 20)
        pointer.mouseDragged(with: mouseEvent(.leftMouseDragged, screenPoint: dragPoint1, in: panel))
        try await flushLayout(host)

        XCTAssertFalse(motion.preparingExpansion)
        XCTAssertNil(motion.transitionHost)
        XCTAssertNil(motion.surface.transitionFrame)
        XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: startOrigin.x - 40, y: startOrigin.y - 20))

        let countDuringDrag1 = try countTextView(in: host)
        let rectDuringDrag1 = countDuringDrag1.convert(countDuringDrag1.bounds, to: host)
        XCTAssertTrue(
            host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rectDuringDrag1),
            "Count badge drifted outside 48x48 window during drag: \(rectDuringDrag1) not in \(host.bounds)"
        )
        XCTAssertEqual(rectDuringDrag1.minX, 0, accuracy: 0.5)
        XCTAssertEqual(rectDuringDrag1.minY, 0, accuracy: 0.5)

        // Continue dragging without crossing the screen midline.
        let dragPoint2 = NSPoint(x: downPoint.x - 90, y: downPoint.y - 60)
        pointer.mouseDragged(with: mouseEvent(.leftMouseDragged, screenPoint: dragPoint2, in: panel))
        try await flushLayout(host)
        let countDuringDrag2 = try countTextView(in: host)
        let rectDuringDrag2 = countDuringDrag2.convert(countDuringDrag2.bounds, to: host)
        XCTAssertEqual(rectDuringDrag2.minX, 0, accuracy: 0.5)
        XCTAssertEqual(rectDuringDrag2.minY, 0, accuracy: 0.5)

        // Release without crossing midline.
        pointer.mouseUp(with: mouseEvent(.leftMouseUp, screenPoint: dragPoint2, in: panel))
        try await flushLayout(host)
        let countAfterRelease = try countTextView(in: host)
        let rectAfterRelease = countAfterRelease.convert(countAfterRelease.bounds, to: host)
        XCTAssertEqual(rectAfterRelease.minX, 0, accuracy: 0.5)
        XCTAssertEqual(rectAfterRelease.minY, 0, accuracy: 0.5)
    }

    func testDraggingBottomLeftBubbleAcrossMidlineKeepsCountVisible() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("Requires a WindowServer display") }
        let area = screen.visibleFrame
        let expanded = NSRect(x: area.minX + 16, y: area.minY + 16, width: 364, height: 620)
        let (_, panel, motion, host) = try makeFixture(initialFrame: expanded, area: area, hoverExpand: true)

        // Collapse and immediately place near bottom-left so host.local(compact).minY > 0.
        motion.toggleBubble(in: area, animated: false)
        panel.setFrameOrigin(NSPoint(x: area.minX + 20, y: area.minY + 20))
        motion.finishBubbleMove()
        try await flushLayout(host)
        XCTAssertFalse(motion.bubbleOnRight)

        let pointer = try pointerView(in: host)
        let startOrigin = panel.frame.origin
        let downPoint = NSPoint(x: startOrigin.x + 24, y: startOrigin.y + 24)
        pointer.mouseDown(with: mouseEvent(.leftMouseDown, screenPoint: downPoint, in: panel))
        try await flushLayout(host)
        let hostBeforeDrag = try XCTUnwrap(motion.transitionHost)
        XCTAssertGreaterThan(hostBeforeDrag.local(hostBeforeDrag.compact).minY, 100)

        // Drag across screen midline to the right half.
        let targetPoint = NSPoint(x: area.maxX - 80, y: area.midY)
        pointer.mouseDragged(with: mouseEvent(.leftMouseDragged, screenPoint: targetPoint, in: panel))
        try await flushLayout(host)
        XCTAssertNil(motion.transitionHost)
        let countDuringDrag = try countTextView(in: host)
        let rectDuringDrag = countDuringDrag.convert(countDuringDrag.bounds, to: host)
        XCTAssertEqual(rectDuringDrag.minX, 0, accuracy: 0.5)
        XCTAssertEqual(rectDuringDrag.minY, 0, accuracy: 0.5)

        pointer.mouseUp(with: mouseEvent(.leftMouseUp, screenPoint: targetPoint, in: panel))
        try await flushLayout(host)
        XCTAssertTrue(motion.bubbleOnRight)
        let countAfterRelease = try countTextView(in: host)
        let rectAfterRelease = countAfterRelease.convert(countAfterRelease.bounds, to: host)
        XCTAssertEqual(rectAfterRelease.minX, 0, accuracy: 0.5)
        XCTAssertEqual(rectAfterRelease.minY, 0, accuracy: 0.5)
    }

    func testCancelReleaseOutsideBoundsRestoresCountInsideCompactWindow() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("Requires a WindowServer display") }
        let area = screen.visibleFrame
        let expanded = NSRect(x: area.maxX - 380, y: area.maxY - 640, width: 364, height: 620)
        let (_, panel, motion, host) = try makeFixture(initialFrame: expanded, area: area, hoverExpand: false)

        motion.toggleBubble(in: area, animated: false)
        try await flushLayout(host)
        let pointer = try pointerView(in: host)
        let startOrigin = panel.frame.origin
        let downPoint = NSPoint(x: startOrigin.x + 2, y: startOrigin.y + 24)

        pointer.mouseDown(with: mouseEvent(.leftMouseDown, screenPoint: downPoint, in: panel))
        try await flushLayout(host)
        XCTAssertTrue(motion.preparingExpansion)

        // Release slightly outside the left edge without exceeding the 4pt drag threshold.
        let releasePoint = NSPoint(x: startOrigin.x - 1, y: startOrigin.y + 24)
        pointer.mouseUp(with: mouseEvent(.leftMouseUp, screenPoint: releasePoint, in: panel))
        try await flushLayout(host)

        XCTAssertTrue(motion.bubble)
        XCTAssertNil(motion.transitionHost)
        XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))
        let countAfterCancel = try countTextView(in: host)
        let rectAfterCancel = countAfterCancel.convert(countAfterCancel.bounds, to: host)
        XCTAssertEqual(rectAfterCancel.minX, 0, accuracy: 0.5)
        XCTAssertEqual(rectAfterCancel.minY, 0, accuracy: 0.5)
    }

    func testDraggingHoverExpandedCapsuleAndGroupBubbleKeepsCountVisible() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("Requires a WindowServer display") }
        let area = screen.visibleFrame
        let expanded = NSRect(x: area.maxX - 380, y: area.maxY - 640, width: 364, height: 620)

        // 1. Hover-expanded capsule dragged mid-hover animation.
        do {
            let (_, panel, motion, host) = try makeFixture(initialFrame: expanded, area: area, hoverExpand: true)
            motion.toggleBubble(in: area, animated: false)
            try await flushLayout(host)
            motion.setHover(true, in: area)
            try await flushLayout(host)
            XCTAssertTrue(motion.hovering)
            XCTAssertGreaterThan(panel.frame.width, 48)

            let pointer = try pointerView(in: host)
            let startOrigin = panel.frame.origin
            let downPoint = NSPoint(x: panel.frame.maxX - 24, y: panel.frame.midY)
            pointer.mouseDown(with: mouseEvent(.leftMouseDown, screenPoint: downPoint, in: panel))
            pointer.mouseDragged(with: mouseEvent(.leftMouseDragged, screenPoint: NSPoint(x: downPoint.x - 50, y: downPoint.y - 30), in: panel))
            try await flushLayout(host)

            XCTAssertNil(motion.transitionHost)
            XCTAssertEqual(panel.frame.origin, NSPoint(x: startOrigin.x - 50, y: startOrigin.y - 30))
            let countDuringDrag = try countTextView(in: host)
            let rectDuringDrag = countDuringDrag.convert(countDuringDrag.bounds, to: host)
            XCTAssertTrue(
                host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rectDuringDrag),
                "Count badge drifted outside hover capsule during drag: \(rectDuringDrag) not in \(host.bounds)"
            )
            pointer.mouseUp(with: mouseEvent(.leftMouseUp, screenPoint: NSPoint(x: downPoint.x - 50, y: downPoint.y - 30), in: panel))
        }

        // 2. Group panel circular bubble drag.
        do {
            let (_, panel, motion, host) = try makeFixture(initialFrame: expanded, area: area, hoverExpand: false, groupID: "work")
            motion.toggleBubble(in: area, animated: false)
            try await flushLayout(host)

            let pointer = try pointerView(in: host)
            let downPoint = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            pointer.mouseDown(with: mouseEvent(.leftMouseDown, screenPoint: downPoint, in: panel))
            try await flushLayout(host)
            pointer.mouseDragged(with: mouseEvent(.leftMouseDragged, screenPoint: NSPoint(x: downPoint.x - 60, y: downPoint.y - 25), in: panel))
            try await flushLayout(host)

            XCTAssertNil(motion.transitionHost)
            XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))
            let countDuringDrag = try countTextView(in: host)
            let rectDuringDrag = countDuringDrag.convert(countDuringDrag.bounds, to: host)
            XCTAssertEqual(rectDuringDrag.minX, 0, accuracy: 0.5)
            XCTAssertEqual(rectDuringDrag.minY, 0, accuracy: 0.5)
            pointer.mouseUp(with: mouseEvent(.leftMouseUp, screenPoint: NSPoint(x: downPoint.x - 60, y: downPoint.y - 25), in: panel))
        }
    }

    func testCancelExpansionOnPressKeepsPreparingGuardActiveDuringFrameRestore() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("Requires a WindowServer display") }
        let area = screen.visibleFrame
        let expanded = NSRect(x: area.maxX - 380, y: area.maxY - 640, width: 364, height: 620)
        let (_, panel, motion, host) = try makeFixture(initialFrame: expanded, area: area, hoverExpand: false)

        motion.toggleBubble(in: area, animated: false)
        try await flushLayout(host)
        motion.prepareExpansionOnPress()
        XCTAssertTrue(motion.preparingExpansion)

        var observedPreparingDuringMove: [Bool] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                observedPreparingDuringMove.append(motion.preparingExpansion)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        motion.cancelExpansionOnPress()
        XCTAssertFalse(motion.preparingExpansion)
        XCTAssertNil(motion.transitionHost)
        XCTAssertTrue(
            observedPreparingDuringMove.allSatisfy { $0 },
            "windowDidMove during cancelExpansionOnPress must still see preparingExpansion == true"
        )
    }
}
