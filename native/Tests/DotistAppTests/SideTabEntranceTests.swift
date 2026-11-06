import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class SideTabEntranceTests: XCTestCase {
    func testCurrentCollapsedEarHasWiderActualRenderedGeometry() throws {
        let sample = try XCTUnwrap(SideTabsSnapshot.render(names: ["All", "Work"], language: "en",
            scheme: .light, inward: false, expanded: false, showLabels: false))
        XCTAssertEqual(sample.tabs[0].width, 15)
        XCTAssertEqual(sample.tabs[1].width, 10)
    }

    func testNeutralCurrentEarHasVisiblePixelContrastInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let sample = try XCTUnwrap(SideTabsSnapshot.render(names: ["Same", "Same"], language: "en",
                scheme: scheme, inward: false, expanded: false, showLabels: false, opacity: 100, color: { _ in .none }))
            let bitmap = NSBitmapImageRep(cgImage: sample.image)
            let colors = try sample.tabs.map { rect in
                try XCTUnwrap(bitmap.colorAt(x: Int(rect.midX), y: Int(rect.midY))?.usingColorSpace(.deviceRGB))
            }
            XCTAssertGreaterThan(abs(colors[0].redComponent - colors[1].redComponent), 0.08)
        }
    }

    func testHiddenRowsHaveNoNativeCaptureSurface() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/side-tabs-entrance/hidden-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let panel = DotistPanel(contentRect: CGRect(x: 500, y: 100, width: 364, height: 620),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" })
        let controller = SideTabsController(parent: panel, model: model, state: TaskPanelState(), motion: motion)
        defer { controller.stop(); motion.stop(); panel.close() }
        let child = try XCTUnwrap(panel.childWindows?.first)
        let content = try XCTUnwrap(child.contentView)
        try await Task.sleep(for: .milliseconds(60))
        content.layoutSubtreeIfNeeded()
        let screen = CGPoint(x: child.frame.midX, y: child.frame.maxY - 17)
        let local = child.convertPoint(fromScreen: screen)
        XCTAssertNil(content.hitTest(content.superview?.convert(local, from: nil) ?? local))
        XCTAssertTrue(child.ignoresMouseEvents)
    }
}

