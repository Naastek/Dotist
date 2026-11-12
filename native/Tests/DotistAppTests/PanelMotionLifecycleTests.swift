import AppKit
import DotistCore
import XCTest
@testable import DotistApp

/// These regressions intentionally run without a WindowServer display too.
@MainActor
final class PanelMotionLifecycleTests: XCTestCase {
    private func panel() -> DotistPanel {
        _ = NSApplication.shared
        let panel = DotistPanel(contentRect: NSRect(x: 100, y: 100, width: 364, height: 620),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func model() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-motion-lifecycle-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        var settings = DotistSettingsPatch()
        settings.hoverExpand = true
        _ = try store.updateSettings(settings)
        return try AppModel(store: store)
    }

    func testIdleFadeChangesContentOpacityWithoutChangingPanelAlpha() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-idle-fade-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        var settings = DotistSettingsPatch()
        settings.idleFade = true
        settings.idleDelaySecs = 1
        settings.idleOpacity = 37
        settings.autoCollapse = false
        settings.locked = false
        _ = try store.updateSettings(settings)
        let model = try AppModel(store: store)
        let panel = panel()
        defer { panel.close() }
        var now = Date()
        var environment = PanelMotionTestEnvironment().environment
        environment.now = { now }
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" }, environment: environment)
        now = now.addingTimeInterval(2)
        motion.updateIdleState()
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertEqual(motion.idleContentOpacity, 0.37, accuracy: 0.0001)
    }

