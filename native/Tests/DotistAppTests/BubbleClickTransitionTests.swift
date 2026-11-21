import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

/// Investigation controls, not a reproduction of the reported desktop jitter.
/// Uses a window-backed production tree without desktop input or ordered windows.
@MainActor
final class BubbleClickTransitionTests: XCTestCase {
    func testNativePointerClickWithRepeatedSubthresholdMovementStartsOnlyOneExpansion() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-pointer-click-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let panel = DotistPanel(contentRect: NSRect(x: 100, y: 100, width: 364, height: 620),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let input = PanelMotionTestEnvironment()
        var environment = input.environment
        environment.pointerEventsEnabled = true
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" }, environment: environment)
        defer { motion.stop(); panel.close() }
        let state = TaskPanelState()
        let host = DotistHostingView(rootView: FloatingPanelView(model: model, motion: motion, colorState: state,
            title: "", remaining: 0, total: 0, groupName: nil, contextMenu: { _, _ in }, content: Color.clear))
        host.sizingOptions = []
        panel.contentView = host
        motion.toggleBubble(in: input.area, animated: false)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        func pointers(_ view: NSView) -> [BubblePointerView] {
            (view as? BubblePointerView).map { [$0] } ?? view.subviews.flatMap(pointers)
        }
        let pointer = try XCTUnwrap(pointers(host).first)
        XCTAssertTrue(host.hitTest(NSPoint(x: 24, y: 24)) === pointer,
            "The native overlay must receive the compact center click")
        let resting = panel.frame
        func event(_ type: NSEvent.EventType, delta: CGFloat = 0) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 24 + delta, y: 24 - delta), modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        pointer.mouseDown(with: event(.leftMouseDown))
        for step in 0..<120 {
            pointer.mouseDragged(with: event(.leftMouseDragged, delta: step.isMultiple(of: 2) ? 1 : -1))
            XCTAssertEqual(panel.frame, resting)
        }
        pointer.mouseUp(with: event(.leftMouseUp))
        XCTAssertFalse(motion.bubble)
        XCTAssertTrue(motion.animationInProgress)
        XCTAssertEqual(input.pendingFrameAnimationCount, 1)
        try input.completeFrameAnimation(for: panel)
        XCTAssertEqual(panel.frame.size, NSSize(width: 364, height: 620))
        XCTAssertFalse(motion.animationInProgress)
    }

    func testClickDuringHoverAndFrameTransitionKeepsTheRequestedFrame() async throws {
        _ = NSApplication.shared
        for onRight in [false, true] {
            for reduceMotion in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-click-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
                var settings = DotistSettingsPatch()
                settings.hoverExpand = true
                _ = try store.updateSettings(settings)
                let model = try AppModel(store: store)
                let panel = DotistPanel(contentRect: NSRect(x: onRight ? 900 : 100, y: 100, width: 364, height: 620),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                let input = PanelMotionTestEnvironment()
                let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" }, environment: input.environment)
                defer { motion.stop(); panel.close() }
                let state = TaskPanelState()
                let host = DotistHostingView(rootView: FloatingPanelView(model: model, motion: motion, colorState: state,
                    title: "", remaining: 0, total: 0, groupName: nil, contextMenu: { _, _ in }, content: Color.clear)
                    .environment(\._accessibilityReduceMotion, reduceMotion))
                host.sizingOptions = []
                panel.contentView = host
                host.layoutSubtreeIfNeeded()
                motion.toggleBubble(in: input.area, animated: false)
                XCTAssertEqual(motion.bubbleOnRight, onRight)
                host.layoutSubtreeIfNeeded()
                motion.setHover(true)
                host.layoutSubtreeIfNeeded()
                // Same action used by both the native pointer and keyboard button.
                motion.toggleBubble()
                try await Task.sleep(for: .milliseconds(400))
                host.layoutSubtreeIfNeeded()
                XCTAssertFalse(motion.hoverAnimating)
                XCTAssertTrue(motion.animationInProgress)
                for step in 1...24 {
                    try input.sampleFrameAnimation(for: panel, progress: CGFloat(step) / 24)
                    let expected = panel.frame
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(2))
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(panel.frame, expected, "Layout must not compete with the frame driver")
                }
                try input.completeFrameAnimation(for: panel)
                XCTAssertFalse(motion.bubble)
                XCTAssertEqual(panel.frame.size, NSSize(width: 364, height: 620))
            }
        }
    }
}