@MainActor
final class SideTabEntranceSamplingTests: XCTestCase {
    private var evidence: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/side-tabs-entrance/frames")
    }

    func testOneSeveralAndOneHundredRowsUseOrderedCurvedSamplesWithBoundedCompletion() throws {
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        var records = ["count,time,row,progress,width,pixelAlpha"]
        for count in [1, 3, 100] {
            let ids = (0..<count).map(String.init)
            var entrance = SideTabEntrance()
            entrance.update(ids: ids, visible: true, at: 10, reduceMotion: false)
            let initial = entrance.values(ids: ids, at: 10)
            XCTAssertTrue(initial.allSatisfy { $0 == 0 }, "Opening must begin with no painted rows")
            let interval = min(0.035, 0.28 / Double(max(1, count - 1)))
            for step in 0...56 {
                let elapsed = Double(step) / 120
                // Sampling/update on every display tick must not reset the origin.
                entrance.update(ids: ids, visible: true, at: 10 + elapsed, reduceMotion: false)
                let values = entrance.values(ids: ids, at: 10 + elapsed)
                let image = try XCTUnwrap(SideTabsSnapshot.render(names: ids, language: "en", scheme: .light,
                    inward: false, expanded: false, showLabels: false, entrance: values))
                let bitmap = NSBitmapImageRep(cgImage: image.image)
                for (index, rect) in image.tabs.enumerated() {
                    let t = min(1, max(0, (elapsed - Double(index) * interval) / 0.18))
                    let expected = CGFloat(UnitCurve.easeOut.value(at: t))
                    XCTAssertEqual(values[index], expected, accuracy: 0.000001)
                    if index > 0 { XCTAssertGreaterThanOrEqual(values[index - 1], values[index]) }
                    XCTAssertEqual(rect.width, (index == 0 ? 15 : 10) - 8 * (1 - expected), accuracy: 0.000001)
                    let alpha = bitmap.colorAt(x: Int(rect.midX), y: Int(rect.midY))?.alphaComponent ?? 0
                    XCTAssertEqual(alpha, 0.85 * expected, accuracy: 0.018,
                        "Actual row pixels must follow its own sample, including completely absent delayed rows")
                    records.append("\(count),\(elapsed),\(index),\(values[index]),\(rect.width),\(alpha)")
                }
                if count == 3 && step.isMultiple(of: 4) {
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: evidence.appendingPathComponent("entrance-\(step)-120s.png"))
                }
            }
            XCTAssertTrue(entrance.values(ids: ids, at: 10.461).allSatisfy { $0 == 1 }, "Even 100 rows finish within 460ms")
            if count == 3 {
                XCTAssertGreaterThan(entrance.values(ids: ids, at: 10.09)[0], 0.5, "Ease-out must exceed linear progress halfway")
            }
        }
        try records.joined(separator: "\n").write(to: evidence.appendingPathComponent("samples.csv"), atomically: true, encoding: .utf8)
    }

    func testRapidReverseRetargetsEachIDWithoutJumpOrRecurringDelay() throws {
        let ids = ["all", "work", "life"]
        var entrance = SideTabEntrance()
        entrance.update(ids: ids, visible: true, at: 0, reduceMotion: false)
        let before = entrance.values(ids: ids, at: 0.06)
        entrance.update(ids: ids, visible: false, at: 0.06, reduceMotion: false)
        XCTAssertEqual(entrance.values(ids: ids, at: 0.06), before)
        let retracting = entrance.values(ids: ids, at: 0.08)
        XCTAssertLessThan(retracting[0], before[0])
        entrance.update(ids: ids, visible: true, at: 0.08, reduceMotion: false)
        XCTAssertEqual(entrance.values(ids: ids, at: 0.08), retracting)
        XCTAssertGreaterThan(entrance.values(ids: ids, at: 0.081)[1], retracting[1], "Already visible rows resume immediately")
        for step in 1...40 {
            entrance.update(ids: ids, visible: true, at: 0.08 + Double(step) / 120, reduceMotion: false)
        }
        XCTAssertEqual(entrance.values(ids: ids, at: 0.5), [1, 1, 1])
        entrance.update(ids: ids.reversed(), visible: true, at: 0.5, reduceMotion: false)
        XCTAssertEqual(entrance.values(ids: ids.reversed(), at: 0.5), [1, 1, 1], "Reorder retains ID tracks")
        entrance.update(ids: ids + ["new"], visible: true, at: 0.51, reduceMotion: true)
        XCTAssertEqual(entrance.values(ids: ids + ["new"], at: 0.51), [1, 1, 1, 1])
        entrance.update(ids: ids, visible: false, at: 0.51, reduceMotion: true)
        XCTAssertEqual(entrance.values(ids: ids, at: 0.51), [0, 0, 0])
    }

    func testMovingPanelsAtBothScreenEdgesUseTheSameClampedGeometry() {
        var entrance = SideTabEntrance()
        let ids = ["all", "work", "life"]
        entrance.update(ids: ids, visible: true, at: 0, reduceMotion: false)
        for step in 0...60 {
            let t = Double(step) / 120
            let values = entrance.values(ids: ids, at: t)
            for x: CGFloat in [-1000, -997, -930, 400, 636] {
                let panel = CGRect(x: x, y: 100 + CGFloat(step), width: 364, height: 620 - CGFloat(step))
                let inward = x < -850
                let sample = SideTabGeometry.snapshot(panel: panel, fullWidths: [100, 80, 120], progress: 0.3,
                    inward: inward, visibleMinX: -1000, selectedIndex: 1, entrance: values)
                XCTAssertGreaterThanOrEqual(sample.window.minX, -1000)
                XCTAssertLessThanOrEqual(sample.window.maxX, 1000)
                for (index, rect) in sample.tabs.enumerated() {
                    XCTAssertTrue(sample.window.insetBy(dx: -0.000001, dy: -0.000001).contains(rect))
                    XCTAssertEqual(rect.maxY, panel.maxY - 40 - CGFloat(index) * 40)
                    XCTAssertEqual(inward ? rect.minX : rect.maxX,
                        inward ? max(panel.minX - 10, -1000) : panel.minX, accuracy: 0.000001)
                    XCTAssertEqual(sample.opacities[index], Double(values[index]))
                }
            }
        }
    }

    func testSelectedPixelDistinctionAndSolidAccessibilityFallbackAcrossThemes() throws {
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            for inward in [false, true] {
                for color in DotistGroupColor.allCases {
                    for protection in 0...2 {
                        let image = try XCTUnwrap(SideTabsSnapshot.render(names: ["All", "Work", "Life"], language: "en",
                            scheme: scheme, inward: inward, expanded: false, showLabels: false, opacity: 85,
                            reduceTransparency: protection == 1, contrast: protection == 2 ? .increased : .standard,
                            selectedIndex: 1, color: { _ in color }))
                        XCTAssertEqual(image.tabs.map(\.width), [10, 15, 10])
                        let bitmap = NSBitmapImageRep(cgImage: image.image)
                        let colors = try image.tabs.map { rect in
                            try XCTUnwrap(bitmap.colorAt(x: Int(rect.midX), y: Int(rect.midY))?.usingColorSpace(.deviceRGB))
                        }
                        let delta = max(abs(colors[1].redComponent - colors[0].redComponent),
                            abs(colors[1].greenComponent - colors[0].greenComponent), abs(colors[1].blueComponent - colors[0].blueComponent))
                        XCTAssertGreaterThan(delta * colors[1].alphaComponent, 0.06, "\(scheme), \(color), protection=\(protection)")
                        XCTAssertEqual(colors[1].alphaComponent, protection == 0 ? 0.85 : 1, accuracy: 0.005)
                        if color == .none || color == .teal {
                            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                                evidence.appendingPathComponent("selected-\(scheme)-inward\(inward)-\(color)-protection\(protection).png"))
                        }
                    }
                }
            }
        }
    }
}

