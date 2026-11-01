import AppKit
import Combine
import DotistCore
import XCTest
@testable import DotistApp

@MainActor
final class PanelMotionTests: XCTestCase {
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

    private func group(_ id: String, model: AppModel, frame: NSRect) -> GroupPanelController {
        let controller = GroupPanelController(model: model, groupID: id, near: frame,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, didClose: { _ in })
        controller.window?.setFrame(frame, display: false)
        addTeardownBlock { controller.close() }
        return controller
    }

    private func waitForAnimations(_ motions: [PanelMotion]) async {
        let settled = expectation(description: "Each panel completes its own native transition")
        settled.expectedFulfillmentCount = motions.count
        let observations = motions.map { motion in
            motion.$animationInProgress.filter { !$0 }.first().sink { _ in settled.fulfill() }
        }
        await fulfillment(of: [settled], timeout: 3)
        withExtendedLifetime(observations) {}
    }

    func testGroupPanelsAnimateIndependentlyAndRestoreTheirOwnSizes() async throws {
        let model = try model()
        let area = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let work = group("work", model: model, frame: NSRect(x: area.minX + 70, y: area.minY + 70, width: 340, height: 480))
        let life = group("life", model: model, frame: NSRect(x: area.midX + 24, y: area.minY + 90, width: 360, height: 500))
        let workFrame = try XCTUnwrap(work.window).frame
        let lifeFrame = try XCTUnwrap(life.window).frame

        work.toggleCompact()
        XCTAssertTrue(work.motion.animationInProgress)
        XCTAssertTrue(work.compact)
        XCTAssertFalse(life.motion.animationInProgress)
        XCTAssertFalse(life.compact)
        XCTAssertEqual(life.window?.frame, lifeFrame)
        await waitForAnimations([work.motion])
        XCTAssertEqual(work.window?.frame.size, NSSize(width: 48, height: 48))
        XCTAssertFalse(try XCTUnwrap(work.window).styleMask.contains(.resizable))

        life.toggleCompact()
        work.toggleCompact()
        XCTAssertTrue(work.motion.animationInProgress)
        XCTAssertTrue(life.motion.animationInProgress)
        await waitForAnimations([work.motion, life.motion])
        XCTAssertFalse(work.compact)
        XCTAssertTrue(life.compact)
        XCTAssertEqual(work.window?.frame.size, workFrame.size)
        XCTAssertEqual(life.window?.frame.size, NSSize(width: 48, height: 48))
        XCTAssertTrue(try XCTUnwrap(work.window).styleMask.contains(.resizable))

        life.toggleCompact()
        await waitForAnimations([life.motion])
        XCTAssertEqual(life.window?.frame.size, lifeFrame.size)
        XCTAssertTrue(area.contains(try XCTUnwrap(work.window).frame))
        XCTAssertTrue(area.contains(try XCTUnwrap(life.window).frame))
    }

    func testGroupBubbleMovedAcrossScreenOpensItsHoverTowardTheInterior() async throws {
        let model = try model()
        let area = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let controller = group("work", model: model,
            frame: NSRect(x: area.maxX - 370, y: area.minY + 70, width: 340, height: 480))
        let panel = try XCTUnwrap(controller.window)
        controller.toggleCompact()
        await waitForAnimations([controller.motion])
        XCTAssertTrue(controller.motion.bubbleOnRight)

        // Keep the real pointer outside this invisible panel; do not move the user's mouse.
        let y = NSEvent.mouseLocation.y > area.midY ? area.minY + 60 : area.maxY - 108
        panel.setFrameOrigin(NSPoint(x: area.minX - 24, y: y))
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
        let retracted = expectation(description: "The group schedules its own hover retraction")
        let observation = controller.motion.$hovering.filter { !$0 }.first().sink { _ in retracted.fulfill() }
        await fulfillment(of: [retracted], timeout: 3)
        withExtendedLifetime(observation) {}
        controller.motion.finishHover(false)
        XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))
        XCTAssertEqual(panel.frame.minX, left, accuracy: 0.5)
    }
}