    func testAnimatorProxyDeliversFrameChangesToTheRealPanel() async throws {
        let panel = panel()
        defer { panel.close() }
        let target = NSRect(x: 150, y: 180, width: 48, height: 48)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(target, display: false)
        } completionHandler: {}
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(panel.frame, target)
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
        let origin = NSPoint(x: 210, y: 240)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrameOrigin(origin)
        } completionHandler: {}
        XCTAssertEqual(panel.frame.origin, origin)
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
    }

    func testEdgeAnimationClockCompletesAndCancellationStopsFurtherWrites() async throws {
        let panel = panel()
        defer { panel.close() }
        let start = panel.frame, target = NSRect(x: 150, y: 180, width: 48, height: 48)
        var completions = 0
        let animation = PanelFrameAnimation(window: panel, target: target, duration: 0.34) { completions += 1 }
        animation.startMotion()
        XCTAssertTrue(animation.isAnimating)
        XCTAssertNil(animation.displayLink, "Hidden clock tests use only the bounded fallback")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(panel.frame, target)
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(animation.isAnimating)
        XCTAssertNil(animation.displayLink)

        panel.setFrame(start, display: false)
        let cancelled = PanelFrameAnimation(window: panel, target: target, duration: 0.28) { completions += 1 }
        cancelled.startMotion()
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        let stopped = panel.frame
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(panel.frame, stopped)
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(cancelled.isAnimating)
        XCTAssertNil(cancelled.displayLink)
    }

    func testReleasingHiddenFrameDriverCancelsItsTaskWithoutRetainingAnimation() async throws {
        let panel = panel()
        defer { panel.close() }
        let start = panel.frame
        var completions = 0
        var animation: PanelFrameAnimation? = PanelFrameAnimation(window: panel,
            target: NSRect(x: 150, y: 180, width: 48, height: 48), duration: 0.28) { completions += 1 }
        weak var released = animation
        animation?.startMotion()
        XCTAssertNil(animation?.displayLink)
        animation = nil
        XCTAssertNil(released, "The bounded task must not keep its owner alive")
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(panel.frame, start)
        XCTAssertEqual(completions, 0)
    }

    func testClosingPanelStopsMotionAndRemovesShadowWindow() throws {
        let model = try model()
        let panel = panel()
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" },
                                 environment: PanelMotionTestEnvironment().environment)
        motion.refreshShadow()
        XCTAssertFalse(panel.hasShadow)
        let shadow = try XCTUnwrap(motion.shadowController?.window)
        XCTAssertTrue(panel.childWindows?.contains { $0 === shadow } ?? false)
        panel.close()
        XCTAssertFalse(shadow.isVisible)
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
        motion.refreshShadow()
        XCTAssertFalse(panel.hasShadow)
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true, "A closed panel must not create a shadow window")
        motion.stop()
    }

    func testReleasingMotionLeavesNoShadowWindowsWhileThePanelSurvives() throws {
        let model = try model()
        let panel = panel()
        defer { panel.close() }
        var motion: PanelMotion? = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" },
                                             environment: PanelMotionTestEnvironment().environment)
        let released = WeakBox(try XCTUnwrap(motion))
        motion?.refreshShadow()
        XCTAssertEqual(panel.childWindows?.count, 1)
        motion = nil
        XCTAssertNil(released.value)
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
    }

    func testStaleHoverRevealCompletionCannotConsumeTheRetraction() throws {
        let model = try model()
        let panel = panel()
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" },
                                 environment: PanelMotionTestEnvironment().environment)
        defer { motion.stop(); panel.close() }
        let area = NSRect(x: 0, y: 0, width: 1440, height: 1000)
        motion.toggleBubble(in: area, animated: false)
        let collapsedFrame = panel.frame
        let contentWidth = ceil(86 + BubbleContent(model: model).textWidth(language: model.language))
        let expectedWidth = min(contentWidth, min(440, area.width / 2))
        motion.setHover(true, in: area)
        XCTAssertEqual(panel.frame.width, expectedWidth)
        let revealedFrame = panel.frame
        motion.finishHover(true)
        motion.setHover(false, in: area)
        XCTAssertTrue(motion.hoverAnimating)
        XCTAssertFalse(motion.hovering)
        XCTAssertEqual(panel.frame, revealedFrame, "Keep the content-sized window until retraction completes")
        // A SwiftUI completion from the earlier reveal arrives late.
        motion.finishHover(true)
        XCTAssertTrue(motion.hoverAnimating)
        XCTAssertFalse(motion.hovering)
        XCTAssertEqual(panel.frame, revealedFrame, "A stale reveal completion must not shrink or move the retracting window")
        motion.finishHover(false)
        XCTAssertEqual(panel.frame, collapsedFrame)
        XCTAssertFalse(motion.hoverAnimating)
    }

    func testOneThousandMixedTransitionsWithImmediateCloseAndRelease() async throws {
        let model = try model()
        let area = NSRect(x: 0, y: 0, width: 1440, height: 1000)
        // Exercise the production hidden-window path, not the controlled driver.
        let input = PanelMotionTestEnvironment(area: area, frameAnimations: .native)
        var seed: UInt64 = 0xD07157
        var currentPanel: DotistPanel?
        var motion: PanelMotion?
        var pendingReleases: [(panel: WeakBox<DotistPanel>, motion: WeakBox<PanelMotion>)] = []
        for step in 0..<1000 {
            autoreleasepool {
                if motion == nil {
                    let next = panel()
                    currentPanel = next
                    motion = PanelMotion(model: model, panel: next, size: next.frame.size, title: { "" },
                                         environment: input.environment)
                    motion?.refreshShadow()
                }
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                switch (seed >> 32) % 8 {
                case 0, 1:
                    motion?.toggleBubble(in: area, animated: false)
                case 2:
                    motion?.beginBubbleDrag()
                    currentPanel?.setFrameOrigin(NSPoint(x: CGFloat(seed % 1300), y: CGFloat((seed >> 16) % 900)))
                    _ = motion?.finishBubbleMove()
                case 3:
                    motion?.setHover(true, in: area)
                    motion?.finishHover(true)
                case 4:
                    motion?.setHover(false, in: area)
                    motion?.finishHover(true) // stale completion during a newer transition
                    motion?.finishHover(false)
                case 5:
                    motion?.toggleBubble(in: area)
                    if let currentPanel, let motion {
                        XCTAssertFalse(currentPanel.isVisible)
                        XCTAssertFalse(motion.animationInProgress, "Hidden frame requests must finish before immediate close")
                        XCTAssertEqual(input.pendingFrameAnimationCount, 0)
                        // Keep real zero-duration proxy coverage without queuing
                        // a nonzero animation for an unordered window.
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = 0
                            currentPanel.animator().setFrame(currentPanel.frame, display: false)
                        } completionHandler: {}
                        pendingReleases.append((WeakBox(currentPanel), WeakBox(motion)))
                        currentPanel.close()
                        XCTAssertTrue(currentPanel.childWindows?.isEmpty ?? true)
                    }
                    motion = nil
                    currentPanel = nil
                case 6:
                    // No explicit stop: delayed work must not retain its owner.
                    let survivor = currentPanel
                    let released = motion.map(WeakBox.init)
                    motion = nil
                    if released?.value == nil { XCTAssertTrue(survivor?.childWindows?.isEmpty ?? true) }
                    survivor?.close()
                    currentPanel = nil
                default:
                    motion?.stop()
                    motion?.stop()
                    let frame = currentPanel?.frame
                    motion?.toggleBubble(in: area, animated: false)
                    motion?.refreshShadow()
                    XCTAssertEqual(currentPanel?.frame, frame)
                    XCTAssertTrue(currentPanel?.childWindows?.isEmpty ?? true)
                    currentPanel?.close()
                    motion = nil
                    currentPanel = nil
                }
                if let currentPanel { XCTAssertFalse(currentPanel.hasShadow, "Mixed transition \(step)") }
            }
            if step % 50 == 0 { try await Task.sleep(for: .milliseconds(1)) }
        }
        motion?.stop()
        currentPanel?.close()
        motion = nil
        currentPanel = nil
        try await Task.sleep(for: .milliseconds(700))
        for released in pendingReleases {
            XCTAssertNil(released.motion.value, "Completed animations must release their motion owner")
            XCTAssertNil(released.panel.value, "Completed animations must release their panel")
        }
    }

    func testRetractionWaitsForLeftButtonReleaseAndKeepsItsCore() throws {
        for onRight in [false, true] {
            let model = try model()
            let panel = panel()
            let input = PanelMotionTestEnvironment()
            let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" },
                                     environment: input.environment)
            defer { motion.stop(); panel.close() }
            var completions: [Bool] = []
            motion.environment.hoverDidFinish = { completions.append($0) }
            motion.toggleBubble(in: input.area, animated: false)
            motion.bubbleOnRight = onRight
            let collapsed = panel.frame
            input.pressedMouseButtons = 1
            motion.setHover(true)
            XCTAssertFalse(motion.hovering, "A drag must also block the initial hover entry")
            XCTAssertEqual(panel.frame, collapsed)
            input.pressedMouseButtons = 0
            motion.setHover(true)
            motion.finishHover(true)
            let revealed = panel.frame
            XCTAssertGreaterThan(revealed.width, 48)

            input.pressedMouseButtons = 1
            motion.setHover(false, in: input.area)
            motion.finishHover(false)
            XCTAssertEqual(panel.frame, revealed, "Never shrink a bubble during a user's drag")
            XCTAssertTrue(motion.hoverAnimating)
            XCTAssertFalse(motion.hovering)
            XCTAssertEqual(input.scheduledCount, 1)
            motion.finishHover(true) // the old reveal's completion is still stale
            XCTAssertTrue(motion.hoverAnimating)
            XCTAssertEqual(completions, [true])

            input.advance(by: 0.1) // one held-button check, without sleeping
            XCTAssertEqual(panel.frame, revealed)
            XCTAssertTrue(motion.hoverAnimating)
            XCTAssertEqual(input.scheduledCount, 1)
            input.pressedMouseButtons = 0
            input.advance(by: 0.1)
            XCTAssertEqual(panel.frame, collapsed)
            XCTAssertFalse(motion.hoverAnimating)
            XCTAssertEqual(completions, [true, false])
            XCTAssertEqual(input.scheduledCount, 0)
        }
    }

    func testDeferredRetractionReproducesTheOldCaptureSideChange() throws {
        let model = try model()
        let panel = panel()
        let input = PanelMotionTestEnvironment()
        let title = String(repeating: "Long project handoff ", count: 10)
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { title },
                                 environment: input.environment)
        defer { motion.stop(); panel.close() }
        XCTAssertNil(panel.delegate, "This fixture has no application windowDidMove callback")
        motion.toggleBubble(in: input.area, animated: false)
        motion.bubbleOnRight = false
        motion.setHover(true, in: input.area)
        motion.finishHover(true)
        XCTAssertEqual(panel.frame.width, 440)

        // The old matrix finished its left-side pass while the real user held
        // the mouse down, then started its right-side pass before that retry ran.
        input.pressedMouseButtons = 1
        motion.setHover(false, in: input.area)
        motion.finishHover(false)
        motion.bubbleOnRight = true
        motion.setHover(true, in: input.area)
        motion.finishHover(true)
        panel.setFrame(NSRect(x: 0, y: 0, width: 440, height: 48), display: false)
        XCTAssertTrue(motion.bubbleOnRight, "setFrame alone does not choose a new side")
        XCTAssertFalse(motion.hovering)
        XCTAssertTrue(motion.hoverAnimating)
        XCTAssertEqual(input.scheduledCount, 1)

        input.pressedMouseButtons = 0
        input.advance(by: 0.1)
        XCTAssertFalse(motion.bubbleOnRight, "The deferred retraction chooses the side at core x=416, left of screen center 720")
        XCTAssertTrue(motion.hovering, "The next reveal was queued behind that retraction")
        XCTAssertTrue(motion.hoverAnimating)
        XCTAssertEqual(panel.frame, NSRect(x: 392, y: 0, width: 440, height: 48))
        motion.finishHover(true)
        XCTAssertFalse(motion.hoverAnimating)
        // Subsequent old captures relocated this now-left-facing strip to zero.
        panel.setFrameOrigin(.zero)
        XCTAssertFalse(motion.bubbleOnRight)
        XCTAssertEqual(input.scheduledCount, 0)
    }

    func testDelayedHoverExitRechecksPointerPositionAndPressedButtons() throws {
        let model = try model()
        let panel = panel()
        let input = PanelMotionTestEnvironment()
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" },
                                 environment: input.environment)
        defer { motion.stop(); panel.close() }
        motion.toggleBubble(in: input.area, animated: false)
        let collapsed = panel.frame
        motion.setHover(true)
        motion.finishHover(true)
        let revealed = panel.frame

        motion.setHover(false)
        XCTAssertEqual(input.scheduledCount, 1)
        input.mouseLocation = NSPoint(x: revealed.midX, y: revealed.midY)
        input.advance(by: 0.22)
        XCTAssertTrue(motion.hovering, "Returning before the exit delay expires cancels the retraction")
        XCTAssertFalse(motion.hoverAnimating)
        XCTAssertEqual(panel.frame, revealed)

        input.mouseLocation = NSPoint(x: -10_000, y: -10_000)
        motion.setHover(false)
        input.pressedMouseButtons = 1
        input.advance(by: 0.22)
        XCTAssertTrue(motion.hovering, "A new drag during the delay must keep the strip open")
        XCTAssertEqual(panel.frame, revealed)

        input.pressedMouseButtons = 0
        motion.setHover(false)
        input.advance(by: 0.22)
        XCTAssertFalse(motion.hovering)
        XCTAssertTrue(motion.hoverAnimating)
        XCTAssertEqual(panel.frame, revealed)
        motion.finishHover(false)
        XCTAssertEqual(panel.frame, collapsed)
        XCTAssertFalse(motion.hoverAnimating)
        XCTAssertEqual(input.scheduledCount, 0)
    }

    func testFrameTransitionWaitsForItsDriverBeforeRestoringGeometry() throws {
        let model = try model()
        let panel = panel()
        let input = PanelMotionTestEnvironment()
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" },
                                 environment: input.environment)
        defer { motion.stop(); panel.close() }
        let expanded = panel.frame.size
        XCTAssertFalse(panel.isVisible)
        XCTAssertNotNil(motion.environment.animateFrame, "Only the explicit controlled driver bypasses hidden-window completion")
        motion.toggleBubble(in: input.area)
        XCTAssertTrue(motion.animationInProgress)
        XCTAssertEqual(panel.frame.size, expanded, "Requesting an animation must not fake its completion")
        XCTAssertEqual(input.pendingFrameAnimationCount, 1)
        XCTAssertEqual(try input.frameAnimationDuration(for: panel), 0.28)
        try input.sampleFrameAnimation(for: panel, progress: 0.5)
        XCTAssertTrue(motion.animationInProgress)
        XCTAssertGreaterThan(panel.frame.width, 48)
        XCTAssertLessThan(panel.frame.width, expanded.width)
        try input.completeFrameAnimation(for: panel)
        XCTAssertFalse(motion.animationInProgress)
        XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))
        XCTAssertFalse(panel.styleMask.contains(.resizable))

        motion.toggleBubble(in: input.area)
        XCTAssertTrue(motion.animationInProgress)
        XCTAssertEqual(try input.frameAnimationDuration(for: panel), 0.34)
        XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))
        try input.completeFrameAnimation(for: panel)
        XCTAssertFalse(motion.animationInProgress)
        XCTAssertEqual(panel.frame.size, expanded)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertEqual(input.pendingFrameAnimationCount, 0)
    }

    func testLateFrameCompletionCannotReviveAStoppedMotionOrRetainItsOwner() throws {
        let model = try model()
        let panel = panel()
        defer { panel.close() }
        let input = PanelMotionTestEnvironment()
        var motion: PanelMotion? = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" },
                                               environment: input.environment)
        motion?.toggleBubble(in: input.area)
        XCTAssertEqual(input.pendingFrameAnimationCount, 1)
        let frame = panel.frame
        motion?.stop()
        try input.completeFrameAnimation(for: panel)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.frame, frame, "A late completion must not resize a stopped window")
        XCTAssertFalse(try XCTUnwrap(motion).animationInProgress)

        motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" },
                             environment: input.environment)
        motion?.toggleBubble(in: input.area)
        let released = WeakBox(try XCTUnwrap(motion))
        motion = nil
        XCTAssertNil(released.value, "The retained driver callback must hold its motion owner weakly")
        try input.completeFrameAnimation(for: panel)
        XCTAssertEqual(panel.frame, frame)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
        XCTAssertEqual(input.pendingFrameAnimationCount, 0)
    }

}