@MainActor
final class SideTabEntranceControllerTests: XCTestCase {
    @MainActor private final class Clock {
        var time = 10.0
        var visible = false
        var reduceMotion = false
        var mouse = CGPoint(x: -10_000, y: -10_000)
        var mouseButtons = 0
    }
    @MainActor private final class Harness {
        let clock = Clock()
        let model: AppModel
        let state = TaskPanelState()
        let panel: DotistPanel
        let motion: PanelMotion
        let panelInput = PanelMotionTestEnvironment()
        let controller: SideTabsController
        let child: NSWindow
        init(inward: Bool = false) throws {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/side-tabs-entrance/fixture-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
            panel = DotistPanel(contentRect: CGRect(x: inward ? -1000 : 500, y: 100, width: 364, height: 620),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
            motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" },
                environment: panelInput.environment)
            let clock = clock
            var environment = SideTabsController.Environment()
            environment.time = { clock.time }
            environment.mouse = { clock.mouse }
            environment.mouseButtons = { clock.mouseButtons }
            environment.visible = { _ in clock.visible }
            environment.visibleMinX = { _ in -1000 }
            environment.reduceMotion = { clock.reduceMotion }
            environment.desktopEvents = false
            controller = SideTabsController(parent: panel, model: model, state: state, motion: motion, environment: environment)
            child = try XCTUnwrap(panel.childWindows?.first)
        }
        func sample(_ time: Double) {
            clock.time = time
            controller.synchronize()
            child.contentView?.layoutSubtreeIfNeeded()
        }
        func close() { controller.stop(); motion.stop(); panel.close() }
        func capture(_ index: Int, resting: Bool = false) -> NSView? {
            let row = controller.renderedRows[index]
            let screen = CGPoint(x: child.frame.minX + row.rect.midX, y: child.frame.minY + row.rect.midY)
            let host = resting ? panel.contentView?.subviews.first : child.contentView
            guard let host, let window = host.window else { return nil }
            let point = window.convertPoint(fromScreen: screen)
            return host.hitTest(host.superview?.convert(point, from: nil) ?? point)
        }
    }

    private func axRows(_ root: NSObject) -> [NSObject] {
        let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        guard root.responds(to: selector) else { return [] }
        let children = root.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? []
        return children.filter { ($0 as? any NSAccessibilityElementProtocol)?.accessibilityIdentifier?().hasPrefix("side-tab:") == true }
            + children.flatMap(axRows)
    }

