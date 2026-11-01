import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

final class SideTabGeometryTests: XCTestCase {
    func testNeighboringTabsHaveSixPointGap() {
        let panel = CGRect(x: 500, y: 100, width: 364, height: 620)
        for right in [false, true] {
            let first = SideTabGeometry.frame(panel: panel, index: 0, width: 120, right: right)
            let second = SideTabGeometry.frame(panel: panel, index: 1, width: 120, right: right)
            XCTAssertEqual(first.minY - second.maxY, 6)
        }
    }
    func testWidthsFollowTextAndExpansion() {
        XCTAssertEqual(SideTabGeometry.expandedWidth(textWidth: 10), 48)
        XCTAssertEqual(SideTabGeometry.expandedWidth(textWidth: 82.2), 111)
        XCTAssertEqual(SideTabGeometry.width(expanded: false, fullWidth: 111), 10)
        XCTAssertEqual(SideTabGeometry.width(expanded: true, fullWidth: 111), 111)
    }
    func testOneExpansionSampleKeepsWindowContentAndTextSynchronized() {
        let panel = CGRect(x: 500, y: 100, width: 364, height: 620)
        for right in [false, true] {
            for step in 0...120 {
                let progress = CGFloat(step) / 120
                let sample = SideTabGeometry.snapshot(panel: panel, fullWidths: [48, 111, 180], progress: progress, right: right)
                XCTAssertEqual(sample.textOpacity, Double(progress), accuracy: 0.000001)
                XCTAssertEqual(sample.window.width, 10 + 170 * progress + 2 * SideTabGeometry.shadowInset, accuracy: 0.000001)
                for (index, tab) in sample.tabs.enumerated() {
                    let fullWidth: CGFloat = [48, 111, 180][index]
                    XCTAssertEqual(tab.width, 10 + (fullWidth - 10) * progress, accuracy: 0.000001)
                    XCTAssertEqual(right ? tab.minX : tab.maxX, right ? panel.maxX : panel.minX, accuracy: 0.000001)
                    XCTAssertTrue(sample.window.contains(tab))
                    // The first tab and its shadow start below the panel's corner.
                    XCTAssertLessThanOrEqual(tab.maxY, panel.maxY - 40)
                    let local = tab.offsetBy(dx: -sample.window.minX, dy: -sample.window.minY)
                    XCTAssertEqual(local.offsetBy(dx: sample.window.minX, dy: sample.window.minY), tab)
                }
            }
        }
        XCTAssertEqual(SideTabGeometry.snapshot(panel: panel, fullWidths: [111], progress: -1, right: false).textOpacity, 0)
        XCTAssertEqual(SideTabGeometry.snapshot(panel: panel, fullWidths: [111], progress: 2, right: false).textOpacity, 1)
    }

    func testExpansionStartsOnEventFinishesIn160MillisecondsAndReversesWithoutJump() {
        var animation = SideTabExpansion()
        animation.setExpanded(true, at: 10, reduceMotion: false)
        XCTAssertEqual(animation.progress(at: 10), 0)
        XCTAssertGreaterThan(animation.progress(at: 10 + 1.0 / 120), 0)
        XCTAssertEqual(animation.progress(at: 10.16), 1, accuracy: 0.000001)
        let current = animation.progress(at: 10.08)
        animation.setExpanded(false, at: 10.08, reduceMotion: false)
        XCTAssertEqual(animation.progress(at: 10.08), current, accuracy: 0.000001)
        XCTAssertLessThan(animation.progress(at: 10.09), current)
        XCTAssertEqual(animation.progress(at: 10.24), 0, accuracy: 0.000001)
        animation.setExpanded(true, at: 11, reduceMotion: true)
        XCTAssertEqual(animation.progress(at: 11), 1)
        animation.setExpanded(false, at: 11, reduceMotion: true)
        XCTAssertEqual(animation.progress(at: 11), 0)
        XCTAssertEqual(SideTabGeometry.collapseDelay, 0.12)
    }

