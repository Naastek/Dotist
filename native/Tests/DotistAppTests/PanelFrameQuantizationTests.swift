import AppKit
import QuartzCore
import DotistCore
import SwiftUI
import Combine
import XCTest
@testable import DotistApp

/// Geometry only. No production app, input events, image APIs, or user data.
@MainActor
final class PanelFrameQuantizationTests: XCTestCase {
    private func productionInsetFixture(frame: NSRect = NSRect(x: 1219, y: 352, width: 454, height: 568),
                                        area: NSRect = NSRect(x: 0, y: 0, width: 1728, height: 1117)) throws
        -> (PanelMotion, DotistPanel, PanelMotionTestEnvironment) {
        _ = NSApplication.shared
        let directory = outputRoot.appendingPathComponent("continuous-inset-test-\(UUID().uuidString)")
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let panel = DotistPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let input = PanelMotionTestEnvironment(area: area)
        return (PanelMotion(model: model, panel: panel, size: frame.size, title: { "Synthetic inset regression" },
                            environment: input.environment), panel, input)
    }
    private func surfaceBounds(frame: NSRect, inset: EdgeInsets) -> NSRect {
        NSRect(x: frame.minX + inset.leading, y: frame.minY + inset.bottom,
               width: frame.width - inset.leading - inset.trailing, height: frame.height - inset.top - inset.bottom)
    }

    private func productionSurfaceBounds(_ motion: PanelMotion, transparent: Bool = true, contrast: Bool = false) -> NSRect {
        surfaceBounds(frame: motion.panel.frame, inset: FloatingSurface.opticalInsets(compact: motion.bubble,
            reduceTransparency: !transparent, increasedContrast: contrast, frameInsets: motion.surfaceInsets))
    }

    func testProductionInsetHandoffDoesNotJumpBeforeFirstWindowFrame() throws {
        let (motion, panel, input) = try productionInsetFixture()
        defer { motion.stop(); panel.close() }
        motion.toggleBubble(in: input.area, animated: false)
        motion.setHover(true, in: input.area)
        panel.setFrame(NSRect(x: 1425, y: 874, width: 250, height: 48), display: false)
        motion.finishHover(true)
        let before = productionSurfaceBounds(motion), old = panel.frame
        motion.toggleBubble(in: input.area)
        XCTAssertFalse(motion.bubble); XCTAssertTrue(motion.animationInProgress); XCTAssertEqual(panel.frame, old)
        let after = productionSurfaceBounds(motion)
        print("PRODUCTION_INSET_HANDOFF before=\(before) after=\(after)")
        XCTAssertEqual(after.maxY, before.maxY, "Production top must preserve its start visible anchor before frame movement")
        XCTAssertEqual(after.maxX, before.maxX, "Production right must preserve its start visible anchor before frame movement")
        XCTAssertFalse(panel.isVisible)
    }

