import AppKit
import DotistCore
import XCTest
@testable import DotistApp

/// Controlled frame completions verify per-panel state and geometry; these
/// unordered fixtures do not validate visible native animation timing.
@MainActor
final class PanelMotionTests: XCTestCase {
    override func setUpWithError() throws {
        guard NSScreen.main != nil else { throw XCTSkip("Panel motion placement requires a WindowServer display") }
    }

    private func model() throws -> AppModel {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-motion-test-\(UUID().uuidString)")
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        var patch = DotistSettingsPatch()
        patch.hoverExpand = true
        patch.idleFade = false
        patch.autoCollapse = false
        _ = try store.updateSettings(patch)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try AppModel(store: store)
    }

    private func group(_ id: String, model: AppModel, frame: NSRect, input: PanelMotionTestEnvironment) -> GroupPanelController {
        let controller = GroupPanelController(model: model, groupID: id, near: frame,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, didClose: { _ in })
        controller.motion.environment = input.environment
        controller.window?.setFrame(frame, display: false)
        addTeardownBlock { controller.close() }
        return controller
    }

    func testGroupPanelsAnimateIndependentlyAndRestoreTheirOwnSizes() throws {
        let model = try model()
        let area = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let input = PanelMotionTestEnvironment(area: area)
        let work = group("work", model: model, frame: NSRect(x: area.minX + 70, y: area.minY + 70, width: 340, height: 480), input: input)
        let life = group("life", model: model, frame: NSRect(x: area.midX + 24, y: area.minY + 90, width: 360, height: 500), input: input)
        let workFrame = try XCTUnwrap(work.window).frame
        let lifeFrame = try XCTUnwrap(life.window).frame

        work.toggleCompact()
        XCTAssertTrue(work.motion.animationInProgress)
        XCTAssertTrue(work.compact)
        XCTAssertFalse(life.motion.animationInProgress)
        XCTAssertFalse(life.compact)
        XCTAssertEqual(life.window?.frame, lifeFrame)
        XCTAssertEqual(input.pendingFrameAnimationCount, 1)
        try input.sampleFrameAnimation(for: try XCTUnwrap(work.window), progress: 0.5)
        XCTAssertTrue(work.motion.animationInProgress)
        XCTAssertEqual(life.window?.frame, lifeFrame)
        try input.completeFrameAnimation(for: try XCTUnwrap(work.window))
        XCTAssertFalse(work.motion.animationInProgress)
        XCTAssertEqual(work.window?.frame.size, NSSize(width: 48, height: 48))
        XCTAssertFalse(try XCTUnwrap(work.window).styleMask.contains(.resizable))

        life.toggleCompact()
        work.toggleCompact()
        XCTAssertTrue(work.motion.animationInProgress)
        XCTAssertTrue(life.motion.animationInProgress)
        XCTAssertEqual(input.pendingFrameAnimationCount, 2)
        try input.completeFrameAnimation(for: try XCTUnwrap(work.window))
        XCTAssertFalse(work.motion.animationInProgress)
        XCTAssertTrue(life.motion.animationInProgress, "Completing work must not consume life's callback")
        XCTAssertEqual(life.window?.frame, lifeFrame)
        try input.completeFrameAnimation(for: try XCTUnwrap(life.window))
        XCTAssertFalse(life.motion.animationInProgress)
        XCTAssertFalse(work.compact)
        XCTAssertTrue(life.compact)
        XCTAssertEqual(work.window?.frame.size, workFrame.size)
        XCTAssertEqual(life.window?.frame.size, NSSize(width: 48, height: 48))
        XCTAssertTrue(try XCTUnwrap(work.window).styleMask.contains(.resizable))

        life.toggleCompact()
        XCTAssertTrue(life.motion.animationInProgress)
        try input.completeFrameAnimation(for: try XCTUnwrap(life.window))
        XCTAssertFalse(life.motion.animationInProgress)
        XCTAssertEqual(life.window?.frame.size, lifeFrame.size)
        XCTAssertTrue(area.contains(try XCTUnwrap(work.window).frame))
        XCTAssertTrue(area.contains(try XCTUnwrap(life.window).frame))
        XCTAssertEqual(input.pendingFrameAnimationCount, 0)
    }

    func testGroupBubbleMovedAcrossScreenOpensItsHoverTowardTheInterior() throws {
        let model = try model()
        let area = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let input = PanelMotionTestEnvironment(area: area)
        let controller = group("work", model: model,
            frame: NSRect(x: area.maxX - 370, y: area.minY + 70, width: 340, height: 480), input: input)
        let panel = try XCTUnwrap(controller.window)
        controller.toggleCompact()
        XCTAssertTrue(controller.motion.animationInProgress)
        try input.completeFrameAnimation(for: panel)
        XCTAssertFalse(controller.motion.animationInProgress)
        XCTAssertTrue(controller.motion.bubbleOnRight)

        // Pointer position/buttons and hover scheduling belong to this fixture.
        panel.setFrameOrigin(NSPoint(x: area.minX - 24, y: area.minY + 60))
        let restored = try XCTUnwrap(controller.motion.finishBubbleMove())
        XCTAssertTrue(area.contains(panel.frame))
        XCTAssertTrue(area.contains(restored))
        XCTAssertFalse(controller.motion.bubbleOnRight)
        let left = panel.frame.minX

        controller.motion.setHover(false)
        controller.motion.setHover(true)
        XCTAssertTrue(controller.motion.hovering)
        XCTAssertGreaterThan(panel.frame.width, 48)
        XCTAssertEqual(panel.frame.minX, left, accuracy: 0.5)
        XCTAssertLessThanOrEqual(panel.frame.maxX, area.maxX)

        // The view reports reveal completion through this public handoff; no desktop is rendered.
        controller.motion.finishHover(true)
        controller.motion.setHover(false)
        XCTAssertTrue(controller.motion.hovering, "Retraction is scheduled, not immediate")
        XCTAssertEqual(input.scheduledCount, 1)
        input.advance(by: 0.22)
        XCTAssertFalse(controller.motion.hovering)
        controller.motion.finishHover(false)
        XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))
        XCTAssertEqual(panel.frame.minX, left, accuracy: 0.5)
    }
}