    func testSideChangesAtWidthDependentScreenBoundary() {
        XCTAssertTrue(SideTabGeometry.isRight(panelMinX: 109, visibleMinX: 0, expandedWidth: 110))
        XCTAssertFalse(SideTabGeometry.isRight(panelMinX: 110, visibleMinX: 0, expandedWidth: 110))
        XCTAssertTrue(SideTabGeometry.isRight(panelMinX: -900, visibleMinX: -1000, expandedWidth: 120))
        XCTAssertFalse(SideTabGeometry.isRight(panelMinX: -880, visibleMinX: -1000, expandedWidth: 120))
    }

    func testFramesStayFlushForEveryIntermediateMoveAndResize() {
        for step in 0...120 {
            let t = CGFloat(step) / 120
            let panel = CGRect(x: -1100 + 800 * t, y: 100 + 120 * t, width: 364 + 100 * t, height: 620 - 200 * t)
            for right in [false, true] {
                let window = SideTabGeometry.windowFrame(panel: panel, count: 4, width: 120, right: right)
                for index in 0..<4 {
                    for width: CGFloat in [10, 48, 120] {
                        let tab = SideTabGeometry.frame(panel: panel, index: index, width: width, right: right)
                        XCTAssertEqual(right ? tab.minX : tab.maxX, right ? panel.maxX : panel.minX, accuracy: 0.000001)
                        XCTAssertEqual(tab.maxY, panel.maxY - 40 - CGFloat(index) * 40, accuracy: 0.000001)
                        XCTAssertTrue(window.insetBy(dx: -0.000001, dy: -0.000001).contains(tab))
                    }
                }
            }
        }
    }

    func testTranslationAndHeightChangesPreserveTopAnchor() {
        let initial = CGRect(x: 600, y: 100, width: 364, height: 620)
        let before = SideTabGeometry.frame(panel: initial, index: 2, width: 80, right: false)
        let translated = SideTabGeometry.frame(panel: initial.offsetBy(dx: -240, dy: 51), index: 2, width: 80, right: false)
        XCTAssertEqual(translated, before.offsetBy(dx: -240, dy: 51))
        let resized = CGRect(x: 600, y: 200, width: 500, height: 520)
        XCTAssertEqual(SideTabGeometry.frame(panel: resized, index: 2, width: 80, right: false), before)
    }

    func testReorderingClampsToVisibleGroupsAndKeepsAllOutsideTheOrder() {
        let ids = ["work", "life", "study"]
        XCTAssertEqual(SideTabGeometry.destination(source: 0, screenDeltaY: -40, count: 3), 1)
        XCTAssertEqual(SideTabGeometry.destination(source: 0, screenDeltaY: 1000, count: 3), 0)
        XCTAssertEqual(SideTabGeometry.destination(source: 0, screenDeltaY: -1000, count: 3), 2)
        XCTAssertEqual(SideTabGeometry.destination(source: 2, screenDeltaY: 80, count: 3), 0)
        XCTAssertEqual(SideTabGeometry.reordered(ids, id: "work", to: 2), ["life", "study", "work"])
        XCTAssertEqual(SideTabGeometry.reordered(ids, id: "study", to: 0), ["study", "work", "life"])
        XCTAssertEqual(SideTabGeometry.reordered(ids, id: "all", to: 1), ids)
        XCTAssertFalse(SideTabGeometry.isDrag(CGPoint(x: 0, y: 4)))
        XCTAssertTrue(SideTabGeometry.isDrag(CGPoint(x: 0, y: 4.01)))
        XCTAssertTrue(SideTabGeometry.isDrag(CGPoint(x: 3, y: 3)))
        let panel = CGRect(x: 600, y: 100, width: 364, height: 620)
        let lifted = SideTabGeometry.frame(panel: panel, index: 1, width: 80, right: false, offsetY: -40)
        XCTAssertEqual(lifted, SideTabGeometry.frame(panel: panel, index: 2, width: 80, right: false))
    }
}