    func testProductionInsetExpansionAndCollapseBoundaries() async throws {
        let full = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let cases: [(String, NSRect, NSRect, Bool, CGFloat)] = [
            ("right-hover", NSRect(x: 1219, y: 352, width: 454, height: 568), full, true, 250),
            ("left-hover", NSRect(x: 80, y: 120, width: 454, height: 568), full, false, 250),
            ("clipped-zero-anchors", NSRect(x: 0, y: 0, width: 900, height: 900), NSRect(x: 0, y: 0, width: 500, height: 600), true, 250),
            ("clipped-left", NSRect(x: 0, y: 0, width: 900, height: 900), NSRect(x: 0, y: 0, width: 500, height: 600), false, 250),
            ("unequal-dimensions", NSRect(x: 600, y: 70, width: 360, height: 740), full, true, 190),
            ("translated-screen", NSRect(x: -600, y: 100, width: 400, height: 520), NSRect(x: -900, y: 0, width: 900, height: 1000), false, 200)
        ]
        for (name, initial, area, onRight, hoverWidth) in cases {
            let (motion, panel, input) = try productionInsetFixture(frame: initial, area: area)
            defer { motion.stop(); panel.close() }
            motion.toggleBubble(in: area, animated: false)
            motion.bubbleOnRight = onRight
            let ball = panel.frame
            motion.setHover(true, in: area)
            panel.setFrame(NSRect(x: onRight ? ball.maxX - hoverWidth : ball.minX, y: ball.minY, width: hoverWidth, height: 48), display: false)
            motion.finishHover(true)
            var requested: NSRect?
            let controlled = try XCTUnwrap(motion.environment.animateFrame)
            motion.environment.animateFrame = { window, target, duration, complete in
                requested = target; controlled(window, target, duration, complete)
            }
            for direction in ["expand", "collapse"] {
                let before = productionSurfaceBounds(motion), start = panel.frame
                motion.toggleBubble(in: area)
                let target = try XCTUnwrap(requested)
                XCTAssertEqual(panel.frame, start); XCTAssertEqual(productionSurfaceBounds(motion), before)
                let endInsets = FloatingSurface.opticalInsets(compact: motion.bubble, reduceTransparency: false, increasedContrast: false)
                let end = surfaceBounds(frame: target, inset: endInsets), right = motion.bubbleOnRight
                let fromX = right ? before.maxX : before.minX, toX = right ? end.maxX : end.minX
                var lastX = fromX, lastY = before.maxY
                let driver = PanelFrameAnimation(window: panel, target: target, duration: 0.34) {}
                for step in 1...100 {
                    driver.currentProgress = Float(step) / 100
                    try await Task.sleep(for: .milliseconds(1))
                    let visible = productionSurfaceBounds(motion), x = right ? visible.maxX : visible.minX
                    if fromX == toX { XCTAssertEqual(x, toX, accuracy: 0.000001, name) }
                    else { XCTAssertGreaterThanOrEqual((x - lastX) * (toX - fromX), -0.000001, name) }
                    if before.maxY == end.maxY { XCTAssertEqual(visible.maxY, end.maxY, accuracy: 0.000001, name) }
                    else { XCTAssertGreaterThanOrEqual((visible.maxY - lastY) * (end.maxY - before.maxY), -0.000001, name) }
                    XCTAssertGreaterThan(visible.width, 0); XCTAssertGreaterThan(visible.height, 0)
                    XCTAssertEqual(productionSurfaceBounds(motion, transparent: false), panel.frame)
                    XCTAssertEqual(productionSurfaceBounds(motion, contrast: true), panel.frame)
                    lastX = x; lastY = visible.maxY
                }
                XCTAssertEqual(productionSurfaceBounds(motion), end, "Actual-frame publication must reach endpoint before completion")
                try input.completeFrameAnimation(for: panel)
                XCTAssertEqual(productionSurfaceBounds(motion), end); XCTAssertFalse(motion.animationInProgress)
                print("PRODUCTION_INSET_CASE \(name) \(direction) start=\(start) target=\(target) side=\(right ? "right" : "left") passed")
            }
            XCTAssertFalse(panel.isVisible)
        }
    }

