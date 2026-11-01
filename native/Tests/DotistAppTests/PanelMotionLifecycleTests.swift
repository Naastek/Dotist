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
        return try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
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

    func testClosingPanelStopsMotionWithoutCreatingShadowWindows() throws {
        let model = try model()
        let panel = panel()
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" })
        motion.refreshShadow()
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
        panel.close()
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
        motion.refreshShadow()
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true, "A closed panel must not create a shadow window")
        motion.stop()
    }

    func testReleasingMotionLeavesNoShadowWindowsWhileThePanelSurvives() throws {
        let model = try model()
        let panel = panel()
        defer { panel.close() }
        var motion: PanelMotion? = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" })
        let released = WeakBox(try XCTUnwrap(motion))
        motion?.refreshShadow()
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
        motion = nil
        XCTAssertNil(released.value)
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
    }

    func testStaleHoverRevealCompletionCannotConsumeTheRetraction() throws {
        let model = try model()
        let panel = panel()
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" })
        defer { motion.stop(); panel.close() }
        let area = NSRect(x: 0, y: 0, width: 1440, height: 1000)
        motion.toggleBubble(in: area, animated: false)
        motion.setHover(true, in: area)
        XCTAssertEqual(panel.frame.width, 250)
        motion.finishHover(true)
        motion.setHover(false, in: area)
        XCTAssertTrue(motion.hoverAnimating)
        // A SwiftUI completion from the earlier reveal arrives late.
        motion.finishHover(true)
        XCTAssertTrue(motion.hoverAnimating)
        motion.finishHover(false)
        XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))
        XCTAssertFalse(motion.hoverAnimating)
    }

    func testOneThousandMixedTransitionsWithImmediateCloseAndRelease() async throws {
        let model = try model()
        let area = NSRect(x: 0, y: 0, width: 1440, height: 1000)
        var seed: UInt64 = 0xD07157
        var currentPanel: DotistPanel?
        var motion: PanelMotion?
        var pendingReleases: [(panel: WeakBox<DotistPanel>, motion: WeakBox<PanelMotion>)] = []
        for step in 0..<1000 {
            autoreleasepool {
                if motion == nil {
                    let next = panel()
                    currentPanel = next
                    motion = PanelMotion(model: model, panel: next, size: next.frame.size, title: { "" })
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
                        // Exercise the forwarding proxy even when ordinary animated
                        // transitions fall back to synchronous geometry headlessly.
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

}

private final class WeakBox<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}