@MainActor
final class SideTabLabelRenderingTests: XCTestCase {
    func testCompleteTabTreeRendersNamesAndSixPointGapsInBothAppearances() throws {
        let names = ["工作計畫", "Work projects", "仕事の計画"]
        for scheme in [ColorScheme.light, .dark] {
            for right in [false, true] {
                let expanded = try XCTUnwrap(SideTabsSnapshot.render(names: names, language: "ja", scheme: scheme,
                    right: right, expanded: true))
                let background = try XCTUnwrap(SideTabsSnapshot.render(names: names, language: "ja", scheme: scheme,
                    right: right, expanded: true, showLabels: false))
                let collapsed = try XCTUnwrap(SideTabsSnapshot.render(names: names, language: "ja", scheme: scheme,
                    right: right, expanded: false))
                let collapsedBackground = try XCTUnwrap(SideTabsSnapshot.render(names: names, language: "ja", scheme: scheme,
                    right: right, expanded: false, showLabels: false))
                let pixels = NSBitmapImageRep(cgImage: expanded.image)
                let paper = NSBitmapImageRep(cgImage: background.image)
                var counts: [Int] = []
                for rect in expanded.tabs {
                    let count = differingPixels(pixels, paper, in: rect)
                    counts.append(count)
                    XCTAssertGreaterThan(count, 25, "Every complete tab must contain readable text: \(scheme), right=\(right)")
                    // Verify the surface actually exists as well as its foreground.
                    XCTAssertGreaterThan(try XCTUnwrap(pixels.colorAt(x: Int(rect.midX), y: Int(rect.minY + 3))).alphaComponent, 0.8)
                }
                for index in 0..<expanded.tabs.count - 1 {
                    let upper = expanded.tabs[index], lower = expanded.tabs[index + 1]
                    XCTAssertEqual(lower.minY - upper.maxY, 6)
                    for y in Int(upper.maxY)..<Int(lower.minY) {
                        for x in 0..<pixels.pixelsWide {
                            XCTAssertEqual(pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0, 0,
                                "All six gap rows must stay transparent; glass must not bridge tabs")
                        }
                    }
                }
                let narrowPixels = NSBitmapImageRep(cgImage: collapsed.image)
                let narrowPaper = NSBitmapImageRep(cgImage: collapsedBackground.image)
                let narrowText = differingPixels(narrowPixels, narrowPaper,
                    in: CGRect(x: 0, y: 0, width: narrowPixels.pixelsWide, height: narrowPixels.pixelsHigh))
                XCTAssertEqual(narrowText, 0, "Collapsed tabs must contain no text")
                print("SideTabs raster \(scheme) right=\(right): text pixels=\(counts); gaps=6pt transparent; collapsed text=\(narrowText)")
            }
        }
    }

    private func differingPixels(_ image: NSBitmapImageRep, _ background: NSBitmapImageRep, in rect: CGRect) -> Int {
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                guard let a = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = background.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let contrast = max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
                if a.alphaComponent > 0.5 && contrast > 0.12 { count += 1 }
            }
        }
        return count
    }

    func testExpandedNamesRenderAndCollapsedNamesAreFullyTransparent() throws {
        for (language, name) in [("zh-CN", "全部"), ("en", "Work projects"), ("ja", "仕事の計画"), ("zh-Hant", "工作與生活")] {
            let text = name as NSString
            let fullWidth = SideTabGeometry.expandedWidth(textWidth: max(
                text.size(withAttributes: [.font: DotistDesign.nativeFont(13, serif: true, language: language)]).width,
                text.size(withAttributes: [.font: DotistDesign.nativeFont(13, weight: .semibold, serif: true, language: language)]).width))
            for right in [false, true] {
                for expanded in [false, true] {
                    let label = SideTabLabel(name: name, language: language, selected: true, hovered: false,
                        right: right, width: expanded ? fullWidth : 10, fullWidth: fullWidth, textOpacity: expanded ? 1 : 0)
                    let renderer = ImageRenderer(content: label.environment(\.colorScheme, .light))
                    let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                    var foregroundPixels = 0
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { foregroundPixels += 1 }
                        }
                    }
                    if expanded {
                        XCTAssertGreaterThan(foregroundPixels, 10, "\(language) name must render at expanded width")
                    } else {
                        XCTAssertEqual(foregroundPixels, 0, "Narrow edges must contain no letters or ellipsis")
                    }
                }
            }
        }
    }
}

