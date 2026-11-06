import AppKit
import CoreGraphics
import Darwin
import DotistCore
import QuartzCore
import Observation
import SwiftUI
import XCTest
@testable import DotistApp

/// Diagnostic evidence only. Nothing here is a production fix or a visual assertion.
/// Run one selected case, two round trips, six region captures; never capture a display.
@MainActor
final class GlassTransitionDesktopTests: XCTestCase {
    /// Human observation only. This entry never calls the capture fixture below.
    func testManualInsetABWithoutCapture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let selected = env["DOTIST_INSET_AB_VARIANT"] else { throw XCTSkip("Manual inset A/B opt-in only") }
        guard ["baseline", "continuous-inset", "production"].contains(selected) else { throw GTFailure("Unknown inset A/B variant") }
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Host screen required; no windows created") }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
              !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
              !GlassDebugState.shared.enabled else { throw XCTSkip("Requires normal accessibility/material mode; settings are never changed") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/glass-transition")
        let output = root.appendingPathComponent("inset-ab-runs/\(selected)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let top = screen.frame.maxY, x = screen.visibleFrame.minX + 40
        let expanded = NSRect(x: x, y: top - 765, width: 454, height: 568)
        let hover = NSRect(x: x + 206, y: top - 243, width: 250, height: 48)
        let area = expanded.union(hover).insetBy(dx: -24, dy: -24)
        guard screen.visibleFrame.contains(area) else { throw XCTSkip("Display cannot contain the translated original geometry") }
        let store = try TaskStore(databasePath: output.appendingPathComponent("data/tasks.sqlite").path)
        var settings = DotistSettingsPatch()
        settings.language = "en"; settings.theme = "light"; settings.allColor = DotistGroupColor.none.rawValue
        _ = try store.updateSettings(settings)
        _ = try store.addTask(title: "Synthetic inset A/B task")
        let model = try AppModel(store: store)
        let background = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let panel = DotistPanel(contentRect: expanded, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for w in [background, panel] {
            w.isReleasedWhenClosed = false; w.hidesOnDeactivate = false; w.ignoresMouseEvents = true
            w.appearance = NSAppearance(named: .aqua)
        }
        background.backgroundColor = .white; background.isOpaque = true; background.hasShadow = false
        panel.backgroundColor = .clear; panel.isOpaque = false
        var environment = PanelMotion.Environment()
        environment.pointerEventsEnabled = false
        environment.mouseLocation = { NSPoint(x: -10_000, y: -10_000) }
        environment.pressedMouseButtons = { 0 }; environment.visibleFrame = { _ in screen.visibleFrame }
        let motion = PanelMotion(model: model, panel: panel, size: expanded.size, title: { "Synthetic inset A/B" }, environment: environment)
        let observed = GTInsetABFrame(panel.frame)
        let observations = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak panel] _ in
                MainActor.assumeIsolated { if let panel { observed.frame = panel.frame } }
            }
        }
        let inset: (@MainActor (Bool, Bool) -> EdgeInsets)?
        if selected == "production" { inset = nil }
        else {
            inset = { compact, transitioning in
                GTInsetAB.insets(frame: observed.frame, target: expanded, compact: compact,
                                 transitioning: transitioning, continuous: selected == "continuous-inset")
            }
        }
        let state = TaskPanelState()
        let host = DotistHostingView(rootView: FloatingPanelView(model: model, motion: motion, colorState: state,
            title: "Synthetic inset A/B", remaining: 1, total: 1, groupName: nil, contextMenu: { _, _ in },
            content: VStack(alignment: .leading) { Text("Synthetic inset A/B").font(.title2); Spacer() }.padding(24))
            .environment(\.diagnosticSurfaceInset, inset))
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: expanded.size)
        host.autoresizingMask = [.width, .height]; panel.contentView = host
        defer {
            observations.forEach { NotificationCenter.default.removeObserver($0) }
            motion.stop(); panel.orderOut(nil); panel.contentView = nil; panel.close()
            background.orderOut(nil); background.close()
        }
        try gtJSON(["variant": selected, "capture": "none; human observation only", "database": model.databasePath,
                    "expandedNS": gtRect(expanded), "hoverNS": gtRect(hover), "translationX": x - 1219,
                    "screenScale": screen.backingScaleFactor, "reduceMotion": false,
                    "trigger": "programmatic stable-hover toggle; not real mouseUp", "rounds": 8], to: output.appendingPathComponent("run.json"))
        print("INSET_AB_OUTPUT=\(output.path) variant=\(selected); 8 rounds, Ctrl-C stops; no capture")
        motion.toggleBubble(in: screen.visibleFrame, animated: false)
        motion.bubbleOnRight = true // Keep the original right-facing scenario after translation to the left.
        background.orderFrontRegardless(); panel.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(600))
        for round in 1...8 {
            print("INSET_AB round=\(round) phase=hover")
            motion.setHover(true, in: screen.visibleFrame)
            panel.setFrame(hover, display: true)
            try await Task.sleep(for: .milliseconds(700))
            guard !motion.hoverAnimating, motion.hovering else { throw GTFailure("Stable hover did not finish; no fixture retry") }
            try await Task.sleep(for: .milliseconds(700))
            print("INSET_AB round=\(round) phase=expand")
            motion.toggleBubble(in: screen.visibleFrame)
            try await gtSettle(motion)
            guard panel.frame == expanded else { throw GTFailure("Unexpected expanded endpoint; no fixture retry") }
            try await Task.sleep(for: .milliseconds(1200))
            if round < 8 {
                motion.toggleBubble(in: screen.visibleFrame, animated: false)
                motion.bubbleOnRight = true
                try await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    func testCaptureGeometryAndIdentityGate() throws {
        let primary = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let area = NSRect(x: -800, y: 1100, width: 492, height: 750)
        XCTAssertEqual(CompactGlassDesktopEvidence.screenRect(area, primaryFrame: primary),
                       CGRect(x: -800, y: -868, width: 492, height: 750))
        let marker = GTBackdrop(frame: NSRect(x: 0, y: 0, width: 492, height: 750))
        for scale in [1, 2] {
            let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: 492 * scale, pixelsHigh: 750 * scale, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32))
            let bytes = try XCTUnwrap(image.bitmapData)
            bytes.initialize(repeating: 255, count: image.bytesPerRow * image.pixelsHigh)
            XCTAssertThrowsError(try marker.validate(image, scale: CGFloat(scale)))
            for (rect, white) in marker.cells {
                for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) {
                    for dy in 0..<scale { for dx in 0..<scale {
                        let i = ((749 - y) * scale + dy) * image.bytesPerRow + (x * scale + dx) * 4
                        for c in 0..<3 { bytes[i + c] = white ? 255 : 0 }
                    } }
                } }
            }
            try marker.validate(image, scale: CGFloat(scale))
            XCTAssertThrowsError(try marker.validate(image, scale: CGFloat(3 - scale)))
            let rect = marker.cells[0].0
            let i = Int((750 - rect.midY) * CGFloat(scale)) * image.bytesPerRow + Int(rect.midX) * scale * 4
            bytes[i] = 128 // An occluded identity sample must reject the capture.
            XCTAssertThrowsError(try marker.validate(image, scale: CGFloat(scale)))
        }
    }

    /// Pure evidence-gate coverage: no windows ordered, no WindowServer required.
    func testWindowGateTreatsAppKitOcclusionAsDiagnosticAndPreservesRejections() throws {
        let area = CGRect(x: 100, y: 200, width: 492, height: 750)
        var sample = GTWindowObservation(role: "background", required: true, windowID: 71,
            listIndex: 4, ownerPID: 123, layer: 3, bounds: area, expectedLayer: 3,
            frame: area, isVisible: true, isOnActiveSpace: true,
            occlusionState: NSWindow.OcclusionState.visible.rawValue, alpha: 1, windowServerAlpha: 1)
        XCTAssertTrue(sample.evaluate(backdropIndex: 4, expectedOwnerPID: 123, area: area).failures.isEmpty)
        sample.occlusionState = 8192 // Host observation: no documented visible bit.
        let advisory = sample.evaluate(backdropIndex: 4, expectedOwnerPID: 123, area: area)
        XCTAssertTrue(advisory.failures.isEmpty)
        XCTAssertEqual(advisory.facts["occlusionVisible"] as? Bool, false)
        XCTAssertEqual(advisory.facts["occlusionStateRawValue"] as? UInt, 8192)
        XCTAssertEqual(advisory.facts["occlusionVisibleIsHardGate"] as? Bool, false)
        XCTAssertNil((advisory.facts["checks"] as? [String: Bool])?["occlusionVisible"])
        // A false AppKit flag must not bypass even a single bad WS alpha.
        sample.windowServerAlpha = nil
        XCTAssertEqual(sample.evaluate(backdropIndex: 4, expectedOwnerPID: 123, area: area).failures,
                       ["background.windowServerAlphaOpaque"])
        sample.windowServerAlpha = 0.5
        XCTAssertEqual(sample.evaluate(backdropIndex: 4, expectedOwnerPID: 123, area: area).failures,
                       ["background.windowServerAlphaOpaque"])
        sample.listIndex = nil; sample.ownerPID = 456; sample.layer = 9
        sample.isVisible = false; sample.isOnActiveSpace = false; sample.occlusionState = 0; sample.alpha = 0.5
        let rejected = sample.evaluate(backdropIndex: 4, expectedOwnerPID: 123, area: area)
        XCTAssertEqual(Set(rejected.failures), Set([
            "background.listedOnScreen", "background.orderedRelativeToBackdrop", "background.ownerMatches",
            "background.layerMatches", "background.isVisible", "background.isOnActiveSpace",
            "background.alphaOpaque", "background.windowServerAlphaOpaque"
        ]))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: rejected.facts)) as? [String: Any])
        XCTAssertEqual(decoded["windowServerOwnerPID"] as? Int, 456)
        XCTAssertEqual(decoded["windowServerLayer"] as? Int, 9)
        XCTAssertEqual(decoded["expectedLayer"] as? Int, 3)
        XCTAssertEqual(decoded["windowServerAlpha"] as? Double, 0.5)
        XCTAssertEqual(decoded["occlusionVisible"] as? Bool, false)
        XCTAssertTrue(decoded["onScreenListIndex"] is NSNull)
        XCTAssertEqual(decoded["failures"] as? [String], rejected.failures)
        sample.role = "panel"; sample.required = false
        XCTAssertTrue(sample.evaluate(backdropIndex: 4, expectedOwnerPID: 123, area: area).failures.isEmpty,
                      "The intentionally unshown panel is reported, but not required for the blank background")
        sample.required = true; sample.listIndex = 4
        XCTAssertTrue(sample.evaluate(backdropIndex: 4, expectedOwnerPID: 123, area: area).failures.contains("panel.orderedRelativeToBackdrop"),
                      "A foreground panel must be strictly above its backdrop")
        sample.bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        XCTAssertTrue(sample.evaluate(backdropIndex: 4, expectedOwnerPID: 123, area: area).failures.contains("panel.boundsWithinBackdrop"))
    }

    func testSelectedDesktopTransition() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DOTIST_GLASS_TRANSITION_DESKTOP"] == "1" else {
            throw XCTSkip("Explicit host opt-in: DOTIST_GLASS_TRANSITION_DESKTOP=1")
        }
        let selected = env["DOTIST_GLASS_TRANSITION_CASE"] ?? "baseline"
        guard ["baseline", "no-shadow"].contains(selected) else { throw GTFailure("Unknown selected case: \(selected)") }
        if selected == "no-shadow" {
            throw XCTSkip("Historical no-shadow comparison disabled pending removal: its NSWindow animator differs from baseline's PanelFrameAnimation driver")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/glass-transition")
        let output = root.appendingPathComponent("runs/\(selected)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("GLASS_TRANSITION_OUTPUT=\(output.path)")
        var facts: [String: Any] = ["case": selected, "status": "preflight", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "sourceManifest": env["DOTIST_GLASS_SOURCE_MANIFEST"] ?? "unprovided; build provenance unverified",
            "installedApplicationVersion": "unknown; installed app neither inspected nor launched",
            "sampling": "display-link callbacks are observations, not guaranteed every presented compositor frame",
            "captureTiming": "sparse asynchronous screencapture intervals; not video or exact presentation timestamps",
            "cropCandidate": "omitted: exterior whole-host mask cannot isolate compact material and would also clip content/expanded glass",
            "activation": "nonactivating, never makeKey/activate, no global clicks",
            "backdrop": "white; 64pt minimum exterior; random identity bands",
            "content": "synthetic task + simple SwiftUI content inside full production FloatingPanelView",
            "occlusionPolicy": "AppKit occlusionState is diagnostic only in this XCTest fixture; WindowServer identity/geometry/alpha/order/occlusion and captured random pixel identity remain mandatory"]
        defer { try? gtJSON(facts, to: output.appendingPathComponent("run.json")) }
        _ = NSApplication.shared
        facts["applicationLifecycle"] = ["entry": "XCTest; fixture does not call NSApplication.run or finishLaunching",
                                         "appIsRunning": NSApp.isRunning]
        guard let screen = NSScreen.screens.first else {
            facts["status"] = "skipped-no-screen"
            throw XCTSkip("No screen in this execution context; run on the host. This says nothing about host WindowServer availability.")
        }
        guard CGPreflightScreenCaptureAccess() else {
            facts["status"] = "failed-no-screen-recording"
            throw GTFailure("Screen Recording unavailable in this process; no permission request was made")
        }
        let visible = screen.visibleFrame
        guard visible.width >= 492, visible.height >= 750 else { throw GTFailure("Selected display needs a 492x750pt controlled region") }
        let area = NSRect(x: min(visible.minX + 24, visible.maxX - 492), y: floor(visible.midY - 375), width: 492, height: 750)
        let frame = NSRect(x: area.minX + 64, y: area.minY + 64, width: 364, height: 620)
        let initialActive = NSApp.isActive
        let initialKey = NSApp.keyWindow?.windowNumber
        let initialFrontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        facts["initialFrontPID"] = initialFrontPID
        facts["area"] = gtRect(area)
        facts["screens"] = NSScreen.screens.map { s in
            ["frame": gtRect(s.frame), "visibleFrame": gtRect(s.visibleFrame), "scale": s.backingScaleFactor,
             "displayID": s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown"] as [String: Any]
        }
        facts["accessibility"] = gtAccessibility()
        if let path = env["DOTIST_GLASS_SOURCE_MANIFEST"] {
            facts["source"] = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        } else {
            throw GTFailure("Build provenance required: use .cache/glass-transition/run.sh build, then desktop")
        }
        guard !GlassDebugState.shared.enabled else { throw GTFailure("Glass debug must be disabled; fixture will not change it") }
        let database = output.appendingPathComponent("data/tasks.sqlite")
        let store = try TaskStore(databasePath: database.path)
        var settings = DotistSettingsPatch()
        settings.language = "en"; settings.theme = "light"; settings.hoverExpand = false
        settings.allColor = DotistGroupColor.none.rawValue
        _ = try store.updateSettings(settings)
        _ = try store.addTask(title: "Synthetic glass transition fixture")
        let model = try AppModel(store: store)
        facts["settings"] = ["theme": model.settings.theme, "opacity": model.settings.opacity,
                              "frost": model.settings.frost, "tint": model.settings.allColor,
                              "hoverExpand": model.settings.hoverExpand]
        let background = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let panel = DotistPanel(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        for w in [background, panel] {
            w.isReleasedWhenClosed = false
            CompactGlassDesktopEvidence.configure(w, frame: w === background ? area : frame)
            w.appearance = NSAppearance(named: .aqua)
        }
        background.hasShadow = false; background.isOpaque = true; background.backgroundColor = .white
        let marker = GTBackdrop(frame: NSRect(origin: .zero, size: area.size))
        background.contentView = marker
        panel.isOpaque = false; panel.backgroundColor = .clear
        var environment = PanelMotion.Environment()
        // Only desktop input is isolated; baseline retains animateFrame=nil and
        // the production duration closure (including actual Reduce Motion).
        environment.pointerEventsEnabled = false
        environment.mouseLocation = { NSPoint(x: area.minX - 100, y: area.minY - 100) }
        environment.pressedMouseButtons = { 0 }
        environment.visibleFrame = { _ in visible }
        if selected == "no-shadow" {
            // DotistPanel is final. Use the existing test injection seam solely
            // to reset hasShadow at handoff, before any animator commit. The
            // native animator/easing/duration/completion dispatch match production.
            environment.animateFrame = { window, target, duration, completion in
                window.hasShadow = false
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(target, display: true)
                } completionHandler: {
                    DispatchQueue.main.async { completion() }
                }
            }
        }
        let motion = PanelMotion(model: model, panel: panel, size: frame.size, title: { model.bubbleTitle }, environment: environment)
        facts["requestedDurationSeconds"] = ["collapse": environment.frameAnimationDuration(true),
                                               "expand": environment.frameAnimationDuration(false)]
        if selected == "no-shadow" { panel.hasShadow = false }
        let state = TaskPanelState()
        let host = DotistHostingView(rootView: FloatingPanelView(model: model, motion: motion, colorState: state,
            title: model.bubbleTitle, remaining: model.remainingCount, total: model.topLevelTasks.count,
            groupName: nil, contextMenu: { _, _ in }, content:
                VStack(alignment: .leading, spacing: 16) {
                    Text("Synthetic fixture").font(.title2)
                    Text("Synthetic glass transition fixture")
                    Spacer()
                }.padding(24)))
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        let container = NSView(frame: host.frame)
        container.addSubview(host); panel.contentView = container
        panel.setFrame(frame, display: true)
        let recorder = GTRecorder(motion: motion, panel: panel, host: host, container: container)
        defer {
            recorder.stop(); motion.stop()
            panel.orderOut(nil); panel.contentView = nil; panel.close()
            background.orderOut(nil); background.close()
            facts["cleanup"] = ["panelVisible": panel.isVisible, "backgroundVisible": background.isVisible,
                                "appActive": NSApp.isActive, "keyWindowID": NSApp.keyWindow?.windowNumber ?? -1]
            try? gtJSON(recorder.rows, to: output.appendingPathComponent("frames.json"))
        }
        do {
            let capture = GTCapture(background: background, panel: panel, marker: marker, screen: screen,
                                    output: output, initialActive: initialActive, initialKey: initialKey, initialFrontPID: initialFrontPID)
            background.orderFrontRegardless()
            try await capture.waitUntilReady("00-background", foreground: false)
            try await capture.take("00-background", foreground: false, recorder: recorder)
            panel.orderFrontRegardless()
            try await capture.waitUntilReady("foreground", foreground: true)
            // Material warmup is separate from readiness; no polling is added
            // to the timing-only native animator pass.
            try await Task.sleep(for: .milliseconds(600))
            try capture.check(foreground: true, phase: "foreground-after-warmup")
            recorder.start(on: host)
            facts["appearance"] = panel.effectiveAppearance.name.rawValue
            facts["backingScale"] = panel.backingScaleFactor
            facts["identityBits"] = marker.cells.map { $0.1 ? 1 : 0 }
            facts["animator"] = selected == "baseline" ? "production animateFrame=nil" : "test seam: native AppKit animator + hasShadow=false at handoff"
            // Pass 1: timing only. No subprocess, image encode, or window-list
            // enumeration within these two real transitions.
            recorder.phase = "timing-only"
            for direction in ["collapse", "expand"] {
                recorder.direction = direction; recorder.sample("before-toggle")
                motion.toggleBubble(in: visible, animated: true)
                recorder.sample("after-toggle")
                try await gtSettle(motion)
                recorder.sample("settled")
            }
            // Pass 2: sparse evidence. One mid-animation capture per direction;
            // process latency is explicitly bracketed rather than hidden.
            recorder.phase = "sparse-captures"
            try await capture.take("01-expanded-start", recorder: recorder)
            for (index, direction) in ["collapse", "expand"].enumerated() {
                recorder.direction = direction; recorder.sample("before-toggle")
                motion.toggleBubble(in: visible, animated: true)
                recorder.sample("after-toggle")
                try await Task.sleep(for: .milliseconds(110))
                try await capture.take("0\(index * 2 + 2)-\(direction)-requested-110ms", recorder: recorder)
                try await gtSettle(motion)
                try await capture.take("0\(index * 2 + 3)-\(direction)-settled", recorder: recorder)
            }
            try capture.check(foreground: true)
            guard recorder.rows.contains(where: { ($0["event"] as? String) == "display-link" }) else {
                throw GTFailure("No display-link samples; cannot claim timing evidence")
            }
            if selected == "no-shadow" {
                guard recorder.rows.allSatisfy({ ($0["hasShadow"] as? Bool) == false }) else { throw GTFailure("no-shadow invariant failed") }
            }
            facts["status"] = "captured-awaiting-human-review"
        } catch {
            facts["status"] = "failed"; facts["error"] = String(describing: error)
            facts["windowCheckDiagnostics"] = "window-check-failure.json (if a window gate failed); *.readiness.json; *.capture.json"
            // Persist/print the fixture error independently of XCTest's error
            // bridging; a runner deinit error is not evidence of a production bug.
            try? gtJSON(facts, to: output.appendingPathComponent("run.json"))
            print("GLASS_TRANSITION_FAILURE=\(error)")
            XCTFail("Fixture diagnostic failed: \(error); output=\(output.path)")
        }
    }
}

/// Only window notifications update this value, including origin-only steps.
@Observable @MainActor private final class GTInsetABFrame {
    var frame: NSRect
    init(_ frame: NSRect) { self.frame = frame }
}
/// Historical A/B: baseline remains the OLD discrete inset; B is the narrow
/// right/top diagnostic formula. "production" injects neither override.
@MainActor enum GTInsetAB {
    static func insets(frame: NSRect, target: NSRect, compact: Bool, transitioning: Bool, continuous: Bool) -> EdgeInsets {
        let normal = FloatingSurface.opticalInsets(compact: compact, reduceTransparency: false, increasedContrast: false)
        guard continuous, !compact, transitioning else { return normal }
        let x = min(2, max(0, frame.maxX - target.maxX)), y = min(2, max(0, frame.maxY - target.maxY))
        return EdgeInsets(top: y, leading: x, bottom: y, trailing: x)
    }
    static func bounds(frame: NSRect, inset: EdgeInsets) -> NSRect {
        NSRect(x: frame.minX + inset.leading, y: frame.minY + inset.bottom,
               width: frame.width - inset.leading - inset.trailing, height: frame.height - inset.top - inset.bottom)
    }
}

private struct GTFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
private func gtRect(_ r: CGRect) -> [String: Double] {
    ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
}
private func gtJSON(_ value: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
}
@MainActor private func gtAccessibility() -> [String: Bool] {
    let workspace = NSWorkspace.shared
    return ["reduceMotion": workspace.accessibilityDisplayShouldReduceMotion,
            "reduceTransparency": workspace.accessibilityDisplayShouldReduceTransparency,
            "increaseContrast": workspace.accessibilityDisplayShouldIncreaseContrast]
}
@MainActor private func gtSettle(_ motion: PanelMotion) async throws {
    let deadline = CACurrentMediaTime() + 2
    while motion.animationInProgress && CACurrentMediaTime() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard !motion.animationInProgress else { throw GTFailure("AppKit transition completion timed out") }
    // Includes a compositor turn and the production 0.45s shadow refresh tail.
    try await Task.sleep(for: .milliseconds(550))
}

@MainActor private final class GTRecorder: NSObject {
    let motion: PanelMotion
    let panel: NSWindow
    let host: NSView
    let container: NSView
    let origin = CACurrentMediaTime()
    var phase = "setup", direction = "expanded"
    var rows: [[String: Any]] = []
    var link: CADisplayLink?
    init(motion: PanelMotion, panel: NSWindow, host: NSView, container: NSView) {
        self.motion = motion; self.panel = panel; self.host = host; self.container = container
    }
    func start(on view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        self.link = link; link.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    @objc func tick(_ link: CADisplayLink) {
        sample("display-link", timestamp: link.timestamp, target: link.targetTimestamp)
    }
    func sample(_ event: String, timestamp: Double = 0, target: Double = 0) {
        rows.append(["t": CACurrentMediaTime() - origin, "monotonic": CACurrentMediaTime(),
                     "displayTimestamp": timestamp, "targetTimestamp": target,
                     "event": event, "phase": phase, "direction": direction,
                     "frame": gtRect(panel.frame), "hostBounds": gtRect(host.bounds),
                     "containerBounds": gtRect(container.bounds), "bubble": motion.bubble,
                     "animationInProgress": motion.animationInProgress, "hovering": motion.hovering,
                     "onRight": motion.bubbleOnRight, "hasShadow": panel.hasShadow,
                     "key": panel.isKeyWindow, "active": NSApp.isActive,
                     "scale": panel.backingScaleFactor, "appearance": panel.effectiveAppearance.name.rawValue,
                     "accessibility": gtAccessibility()])
    }
}

@MainActor private final class GTBackdrop: NSView {
    // 32 random bits, repeated in two bands outside every possible panel frame.
    let token = UUID()
    var cells: [(NSRect, Bool)] {
        var uuid = token.uuid
        let bytes = withUnsafeBytes(of: &uuid) { Array($0) }
        return (0..<72).map { index in
            let column = index % 36
            let bit = max(0, column - 2)
            let white = column < 2 || column >= 34 ? column.isMultiple(of: 2) : (bytes[bit / 8] & (1 << (bit % 8))) != 0
            return (NSRect(x: CGFloat(24 + column * 8), y: index < 36 ? 12 : bounds.height - 20, width: 8, height: 8), white)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        for (rect, white) in cells { (white ? NSColor.white : NSColor.black).setFill(); rect.fill() }
    }
    func validate(_ image: NSBitmapImageRep, scale: CGFloat) throws {
        guard image.pixelsWide == Int(bounds.width * scale), image.pixelsHigh == Int(bounds.height * scale) else {
            throw GTFailure("Wrong region dimensions or backing scale")
        }
        for (rect, white) in cells {
            guard let color = image.colorAt(x: Int(rect.midX * scale), y: Int((bounds.height - rect.midY) * scale))?.usingColorSpace(.sRGB),
                  color.alphaComponent > 0.98,
                  [color.redComponent, color.greenComponent, color.blueComponent].allSatisfy({ white ? $0 > 0.88 : $0 < 0.12 }) else {
                throw GTFailure("Identity mismatch: wrong region, stale capture, or occlusion")
            }
        }
    }
}

/// Only observations of the fixture's own windows are serialized. Keeping this
/// evaluation pure also lets offscreen tests exercise rejection evidence.
private struct GTWindowObservation {
    var role: String
    var required: Bool
    var windowID: Int
    var listIndex: Int?
    var ownerPID: Int?
    var layer: Int?
    var bounds: CGRect?
    var expectedLayer: Int
    var frame: CGRect
    var isVisible: Bool
    var isOnActiveSpace: Bool
    var occlusionState: UInt
    var alpha: Double
    var windowServerAlpha: Double?

    func evaluate(backdropIndex: Int?, expectedOwnerPID: Int, area: CGRect) -> (facts: [String: Any], failures: [String]) {
        let checks: [String: Bool] = [
            "listedOnScreen": listIndex != nil,
            "orderedRelativeToBackdrop": listIndex.map { index in
                backdropIndex.map { role == "background" ? index == $0 : index < $0 } ?? false
            } ?? false,
            "ownerMatches": ownerPID == expectedOwnerPID,
            "layerMatches": layer == expectedLayer,
            "isVisible": isVisible, "isOnActiveSpace": isOnActiveSpace,
            "alphaOpaque": alpha == 1, "windowServerAlphaOpaque": windowServerAlpha == 1,
            // Native animation can make presentation/model bounds differ;
            // containment remains mandatory throughout the animation.
            "boundsWithinBackdrop": bounds.map { area.contains($0) } ?? false,
            "backdropBoundsMatch": role != "background" || bounds == area
        ]
        // XCTest does not enter production's NSApplication.run lifecycle. The
        // host has reported this AppKit bit false while WS identity, geometry,
        // alpha and full-region no-occluder checks pass. It may be stale; that
        // cause is unproven. Even true means only partial visibility per SDK.
        // Keep the raw bit advisory; take() still requires captured nonce pixels
        // as well as all WS gates before accepting any compositor evidence.
        let occlusionVisible = occlusionState & NSWindow.OcclusionState.visible.rawValue != 0
        let failed = required ? checks.keys.filter { checks[$0] == false }.sorted().map { "\(role).\($0)" } : []
        let facts: [String: Any] = [
            "role": role, "required": required, "windowID": windowID,
            "onScreenListIndex": listIndex.map { $0 as Any } ?? NSNull(),
            "windowServerOwnerPID": ownerPID.map { $0 as Any } ?? NSNull(), "expectedOwnerPID": expectedOwnerPID,
            "windowServerLayer": layer.map { $0 as Any } ?? NSNull(), "expectedLayer": expectedLayer,
            "windowServerBounds": bounds.map { gtRect($0) as Any } ?? NSNull(), "windowFrame": gtRect(frame),
            "isVisible": isVisible, "isOnActiveSpace": isOnActiveSpace,
            "occlusionStateRawValue": occlusionState,
            "occlusionVisible": occlusionVisible, "occlusionVisibleIsHardGate": false,
            "diagnosticNotes": required && !occlusionVisible ? ["AppKit occlusion visible bit is false; WS gates and captured pixel identity must independently pass"] : [],
            "alpha": alpha, "windowServerAlpha": windowServerAlpha.map { $0 as Any } ?? NSNull(),
            "checks": checks, "failures": failed
        ]
        return (facts, failed)
    }
}

@MainActor private final class GTCapture {
    let background: NSWindow, panel: NSWindow, marker: GTBackdrop, screen: NSScreen, output: URL
    let initialActive: Bool, initialKey: Int?, initialFrontPID: pid_t?
    private(set) var lastCheck: [String: Any] = [:]
    init(background: NSWindow, panel: NSWindow, marker: GTBackdrop, screen: NSScreen, output: URL,
         initialActive: Bool, initialKey: Int?, initialFrontPID: pid_t?) {
        self.background = background; self.panel = panel; self.marker = marker; self.screen = screen; self.output = output
        self.initialActive = initialActive; self.initialKey = initialKey; self.initialFrontPID = initialFrontPID
    }
    @discardableResult func check(foreground: Bool, phase: String = "final") throws -> [String: Any] {
        let primary = NSScreen.screens.first
        let copiedList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        let list = copiedList ?? []
        func id(_ item: [String: Any]) -> Int { (item[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1 }
        func rect(_ item: [String: Any]) -> CGRect? {
            (item[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        }
        let area = primary.map { CompactGlassDesktopEvidence.screenRect(background.frame, primaryFrame: $0.frame) } ?? .null
        let back = list.firstIndex(where: { id($0) == background.windowNumber })
        let front = list.firstIndex(where: { id($0) == panel.windowNumber })
        let activationChecks: [String: Bool] = [
            "appActiveUnchanged": NSApp.isActive == initialActive,
            "keyWindowUnchanged": NSApp.keyWindow?.windowNumber == initialKey,
            "frontmostPIDUnchanged": NSWorkspace.shared.frontmostApplication?.processIdentifier == initialFrontPID
        ]
        var checks = activationChecks
        checks["primaryScreenAvailable"] = primary != nil
        checks["windowListAvailable"] = copiedList != nil
        checks["screenContainsBackdrop"] = screen.frame.contains(background.frame)
        checks["blankForegroundAbsent"] = foreground || (!panel.isVisible && front == nil)
        var failures = checks.keys.filter { checks[$0] == false }.sorted().map { "global.\($0)" }
        var windows: [[String: Any]] = []
        for (window, role, required) in [(background, "background", true), (panel, "panel", foreground)] {
            let index = list.firstIndex(where: { id($0) == window.windowNumber })
            // If absent onscreen, query this one ID only to distinguish an
            // existing offscreen fixture from missing WindowServer registration.
            let included = index == nil && window.windowNumber > 0
                ? (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]]) : nil
            let entry = index.map { list[$0] } ?? included?.first(where: { id($0) == window.windowNumber })
            let sample = GTWindowObservation(role: role, required: required, windowID: window.windowNumber,
                listIndex: index, ownerPID: (entry?[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                layer: (entry?[kCGWindowLayer as String] as? NSNumber)?.intValue, bounds: entry.flatMap(rect),
                expectedLayer: window.level.rawValue, frame: window.frame, isVisible: window.isVisible,
                isOnActiveSpace: window.isOnActiveSpace, occlusionState: window.occlusionState.rawValue, alpha: window.alphaValue,
                windowServerAlpha: (entry?[kCGWindowAlpha as String] as? NSNumber)?.doubleValue)
            let result = sample.evaluate(backdropIndex: back, expectedOwnerPID: Int(ProcessInfo.processInfo.processIdentifier), area: area)
            var detail = result.facts
            detail["entrySource"] = index != nil ? "onScreenList" : (entry != nil ? "includingOwnWindowOnly" : "missing")
            detail["key"] = window.isKeyWindow
            detail["hidesOnDeactivate"] = window.hidesOnDeactivate
            detail["collectionBehavior"] = window.collectionBehavior.rawValue
            windows.append(detail); failures.append(contentsOf: result.failures)
        }
        let blockerCount = back.map { index in list[..<index].filter {
            id($0) != panel.windowNumber && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 && (rect($0)?.intersects(area) ?? true)
        }.count }
        if let blockerCount, blockerCount > 0 { failures.append("global.noOccludingWindows") }
        var report: [String: Any] = [
            "phase": phase, "monotonic": CACurrentMediaTime(), "foreground": foreground,
            "status": failures.isEmpty ? "ready" : "rejected", "failures": failures, "globalChecks": checks,
            "windows": windows, "backdropOnScreenListIndex": back.map { $0 as Any } ?? NSNull(),
            "occludingWindowCount": blockerCount.map { $0 as Any } ?? NSNull(),
            "thirdPartyWindowDetails": "omitted", "appActive": NSApp.isActive, "appIsRunning": NSApp.isRunning,
            "expectedAppActive": initialActive, "keyWindowID": NSApp.keyWindow?.windowNumber ?? -1,
            "expectedKeyWindowID": initialKey ?? -1,
            "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            "expectedFrontmostPID": initialFrontPID ?? -1
        ]
        // CGRect.null contains infinities, which JSON cannot represent.
        if primary != nil { report["screenRect"] = gtRect(area) }
        lastCheck = report
        if !failures.isEmpty {
            let path = output.appendingPathComponent("window-check-failure.json")
            try gtJSON(report, to: path)
            throw GTFailure("Window gate failed [\(failures.joined(separator: ", "))]; evidence=\(path.path)")
        }
        return report
    }

    func waitUntilReady(_ name: String, foreground: Bool) async throws {
        let started = CACurrentMediaTime()
        let path = output.appendingPathComponent(name + ".readiness.json")
        var attempts: [[String: Any]] = []
        var consecutiveReady = 0
        var status = "failed"
        defer {
            try? gtJSON(["status": status, "started": started, "ended": CACurrentMediaTime(),
                         "timeoutSeconds": 1.5, "pollMilliseconds": 50, "requiredConsecutiveReady": 2,
                         "attempts": attempts], to: path)
        }
        // Match the existing desktop evidence helper's explicit layout/display/
        // flush, then await AppKit/WindowServer agreement instead of assuming a
        // fixed delay implies readiness. Never activate, send events, or reorder
        // other applications. Timing-only animations do not enter this loop.
        for window in foreground ? [background, panel] : [background] {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        CATransaction.flush()
        for attempt in 0..<31 {
            do {
                try check(foreground: foreground, phase: "\(name)/readiness-\(attempt)")
                consecutiveReady += 1
            } catch {
                consecutiveReady = 0
            }
            attempts.append(lastCheck)
            if consecutiveReady == 2 { status = "ready"; return }
            if CACurrentMediaTime() - started >= 1.5 || attempt == 30 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let failed = lastCheck["failures"] as? [String] ?? ["diagnostic-unavailable"]
        throw GTFailure("Readiness timed out for \(name); failed=[\(failed.joined(separator: ", "))]; evidence=\(path.path)")
    }
    func take(_ name: String, foreground: Bool = true, recorder: GTRecorder) async throws {
        let png = output.appendingPathComponent(name + ".png")
        var info: [String: Any] = ["status": "unverified", "start": CACurrentMediaTime(), "foreground": foreground]
        defer { try? gtJSON(info, to: output.appendingPathComponent(name + ".capture.json")) }
        do {
            info["beforeWindowServer"] = try check(foreground: foreground, phase: "\(name)/preCapture")
            let primary = try XCTUnwrap(NSScreen.screens.first)
            let area = CompactGlassDesktopEvidence.screenRect(background.frame, primaryFrame: primary.frame)
            info["screenRect"] = gtRect(area); info["panelID"] = panel.windowNumber; info["backdropID"] = background.windowNumber
            info["beforeFrame"] = gtRect(panel.frame); info["animationBefore"] = recorder.motion.animationInProgress
            recorder.sample("capture-start:\(name)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-R\(Int(area.minX)),\(Int(area.minY)),\(Int(area.width)),\(Int(area.height))", png.path]
            let deadline = CACurrentMediaTime() + 3
            var captureFailure: Error?
            let monitor = Timer(timeInterval: 0.02, repeats: true) { _ in
                MainActor.assumeIsolated {
                    do {
                        if CACurrentMediaTime() > deadline { throw GTFailure("screencapture exceeded 3 seconds") }
                        if captureFailure == nil {
                            try self.check(foreground: foreground, phase: "\(name)/captureMonitor")
                        }
                    } catch {
                        if captureFailure == nil { captureFailure = error }
                        if process.isRunning {
                            if CACurrentMediaTime() > deadline + 0.3 {
                                _ = kill(process.processIdentifier, SIGKILL) // This fixture's child only.
                            } else { process.terminate() }
                        }
                    }
                }
            }
            RunLoop.main.add(monitor, forMode: .common)
            defer { monitor.invalidate() }
            // Never block the main actor while AppKit is animating. Bound a
            // stuck tool to 3 seconds; no process is started per display tick.
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { child in continuation.resume(returning: child.terminationStatus) }
                do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
            }
            recorder.sample("capture-end:\(name)")
            info["end"] = CACurrentMediaTime(); info["afterFrame"] = gtRect(panel.frame)
            info["animationAfter"] = recorder.motion.animationInProgress
            if let captureFailure { throw captureFailure }
            guard status == 0 else { throw GTFailure("screencapture exited \(status)") }
            info["afterWindowServer"] = try check(foreground: foreground, phase: "\(name)/postCapture")
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: png)))
            try marker.validate(bitmap, scale: screen.backingScaleFactor)
            info["status"] = "verified-region-awaiting-visual-review"
        } catch {
            // Never retain a possibly unrelated/occluded desktop image.
            try? FileManager.default.removeItem(at: png)
            info["status"] = "rejected"; info["error"] = String(describing: error)
            info["lastWindowCheck"] = lastCheck
            throw error
        }
    }
}