    func testProductionInsetPublishesOriginOnlyFramesAndStopsPublishingAfterStop() async throws {
        let (motion, panel, input) = try productionInsetFixture()
        defer { motion.stop(); panel.close() }
        motion.toggleBubble(in: input.area, animated: false); motion.setHover(true, in: input.area)
        panel.setFrame(NSRect(x: 1425, y: 874, width: 250, height: 48), display: false); motion.finishHover(true)
        motion.toggleBubble(in: input.area)
        var updates = 0
        let observation = motion.$surfaceInsets.dropFirst().sink { _ in updates += 1 }
        defer { observation.cancel() }
        panel.setFrame(NSRect(x: 1374, y: 744, width: 301, height: 178), display: false)
        try await Task.sleep(for: .milliseconds(5))
        let count = updates, size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: 1373, y: 743))
        try await Task.sleep(for: .milliseconds(5))
        XCTAssertEqual(panel.frame.size, size); XCTAssertGreaterThan(updates, count)
        XCTAssertEqual(motion.surfaceInsets.top, 1); XCTAssertEqual(motion.surfaceInsets.trailing, 1)
        let frozen = motion.surfaceInsets
        motion.stop()
        let stoppedCount = updates
        panel.setFrameOrigin(NSPoint(x: 1370, y: 740))
        try await Task.sleep(for: .milliseconds(5))
        XCTAssertEqual(motion.surfaceInsets, frozen); XCTAssertEqual(updates, stoppedCount)
        try input.completeFrameAnimation(for: panel)
        XCTAssertEqual(motion.surfaceInsets, frozen)
    }

    func testProductionInsetZeroDurationAndGeometricDegeneracy() throws {
        let (motion, panel, input) = try productionInsetFixture()
        defer { motion.stop(); panel.close() }
        var driver: PanelFrameAnimation?
        motion.environment.frameAnimationDuration = { _ in 0 }
        motion.environment.animateFrame = { window, target, duration, complete in
            driver = PanelFrameAnimation(window: window, target: target, duration: duration, completion: complete)
            driver?.startMotion()
        }
        for _ in 0..<2 {
            motion.toggleBubble(in: input.area)
            XCTAssertFalse(motion.animationInProgress); XCTAssertFalse(try XCTUnwrap(driver).isAnimating)
            XCTAssertNil(driver?.displayLink)
            XCTAssertEqual(motion.surfaceInsets.top, motion.bubble ? 2 : 0)
        }
        let two = EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        let stationary = PanelSurfaceTransition(start: panel.frame, target: panel.frame, from: two, to: EdgeInsets(), onRight: false)
        XCTAssertEqual(stationary.insets(at: panel.frame), EdgeInsets(), "No frame motion means no invented inset clock")
        for (sx, sy) in [(CGFloat(1), CGFloat(1)), (2, 0.5), (0.5, 3)] {
            let start = NSRect(x: 20 * sx, y: 10 * sy, width: 80 * sx, height: 100 * sy)
            let target = NSRect(x: 20 * sx, y: -90 * sy, width: 180 * sx, height: 200 * sy)
            let geometry = PanelSurfaceTransition(start: start, target: target, from: two, to: EdgeInsets(), onRight: false)
            let mid = NSRect(x: start.minX, y: (start.minY + target.minY) / 2,
                             width: (start.width + target.width) / 2, height: (start.height + target.height) / 2)
            // Left and top are stationary; fallback uses the actual other edges.
            XCTAssertEqual(geometry.insets(at: mid).leading, 1, accuracy: 0.000001)
            XCTAssertEqual(geometry.insets(at: mid).top, 1, accuracy: 0.000001)
        }
    }

    private let axes = ["left", "right", "top", "bottom", "width", "height"]
    private var outputRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/glass-transition")
    }

    // Every rect here is [x, y, width, height] in CG global POINTS, not backing pixels.
    private func edges(_ r: [Double]) -> [Double] { [r[0], r[0] + r[2], r[1], r[1] + r[3], r[2], r[3]] }
    private func raw(_ r: NSRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    private func cg(_ r: [Double], primaryTop: Double) -> [Double] {
        [r[0], primaryTop - r[1] - r[3], r[2], r[3]]
    }
    private func reversals(_ rects: [[Double]], start: [Double], target: [Double]) -> [[String: Any]] {
        let a = edges(start), b = edges(target)
        return rects.indices.dropFirst().flatMap { i -> [[String: Any]] in
            let before = edges(rects[i - 1]), after = edges(rects[i])
            return axes.indices.compactMap { axis in
                let step = after[axis] - before[axis], direction = b[axis] - a[axis]
                guard abs(step) > 0.000001, direction == 0 || step * direction < 0 else { return nil }
                return ["axis": axes[axis], "beforeIndex": i - 1, "afterIndex": i,
                        "before": before[axis], "after": after[axis], "delta": step]
            }
        }
    }
    private func write(_ report: [String: Any], name: String) throws {
        let url = outputRoot.appendingPathComponent("quantization-\(name)-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        print("QUANTIZATION_JSON=\(url.path)")
    }

    func testDetectorCatchesOnePointTopAndRightReversalsWithoutExternalData() {
        // Minimal consecutive native RED samples, screen height 1117.
        let a = cg([217, 802, 278, 119], primaryTop: 1117)
        let b = cg([212, 788, 284, 134], primaryTop: 1117)
        let found = reversals([a, b], start: [246, 195, 250, 48], target: [40, 197, 454, 568])
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first { $0["axis"] as? String == "top" }?["delta"] as? Double, -1)
        XCTAssertEqual(found.first { $0["axis"] as? String == "right" }?["delta"] as? Double, 1)
    }

    func testSeparateOriginAndHeightRoundingCanReverseTopDespiteMonotonicRawEdges() {
        let rects = (0...1000).map { i -> [Double] in
            let p = Double(i) / 1000
            return [1425 - 206 * p, 874 - 522 * p, 250 + 204 * p, 48 + 520 * p]
        }
        let exact = rects.map { cg($0, primaryTop: 1117) }
        let independentlyRounded = rects.map { cg($0.map { $0.rounded() }, primaryTop: 1117) }
        XCTAssertTrue(reversals(exact, start: exact[0], target: exact.last!).isEmpty)
        XCTAssertTrue(reversals(independentlyRounded, start: exact[0], target: exact.last!).contains { $0["axis"] as? String == "top" })
        // A possible mechanism only: this does NOT establish AppKit's rounding algorithm.
    }

    func testProductionEdgesStayMonotonicThroughSetFrameInBothDirections() {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let hover = NSRect(x: 246, y: 874, width: 250, height: 48)
        let expanded = NSRect(x: 40, y: 352, width: 454, height: 568)
        let ball = NSRect(x: 448, y: 874, width: 48, height: 48)
        for (a, b) in [(hover, expanded), (expanded, ball), (ball, expanded), (expanded, hover)] {
            for mirror in [false, true] {
                func flipped(_ r: NSRect) -> NSRect { mirror ? NSRect(x: 1000 - r.maxX, y: r.minY, width: r.width, height: r.height) : r }
                let start = flipped(a), target = flipped(b)
                panel.setFrame(start, display: false)
                var completed = 0, rects = [cg(raw(panel.frame), primaryTop: 1117)]
                let animation = PanelFrameAnimation(window: panel, target: target, duration: 0.34) { completed += 1 }
                for i in 1...1000 {
                    animation.currentProgress = Float(i) / 1000
                    rects.append(cg(raw(panel.frame), primaryTop: 1117))
                }
                XCTAssertTrue(reversals(rects, start: rects.first!, target: rects.last!).isEmpty)
                XCTAssertEqual(panel.frame, target)
                XCTAssertEqual(completed, 1)
            }
        }
    }

    func testProductionTimingMatchesCAMediaEaseInEaseOut() {
        XCTAssertEqual(PanelFrameAnimation.easedProgress(0), 0)
        XCTAssertEqual(PanelFrameAnimation.easedProgress(0.25), 0.1291619, accuracy: 0.000001)
        XCTAssertEqual(PanelFrameAnimation.easedProgress(0.5), 0.5, accuracy: 0.000001)
        XCTAssertEqual(PanelFrameAnimation.easedProgress(0.75), 0.8708381, accuracy: 0.000001)
        XCTAssertEqual(PanelFrameAnimation.easedProgress(1), 1)
    }

    func testProductionImmediateAndCancelDoNotLeaveLateFrameWrites() {
        _ = NSApplication.shared
        let start = NSRect(x: 246, y: 874, width: 250, height: 48), target = NSRect(x: 40, y: 352, width: 454, height: 568)
        let panel = NSPanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var completed = 0
        let immediate = PanelFrameAnimation(window: panel, target: target, duration: 0) { completed += 1 }
        immediate.startMotion()
        XCTAssertEqual(panel.frame, target)
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(immediate.isAnimating)
        XCTAssertNil(immediate.displayLink, "Zero duration must not create a driver")
        panel.setFrame(start, display: false)
        let cancelled = PanelFrameAnimation(window: panel, target: target, duration: 0.28) { completed += 1 }
        cancelled.currentProgress = 0.5
        cancelled.cancel()
        let stopped = panel.frame
        cancelled.currentProgress = 1
        XCTAssertEqual(panel.frame, stopped)
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(cancelled.isAnimating)
    }

    func testNativeProductionEdgesAreMonotonic() async throws {
        try await nativeFrames()
    }

    private func nativeFrames() async throws {
        guard ProcessInfo.processInfo.environment["DOTIST_FRAME_QUANTIZATION_NATIVE"] == "1" else {
            throw XCTSkip("Opt in on host with DOTIST_FRAME_QUANTIZATION_NATIVE=1; geometry only")
        }
        var report: [String: Any] = ["status": "preflight", "mode": "production", "duration": 0.34, "timing": "easeInEaseOut",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "originalCGStart": [1425, 195, 250, 48], "originalCGTarget": [1219, 197, 454, 568],
            "originalPrimaryHeight": 1117, "originalScale": 2,
            "sampling": "2ms requested sleep; sequential NS-before/CG/NS-after reads; not compositor presentation timestamps",
            "interpretation": "CG bounds reversals alone do not prove visible jitter or AppKit rounding causality"]
        defer { do { try write(report, name: "production-native") } catch { XCTFail("Cannot write geometry evidence: \(error)") } }
        _ = NSApplication.shared
        report["appIsRunning"] = NSApp.isRunning
        guard let screen = NSScreen.screens.first else {
            report["status"] = "skipped-no-screen"
            throw XCTSkip("No screen here. Run the same test on the host; no window was created.")
        }
        let primaryTop = screen.frame.maxY
        report["screenNSFrame"] = raw(screen.frame)
        report["screenNSVisibleFrame"] = raw(screen.visibleFrame)
        report["screenScale"] = screen.backingScaleFactor
        report["screenMaximumFramesPerSecond"] = screen.maximumFramesPerSecond
        report["displayID"] = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        guard screen.backingScaleFactor == 2 else {
            report["status"] = "skipped-not-2x"
            throw XCTSkip("This regression requires a 2x primary screen; metadata recorded")
        }
        let x = screen.visibleFrame.minX + 40
        let start = NSRect(x: x + 206, y: primaryTop - 243, width: 250, height: 48)
        let target = NSRect(x: x, y: primaryTop - 765, width: 454, height: 568)
        guard screen.visibleFrame.contains(start), screen.visibleFrame.contains(target) else {
            report["status"] = "skipped-insufficient-visible-area"
            throw XCTSkip("Primary display cannot contain the translated original geometry")
        }
        let startCG = cg(raw(start), primaryTop: primaryTop), targetCG = cg(raw(target), primaryTop: primaryTop)
        report["startNS"] = raw(start); report["targetNS"] = raw(target)
        report["startCG"] = startCG; report["targetCG"] = targetCG
        report["primaryTopForCGConversion"] = primaryTop
        report["reduceMotionSetting"] = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let panel = NSPanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSView(frame: NSRect(origin: .zero, size: start.size))
        panel.backgroundColor = .windowBackgroundColor
        defer { panel.orderOut(nil); panel.close() }
        // No activate/makeKey/finishLaunching/app.run; only this blank panel is ordered.
        panel.orderFrontRegardless()
        report["windowID"] = panel.windowNumber
        report["windowScale"] = panel.backingScaleFactor
        report["isKeyWindow"] = panel.isKeyWindow
        var trials: [[String: Any]] = []
        for trial in 0..<3 {
            panel.setFrame(start, display: true)
            try await Task.sleep(for: .milliseconds(100))
            var rows: [[String: Any]] = [], cgRects: [[Double]] = [], nsRects: [[Double]] = []
            weak var sampledLink: CADisplayLink?
            let began = ProcessInfo.processInfo.systemUptime
            func sample() throws {
                let beforeTime = ProcessInfo.processInfo.systemUptime - began, before = raw(panel.frame)
                let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(panel.windowNumber)) as? [[String: Any]]
                let entry = try XCTUnwrap(list?.first { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == panel.windowNumber })
                XCTAssertEqual((entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, ProcessInfo.processInfo.processIdentifier)
                let bounds = try XCTUnwrap(entry[kCGWindowBounds as String] as? [String: Double])
                let rect = try ["X", "Y", "Width", "Height"].map { try XCTUnwrap(bounds[$0]) }
                let after = raw(panel.frame), afterTime = ProcessInfo.processInfo.systemUptime - began
                rows.append(["readBegin": beforeTime, "readEnd": afterTime, "nsBefore": before, "nsAfter": after,
                             "nsAsCG": cg(before, primaryTop: primaryTop), "cg": rect,
                             "displayLinkDuration": sampledLink.map { $0.duration as Any } ?? NSNull(),
                             "displayLinkTimestamp": sampledLink.map { $0.timestamp as Any } ?? NSNull(),
                             "displayLinkTargetTimestamp": sampledLink.map { $0.targetTimestamp as Any } ?? NSNull()])
                cgRects.append(rect); nsRects.append(cg(before, primaryTop: primaryTop))
            }
            try sample()
            var completed = false
            var completionAt: Double?
            let animation = PanelFrameAnimation(window: panel, target: target, duration: 0.34) {
                completed = true; completionAt = ProcessInfo.processInfo.systemUptime - began
            }
            defer { animation.cancel() }
            animation.startMotion()
            sampledLink = animation.displayLink
            let preferred = sampledLink?.preferredFrameRateRange
            XCTAssertNotNil(sampledLink, "Visible window must use its contentView display link")
            while ProcessInfo.processInfo.systemUptime - began < 0.65 {
                try await Task.sleep(for: .milliseconds(2))
                try sample()
            }
            let cgReverse = reversals(cgRects, start: startCG, target: targetCG)
            let nsReverse = reversals(nsRects, start: startCG, target: targetCG)
            let pairs = cgReverse.map { r in
                ["reversal": r, "beforeRaw": rows[r["beforeIndex"] as! Int], "afterRaw": rows[r["afterIndex"] as! Int]]
            }
            let valid = completed && panel.frame == target && cgRects.first! == startCG && cgRects.last! == targetCG
                && Set(cgRects.map { String(describing: $0) }).count > 5 && panel.backingScaleFactor == 2
                && preferred != nil && !animation.isAnimating && animation.displayLink == nil
            trials.append(["trial": trial, "rows": rows, "cgReversals": cgReverse, "nsReversals": nsReverse,
                           "cgReversalRawPairs": pairs, "completionObserved": completed, "validTrial": valid,
                           "completionAt": completionAt.map { $0 as Any } ?? NSNull(),
                           "distinctCGFrames": Set(cgRects.map { String(describing: $0) }).count,
                           "driver": preferred == nil ? "unexpected-fallback" : "content-view-display-link",
                           "preferredFrameRateRange": preferred.map { [$0.minimum, $0.maximum, $0.preferred] as Any } ?? NSNull(),
                           "driverReleasedAfterCompletion": !animation.isAnimating && animation.displayLink == nil])
            report["trials"] = trials
            report["status"] = cgReverse.isEmpty && nsReverse.isEmpty ? "observed-monotonic" : "observed-reversal"
            XCTAssertTrue(completed, "Animator completion missing: lifecycle/environment evidence, not a rounding diagnosis")
            XCTAssertEqual(panel.backingScaleFactor, 2)
            XCTAssertEqual(panel.frame, target, "Native animator endpoint; no fixture correction is applied")
            XCTAssertEqual(cgRects.first!, startCG)
            XCTAssertEqual(cgRects.last!, targetCG)
            XCTAssertGreaterThan(Set(cgRects.map { String(describing: $0) }).count, 5, "Require intermediate native frames; endpoint-only is inconclusive")
            XCTAssertNil(animation.displayLink)
            XCTAssertFalse(animation.isAnimating)
            XCTAssertTrue(nsReverse.isEmpty, "NS raw edge reversal: \(nsReverse)")
            XCTAssertTrue(cgReverse.isEmpty, "CG edge reversal; raw before/after pairs are in QUANTIZATION_JSON: \(cgReverse)")
        }
        report["status"] = trials.contains { $0["validTrial"] as? Bool != true } ? "inconclusive-invalid-trial"
            : (trials.contains { !($0["cgReversals"] as! [[String: Any]]).isEmpty || !($0["nsReversals"] as! [[String: Any]]).isEmpty }
               ? "observed-reversal" : "observed-monotonic")
        report["driverCleanup"] = try await verifyDisplayDriverCleanup(panel: panel, target: start)
    }

    private func verifyDisplayDriverCleanup(panel: NSPanel, target: NSRect) async throws -> [String: Bool] {
        var completions = 0
        let cancelled = PanelFrameAnimation(window: panel, target: target, duration: 0.34) { completions += 1 }
        cancelled.startMotion()
        let cancelledLink = try XCTUnwrap(cancelled.displayLink)
        cancelled.cancel()
        XCTAssertNil(cancelled.displayLink)
        XCTAssertFalse(cancelled.isAnimating)
        var released: PanelFrameAnimation? = PanelFrameAnimation(window: panel, target: target, duration: 0.34) { completions += 1 }
        released?.startMotion()
        let retainedLink = try XCTUnwrap(released?.displayLink)
        weak var weakAnimation = released
        released = nil
        XCTAssertNil(weakAnimation, "Retaining the link must not retain its animation through the target")
        let stopped = panel.frame
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(panel.frame, stopped)
        XCTAssertEqual(completions, 0)
        withExtendedLifetime((cancelledLink, retainedLink)) {}
        return ["cancelReleasedLink": cancelled.displayLink == nil, "cancelStopped": !cancelled.isAnimating,
                "deinitReleasedOwnerWithLinkRetained": weakAnimation == nil,
                "noLateFrameWrites": panel.frame == stopped, "noLateCompletion": completions == 0]
    }
}