@MainActor
final class SideTabWindowSynchronizationTests: XCTestCase {
    private func hitTarget(in content: NSView, atWindowPoint point: CGPoint) -> NSView? {
        // hitTest takes its receiver's superview coordinates. NSHostingView is
        // flipped: converting into content coordinates first mirrors the tab index.
        let parentPoint = content.superview?.convert(point, from: nil) ?? point
        return content.hitTest(parentPoint)
    }

    func testNativeTabHitTestingMatchesScreenFramesOffscreen() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wH1-hit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let parent = DotistPanel(contentRect: CGRect(x: 500, y: 100, width: 364, height: 620),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let motion = PanelMotion(model: model, panel: parent, size: parent.frame.size, title: { "test" })
        let controller = SideTabsController(parent: parent, model: model, state: TaskPanelState(), motion: motion)
        defer { controller.stop() }
        let child = try XCTUnwrap(parent.childWindows?.first { $0.identifier?.rawValue == "dotist.side-tabs" })
        let content = try XCTUnwrap(child.contentView)
        try await Task.sleep(for: .milliseconds(60))
        content.layoutSubtreeIfNeeded()
        let before = model.visibleGroups.map(\.id)
        let right = child.frame.midX > parent.frame.midX
        for index in 0...before.count {
            let frame = SideTabGeometry.frame(panel: parent.frame, index: index, width: 10, right: right)
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let target = try XCTUnwrap(hitTarget(in: content, atWindowPoint: child.convertPoint(fromScreen: point)))
            XCTAssertEqual(String(describing: type(of: target)), "PointerView")
            let actual = child.convertToScreen(target.convert(target.bounds, to: nil))
            XCTAssertEqual(actual.midY, frame.midY, accuracy: 0.001, "Tab \(index) must hit its own capture view")
        }
    }