/// Shared by motion and raster fixtures. Advancing a turn executes only the work
/// that was already due; a held button can never cause an unbounded retry loop.
@MainActor
final class PanelMotionTestEnvironment {
    enum FrameAnimationMode { case controlled, native }
    @MainActor
    private final class FrameAnimation {
        weak var panel: NSWindow?
        let start: NSRect
        let target: NSRect
        let duration: TimeInterval
        let completion: @MainActor () -> Void

        init(panel: NSWindow, target: NSRect, duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
            self.panel = panel
            start = panel.frame
            self.target = target
            self.duration = duration
            self.completion = completion
        }
    }

    var mouseLocation = NSPoint(x: -10_000, y: -10_000)
    var pressedMouseButtons = 0
    let area: NSRect
    private var time: TimeInterval = 0
    private var scheduled: [(deadline: TimeInterval, work: DispatchWorkItem)] = []
    private let frameAnimationMode: FrameAnimationMode
    private var frameAnimations: [FrameAnimation] = []

    init(area: NSRect = NSRect(x: 0, y: 0, width: 1440, height: 1000), frameAnimations: FrameAnimationMode = .controlled) {
        self.area = area
        frameAnimationMode = frameAnimations
    }

    var environment: PanelMotion.Environment {
        var result = PanelMotion.Environment()
        result.mouseLocation = { self.mouseLocation }
        result.pressedMouseButtons = { self.pressedMouseButtons }
        result.visibleFrame = { _ in self.area }
        result.schedule = { delay, work in self.scheduled.append((self.time + delay, work)) }
        result.pointerEventsEnabled = false
        if frameAnimationMode == .controlled {
            result.frameAnimationDuration = { $0 ? 0.28 : 0.34 }
            result.animateFrame = { panel, target, duration, completion in
                self.frameAnimations.append(FrameAnimation(panel: panel, target: target, duration: duration, completion: completion))
            }
        }
        return result
    }

