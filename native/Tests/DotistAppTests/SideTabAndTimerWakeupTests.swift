import AppKit
import DotistCore
import XCTest
@testable import DotistApp

@MainActor
final class SideTabAndTimerWakeupTests: XCTestCase {
    private final class Clock {
        var time: TimeInterval = 10
        var visible = true
        var reduceMotion = false
        var mouse = CGPoint(x: -10_000, y: -10_000)
        var mouseButtons = 0
    }

    private func makeHarness() throws -> (Clock, AppModel, DotistPanel, PanelMotion, PanelMotionTestEnvironment, SideTabsController) {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wakeup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = try AppModel(store: TaskStore(databasePath: dir.appendingPathComponent("tasks.sqlite").path))
        let panel = DotistPanel(contentRect: CGRect(x: 500, y: 100, width: 364, height: 620),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        let panelInput = PanelMotionTestEnvironment()
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" },
                                 environment: panelInput.environment)
        let clock = Clock()
        var env = SideTabsController.Environment()
        env.time = { clock.time }
        env.mouse = { clock.mouse }
        env.mouseButtons = { clock.mouseButtons }
        env.visible = { _ in clock.visible }
        env.visibleMinX = { _ in 0 }
        env.reduceMotion = { clock.reduceMotion }
        env.desktopEvents = false
        env.inputMonitors = false
        let controller = SideTabsController(parent: panel, model: model, state: TaskPanelState(), motion: motion, environment: env)
        return (clock, model, panel, motion, panelInput, controller)
    }

    func testSideTabsDisplayLinkPausesWhenIdleAndWakesOnlyForAnimation() throws {
        let (clock, _, panel, motion, panelInput, controller) = try makeHarness()
        defer { controller.stop(); motion.stop(); panel.close() }

        // Entrance starts at t=10 -> displayLink runs while tabs arrive.
        clock.time = 10.02
        controller.synchronize()
        XCTAssertEqual(controller.displayLink?.isPaused, false)

        // Once entrance finishes, displayLink pauses automatically.
        clock.time = 11.0
        controller.synchronize()
        XCTAssertEqual(controller.displayLink?.isPaused, true)

        // Hovering a tab wakes displayLink for smooth expansion.
        let child = try XCTUnwrap(panel.childWindows?.first)
        let ear = controller.renderedRows[0].rect
        clock.mouse = CGPoint(x: child.frame.minX + ear.midX, y: child.frame.minY + ear.midY)
        clock.time = 11.01
        controller.handlePointerEvent(at: clock.mouse)
        XCTAssertEqual(controller.displayLink?.isPaused, false)

        // After expansion completes, displayLink pauses again.
        clock.time = 11.5
        controller.synchronize()
        XCTAssertEqual(controller.displayLink?.isPaused, true)
        XCTAssertGreaterThan(controller.renderedRows[0].rect.width, 16)

        // Collapsing panel wakes displayLink for smooth retraction, then pauses when hidden.
        motion.toggleBubble(in: panelInput.area, animated: false)
        clock.time = 11.51
        controller.synchronize()
        XCTAssertEqual(controller.displayLink?.isPaused, false)

        clock.time = 12.2
        controller.synchronize()
        XCTAssertEqual(controller.displayLink?.isPaused, true)
        XCTAssertTrue(controller.renderedRows.allSatisfy { $0.opacity == 0 })
    }

    func testPointerOutsideInterestRegionDoesNotWakeSideTabsSynchronization() throws {
        let (clock, _, panel, motion, _, controller) = try makeHarness()
        defer { controller.stop(); motion.stop(); panel.close() }

        clock.time = 11.0
        controller.synchronize()
        let restingWidth = controller.renderedRows[0].rect.width
        XCTAssertEqual(controller.displayLink?.isPaused, true)

        // Moving pointer far away should leave tabs resting and displayLink paused.
        clock.time = 11.05
        controller.handlePointerEvent(at: CGPoint(x: 1200, y: 700))
        XCTAssertEqual(controller.renderedRows[0].rect.width, restingWidth, accuracy: 0.001)
        XCTAssertEqual(controller.displayLink?.isPaused, true)
    }

    func testOnDemandTimerDriverRunsOnlyWhileActive() {
        let driver = OnDemandTimerDriver()
        XCTAssertFalse(driver.isRunning)

        driver.setActive(false, every: 0.1)
        XCTAssertFalse(driver.isRunning)

        var ticks = 0
        driver.action = { ticks += 1 }
        driver.setActive(true, every: 0.02)
        XCTAssertTrue(driver.isRunning)

        // Calling setActive(true) repeatedly with the same interval keeps it running.
        driver.setActive(true, every: 0.02)
        XCTAssertTrue(driver.isRunning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertGreaterThan(ticks, 0)

        driver.setActive(false, every: 0.02)
        XCTAssertFalse(driver.isRunning)
        let afterStop = ticks
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(ticks, afterStop)
    }
}