    func testExpandedWindowAndNativeCaptureFramesUseTheSameWidth() async throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else {
            throw XCTSkip("Live expansion requires a WindowServer display; label rendering and geometry are checked offscreen")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wIA-expand-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let parent = DotistPanel(contentRect: CGRect(x: 500, y: 100, width: 364, height: 620),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        parent.appearance = NSAppearance(named: .aqua)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let motion = PanelMotion(model: model, panel: parent, size: parent.frame.size, title: { "test" })
        let controller = SideTabsController(parent: parent, model: model, state: TaskPanelState(), motion: motion)
        defer { controller.stop() }
        parent.orderFront(nil)
        let child = try XCTUnwrap(parent.childWindows?.first { $0.identifier?.rawValue == "dotist.side-tabs" })
        let content = try XCTUnwrap(child.contentView)
        let right = child.frame.midX > parent.frame.midX
        let tab = SideTabGeometry.frame(panel: parent.frame, index: 0, width: 10, right: right)
        let mouse = CGPoint(x: tab.midX, y: tab.midY)
        let collapsed = child.frame
        controller.synchronize(mouse: mouse)
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(10))
            controller.synchronize(mouse: mouse)
        }
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(child.frame.width, collapsed.width)
        let capture = try XCTUnwrap(hitTarget(in: content, atWindowPoint: child.convertPoint(fromScreen: mouse)))
        XCTAssertEqual(String(describing: type(of: capture)), "PointerView")
        let actual = child.convertToScreen(capture.convert(capture.bounds, to: nil))
        let text = model.text("全部") as NSString
        let fullWidth = SideTabGeometry.expandedWidth(textWidth: max(
            text.size(withAttributes: [.font: DotistDesign.nativeFont(13, serif: true, language: model.language)]).width,
            text.size(withAttributes: [.font: DotistDesign.nativeFont(13, weight: .semibold, serif: true, language: model.language)]).width))
        XCTAssertEqual(actual.width, fullWidth, accuracy: 0.001)
        XCTAssertEqual(right ? actual.minX : actual.maxX, right ? parent.frame.maxX : parent.frame.minX, accuracy: 0.001)
        // Leaving keeps the expanded width through the debounce, then shrinks both
        // the actual child window and its native capture region back to 10pt.
        let outside = CGPoint(x: parent.frame.midX, y: parent.frame.midY)
        controller.synchronize(mouse: outside)
        XCTAssertGreaterThan(child.frame.width, collapsed.width)
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(10))
            controller.synchronize(mouse: outside)
        }
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(child.frame, collapsed)
        let narrow = try XCTUnwrap(hitTarget(in: content, atWindowPoint: child.convertPoint(fromScreen: mouse)))
        XCTAssertEqual(narrow.bounds.width, SideTabGeometry.collapsedWidth, accuracy: 0.001)
    }

    func testNativeTabMouseCaptureReordersWithoutSelectingOrMovingPanel() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wG2a-drag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let model = try AppModel(store: store)
        let state = TaskPanelState()
        guard let area = NSScreen.main?.visibleFrame else {
            throw XCTSkip("Native mouse capture requires a WindowServer display; geometry and child attachment run offscreen")
        }
        let panelFrame = CGRect(x: area.midX - 182, y: area.midY - 220, width: 364, height: 440)
        let parent = DotistPanel(contentRect: panelFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.isMovableByWindowBackground = true
        defer { parent.close() }
        let motion = PanelMotion(model: model, panel: parent, size: parent.frame.size, title: { "test" })
        let controller = SideTabsController(parent: parent, model: model, state: state, motion: motion)
        defer { controller.stop() }
        parent.orderFront(nil)
        let child = try XCTUnwrap(parent.childWindows?.first { $0.identifier?.rawValue == "dotist.side-tabs" })
        let before = model.visibleGroups.map(\.id)
        XCTAssertGreaterThanOrEqual(before.count, 2)
        let right = child.frame.midX > parent.frame.midX
        let point = SideTabGeometry.frame(panel: parent.frame, index: 1, width: 10, right: right)
        let start = CGPoint(x: point.midX, y: point.midY)
        controller.synchronize(mouse: start)
        try await Task.sleep(for: .milliseconds(60))
        let content = try XCTUnwrap(child.contentView)
        content.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(hitTarget(in: content, atWindowPoint: child.convertPoint(fromScreen: start)))
        XCTAssertEqual(String(describing: type(of: target)), "PointerView", "The native capture view must receive tab clicks")
        XCTAssertTrue(child.convertToScreen(target.convert(target.bounds, to: nil)).contains(start),
                      "The capture view must contain the requested screen point")
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: child.convertPoint(fromScreen: point), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: child.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
        }
        target.mouseDown(with: try event(.leftMouseDown, start))
        target.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: start.x + 2, y: start.y - 2)))
        target.mouseUp(with: try event(.leftMouseUp, CGPoint(x: start.x + 2, y: start.y - 2)))
        XCTAssertEqual(state.groupID, before[0], "Subthreshold movement must remain a click")
        XCTAssertEqual(model.visibleGroups.map(\.id), before, "Subthreshold movement must not reorder groups")
        XCTAssertFalse(model.busy)
        state.groupID = nil
        controller.synchronize(mouse: start)
        target.mouseDown(with: try event(.leftMouseDown, start))
        let end = CGPoint(x: start.x + 70, y: start.y - SideTabGeometry.stride)
        target.mouseDragged(with: try event(.leftMouseDragged, end))
        XCTAssertNil(state.groupID, "Dragging must not also select the tab")
        XCTAssertEqual(model.visibleGroups.map(\.id), before, "The preview must not persist until mouse-up")
        target.mouseUp(with: try event(.leftMouseUp, end))
        let deadline = Date().addingTimeInterval(5)
        while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
        let after = SideTabGeometry.reordered(before, id: before[0], to: 1)
        XCTAssertEqual(model.visibleGroups.map(\.id), after)
        XCTAssertNil(state.groupID)
        XCTAssertEqual(parent.frame, panelFrame, "Dragging tabs must never drag the main panel")
        XCTAssertTrue(child.parent === parent)

        // Neighbors animate to the committed slots; hit their settled frames.
        try await Task.sleep(for: .seconds(SideTabGeometry.reorderDuration + 0.1))
        // Reacquire each native capture view after the preview commits. All is tab
        // zero; tab i + 1 must select visibleGroups[i], including after reordering.
        for index in 0...after.count {
            let frame = SideTabGeometry.frame(panel: parent.frame, index: index, width: 10, right: right)
            let point = CGPoint(x: frame.midX, y: frame.midY)
            controller.synchronize(mouse: point)
            try await Task.sleep(for: .milliseconds(60))
            content.layoutSubtreeIfNeeded()
            let capture = try XCTUnwrap(hitTarget(in: content, atWindowPoint: child.convertPoint(fromScreen: point)))
            XCTAssertEqual(String(describing: type(of: capture)), "PointerView")
            XCTAssertTrue(child.convertToScreen(capture.convert(capture.bounds, to: nil)).contains(point))
            state.groupID = index == 0 ? after[0] : nil
            capture.mouseDown(with: try event(.leftMouseDown, point))
            capture.mouseUp(with: try event(.leftMouseUp, point))
            XCTAssertEqual(state.groupID, index == 0 ? nil : after[index - 1], "Tab \(index) must select its displayed group")
            XCTAssertEqual(model.visibleGroups.map(\.id), after, "Clicking tabs must not reorder groups")
        }

        let allFrame = SideTabGeometry.frame(panel: parent.frame, index: 0, width: 10, right: right)
        let allPoint = CGPoint(x: allFrame.midX, y: allFrame.midY)
        controller.synchronize(mouse: allPoint)
        content.layoutSubtreeIfNeeded()
        let allCapture = try XCTUnwrap(hitTarget(in: content, atWindowPoint: child.convertPoint(fromScreen: allPoint)))
        state.groupID = after[0]
        allCapture.mouseDown(with: try event(.leftMouseDown, allPoint))
        let allEnd = CGPoint(x: allPoint.x, y: allPoint.y - SideTabGeometry.stride)
        allCapture.mouseDragged(with: try event(.leftMouseDragged, allEnd))
        allCapture.mouseUp(with: try event(.leftMouseUp, allEnd))
        XCTAssertEqual(state.groupID, after[0], "Dragging All must not select it")
        XCTAssertEqual(model.visibleGroups.map(\.id), after, "All stays outside the sortable group order")
        XCTAssertFalse(model.busy)
        XCTAssertEqual(parent.frame, panelFrame)
    }

    func testChildTracksActualParentFrameSynchronouslyAndDetachesOnStop() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wG2a-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let model = try AppModel(store: store)
        let parent = DotistPanel(contentRect: CGRect(x: 500, y: 100, width: 364, height: 620),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let motion = PanelMotion(model: model, panel: parent, size: parent.frame.size, title: { "test" })
        let controller = SideTabsController(parent: parent, model: model, state: TaskPanelState(), motion: motion)
        defer { controller.stop() }
        let child = try XCTUnwrap(parent.childWindows?.first { $0.identifier?.rawValue == "dotist.side-tabs" })
        XCTAssertEqual(parent.childWindows?.filter { $0.identifier?.rawValue == "dotist.side-tabs" }.count, 1, "All tabs must share one transparent child window")
        XCTAssertFalse(child.isMovable)
        XCTAssertFalse(child.isOpaque)
        XCTAssertEqual(child.backgroundColor, .clear)
        XCTAssertFalse(try XCTUnwrap(child.contentView).isOpaque)
        XCTAssertFalse(try XCTUnwrap(child.contentView?.layer).masksToBounds)

        func assertAttached(file: StaticString = #filePath, line: UInt = #line) {
            let frame = parent.frame
            let right = SideTabGeometry.isRight(panelMinX: frame.minX,
                visibleMinX: (parent.screen ?? NSScreen.main)?.visibleFrame.minX ?? frame.minX, expandedWidth: child.frame.width)
            XCTAssertEqual(child.frame, SideTabGeometry.snapshot(panel: frame,
                fullWidths: Array(repeating: SideTabGeometry.collapsedWidth, count: model.visibleGroups.count + 1),
                progress: 0, right: right).window, file: file, line: line)
        }
        assertAttached()
        for frame in [CGRect(x: 700, y: 170, width: 364, height: 620),
                      CGRect(x: 300, y: 200, width: 500, height: 520),
                      CGRect(x: -1400, y: -200, width: 364, height: 620)] {
            parent.setFrame(frame, display: false)
            // No run-loop drain or timer: didMove/didResize synchronizes in this call.
            assertAttached()
        }
        controller.stop()
        XCTAssertFalse(parent.childWindows?.contains { $0 === child } ?? false, "Stopping tabs must detach only their own child, preserving other panel children")
    }
}