    func testParentDragAndResizeCrossingPointerDoNotStartHoverUntilRelease() throws {
        for inward in [false, true] {
            for reduceMotion in [false, true] {
                let h = try Harness(inward: inward)
                defer { h.close() }
                h.clock.visible = true
                h.clock.reduceMotion = reduceMotion
                h.sample(10)
                h.sample(10.5)
                XCTAssertEqual(h.controller.renderedRows[0].rect.width, 15, accuracy: 0.001)

                // Simulate a press elsewhere followed by fast parent frame and
                // pointer updates, including crossings of the selected ear.
                h.clock.mouseButtons = 1
                for step in 0..<20 {
                    let x: CGFloat = inward ? -1000 + CGFloat(step % 3) : 500 + CGFloat(step * 13)
                    let frame = CGRect(x: x, y: 100 + CGFloat(step * 2),
                        width: 364 + CGFloat(step), height: 620 - CGFloat(step))
                    h.clock.mouse = step.isMultiple(of: 2) ? CGPoint(x: x + 200, y: frame.midY) :
                        CGPoint(x: inward ? max(x - 10, -1000) + 5 : x - 5, y: frame.maxY - 50)
                    h.panel.setFrame(frame, display: false)
                    h.sample(10.51 + Double(step) * 0.01)
                    XCTAssertEqual(h.controller.renderedRows[0].rect.width, 15, accuracy: 0.001)
                }
                // Releasing over the ear is a genuine hover, without requiring
                // an additional mouse-moved event.
                h.clock.mouseButtons = 0
                h.sample(10.8)
                h.sample(11.0)
                XCTAssertGreaterThan(h.controller.renderedRows[0].rect.width, 15)
                let expandedWidth = h.controller.renderedRows[0].rect.width
                h.clock.mouseButtons = 1
                h.clock.mouse = CGPoint(x: h.panel.frame.midX, y: h.panel.frame.midY)
                h.panel.setFrameOrigin(CGPoint(x: h.panel.frame.minX + 1, y: h.panel.frame.minY + 10))
                h.sample(11.2)
                XCTAssertEqual(h.controller.renderedRows[0].rect.width, expandedWidth, accuracy: 0.001)
            }
        }
    }

    func testFirstOpenHasNoInstantRowsAndDelayedRowsCannotHitOrAppearInAX() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let saved = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(saved, forAttribute: attribute) }
        let h = try Harness()
        defer { h.close() }
        h.clock.visible = true
        h.sample(10)
        XCTAssertTrue(h.controller.renderedRows.allSatisfy { $0.opacity == 0 && !$0.interactive })
        XCTAssertNil(h.capture(0))
        h.sample(10.02)
        try await Task.sleep(for: .milliseconds(40))
        h.sample(10.02)
        XCTAssertGreaterThan(h.controller.renderedRows[0].opacity, 0)
        XCTAssertEqual(h.controller.renderedRows[1].opacity, 0)
        XCTAssertEqual(String(describing: type(of: try XCTUnwrap(h.capture(0)))), "PointerView")
        for index in 1..<h.controller.renderedRows.count { XCTAssertNil(h.capture(index), "Delayed rows cannot intercept clicks") }
        let accessibility = axRows(try XCTUnwrap(h.child.contentView))
        XCTAssertEqual(accessibility.count, 1, "Only the actually presented row is exposed to AX")
        h.sample(10.5)
        try await Task.sleep(for: .milliseconds(40))
        h.sample(10.5)
        XCTAssertEqual(axRows(try XCTUnwrap(h.child.contentView)).count, h.controller.renderedRows.count)
        for index in h.controller.renderedRows.indices {
            let capture = try XCTUnwrap(h.capture(index))
            let actual = h.child.convertToScreen(capture.convert(capture.bounds, to: nil))
            let row = h.controller.renderedRows[index]
            XCTAssertEqual(actual.width, row.rect.width, accuracy: 0.001)
            XCTAssertEqual(actual.midY, h.child.frame.minY + row.rect.midY, accuracy: 0.001)
        }
        XCTAssertFalse(h.panel.isVisible)
        XCTAssertFalse(h.child.isVisible, "Fixture must never order a desktop window")
    }

    func testCollapseReopenAndIndependentAllAndGroupSelectionsUseLiveSamples() throws {
        let main = try Harness()
        let group = try Harness(inward: true)
        defer { main.close(); group.close() }
        let id = try XCTUnwrap(group.model.visibleGroups.first?.id)
        group.state.groupID = id
        for h in [main, group] {
            h.clock.visible = true
            h.sample(10)
            h.sample(10.06)
            let before = h.controller.renderedRows.map(\.opacity)
            h.motion.toggleBubble(in: CGRect(x: -1000, y: 0, width: 2000, height: 1000), animated: false)
            h.sample(10.06)
            XCTAssertEqual(h.controller.renderedRows.map(\.opacity), before)
            XCTAssertTrue(h.controller.renderedRows.allSatisfy { !$0.interactive })
            h.sample(10.08)
            let retracting = h.controller.renderedRows.map(\.opacity)
            h.motion.toggleBubble(in: CGRect(x: -1000, y: 0, width: 2000, height: 1000), animated: false)
            h.sample(10.08)
            XCTAssertEqual(h.controller.renderedRows.map(\.opacity), retracting)
            h.sample(10.5)
        }
        XCTAssertEqual(main.controller.renderedRows[0].rect.width, 15)
        XCTAssertEqual(group.controller.renderedRows.first { $0.groupID == id }?.rect.width, 15)
        XCTAssertEqual(group.controller.renderedRows[0].rect.width, 10)
        main.state.groupID = main.model.visibleGroups.last?.id
        main.sample(10.5)
        XCTAssertEqual(main.controller.renderedRows[0].rect.width, 10)
        group.state.groupID = nil
        group.sample(10.5)
        XCTAssertEqual(group.controller.renderedRows[0].rect.width, 15)
    }

    func testEntranceWaitsForTheActualPanelExpansionCompletion() throws {
        let h = try Harness()
        defer { h.close() }
        h.clock.visible = true
        h.motion.toggleBubble(in: h.panelInput.area, animated: false)
        h.sample(10)
        h.motion.toggleBubble(in: h.panelInput.area)
        XCTAssertTrue(h.motion.animationInProgress)
        try h.panelInput.sampleFrameAnimation(for: h.panel, progress: 0.6)
        h.sample(10.2)
        XCTAssertTrue(h.controller.renderedRows.allSatisfy { $0.opacity == 0 && !$0.interactive })
        try h.panelInput.completeFrameAnimation(for: h.panel)
        h.sample(10.34)
        XCTAssertTrue(h.controller.renderedRows.allSatisfy { $0.opacity == 0 && !$0.interactive })
        h.sample(10.36)
        XCTAssertGreaterThan(h.controller.renderedRows[0].opacity, 0)
        XCTAssertEqual(h.controller.renderedRows[1].opacity, 0)
        h.sample(10.84)
        XCTAssertTrue(h.controller.renderedRows.allSatisfy { $0.opacity == 1 && $0.interactive })
    }

    func testReduceMotionAndLeftEdgeRestingHostShareImmediateSamplesAndHitRects() async throws {
        let h = try Harness(inward: true)
        defer { h.close() }
        h.clock.reduceMotion = true
        h.clock.visible = true
        h.sample(10)
        try await Task.sleep(for: .milliseconds(40))
        h.sample(10)
        XCTAssertTrue(h.controller.renderedRows.allSatisfy { $0.opacity == 1 && $0.interactive })
        let resting = try XCTUnwrap(h.panel.contentView?.subviews.first)
        XCTAssertFalse(resting.isHidden)
        XCTAssertEqual(h.child.frame.minX, -1000)
        XCTAssertEqual(h.child.frame.width, 15)
        for index in h.controller.renderedRows.indices {
            XCTAssertEqual(String(describing: type(of: try XCTUnwrap(h.capture(index, resting: true)))), "PointerView")
        }
        h.clock.visible = false
        h.sample(10)
        XCTAssertTrue(resting.isHidden)
        XCTAssertTrue(h.child.ignoresMouseEvents)
        for index in h.controller.renderedRows.indices { XCTAssertNil(h.capture(index, resting: true)) }
    }
}