    var scheduledCount: Int { scheduled.filter { !$0.work.isCancelled }.count }
    var pendingFrameAnimationCount: Int { frameAnimations.count }

    func frameAnimationDuration(for panel: NSWindow) throws -> TimeInterval {
        try XCTUnwrap(frameAnimations.first { $0.panel === panel }).duration
    }

    func sampleFrameAnimation(for panel: NSWindow, progress: CGFloat) throws {
        precondition((0...1).contains(progress))
        let animation = try XCTUnwrap(frameAnimations.first { $0.panel === panel })
        let start = animation.start, target = animation.target
        panel.setFrame(NSRect(x: start.minX + (target.minX - start.minX) * progress,
                              y: start.minY + (target.minY - start.minY) * progress,
                              width: start.width + (target.width - start.width) * progress,
                              height: start.height + (target.height - start.height) * progress), display: false)
    }

    func completeFrameAnimation(for panel: NSWindow) throws {
        let index = try XCTUnwrap(frameAnimations.firstIndex { $0.panel === panel })
        let animation = frameAnimations.remove(at: index)
        // The production completion applies the target behind its stopped/weak
        // owner guards. The fixture must not resize closed windows on its behalf.
        animation.completion()
    }

    func advance(by interval: TimeInterval) {
        precondition(interval >= 0)
        time += interval
        let due = scheduled.filter { $0.deadline <= time }.sorted { $0.deadline < $1.deadline }
        scheduled.removeAll { $0.deadline <= time }
        for entry in due where !entry.work.isCancelled { entry.work.perform() }
    }
}

private final class WeakBox<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}