@MainActor
private final class SideTabOpeningSampleParent: NSPanel {
    override var isVisible: Bool { true }
    override var isOnActiveSpace: Bool { true }
}

@MainActor
final class SideTabOriginalAPIRegressionTests: XCTestCase {
    func testFirstSynchronizationDoesNotExposeAllRowsAtFullWidth() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/side-tabs-entrance/original-api-data")
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let frame = CGRect(x: 500, y: 100, width: 364, height: 620)
        let motionPanel = DotistPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let parent = SideTabOpeningSampleParent(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        motionPanel.isReleasedWhenClosed = false; parent.isReleasedWhenClosed = false
        let motion = PanelMotion(model: model, panel: motionPanel, size: frame.size, title: { "" })
        let controller = SideTabsController(parent: parent, model: model, state: TaskPanelState(), motion: motion)
        defer { controller.stop(); motion.stop(); parent.close(); motionPanel.close() }
        let child = try XCTUnwrap(parent.childWindows?.first)
        let host = try XCTUnwrap(child.contentView)
        host.layoutSubtreeIfNeeded()
        let screen = CGPoint(x: child.frame.midX, y: child.frame.minY + 17)
        let local = child.convertPoint(fromScreen: screen)
        let target = host.hitTest(host.superview?.convert(local, from: nil) ?? local)
        print("FIRST OPEN SAMPLE alpha=\(child.alphaValue), window=\(child.frame), last-row-native-target=\(String(describing: target))")
        XCTAssertNil(target, "The last row must wait for its entrance delay instead of appearing at full geometry on the first sample")
    }
}
