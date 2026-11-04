import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

final class SideTabGeometryTests: XCTestCase {
    func testNeighboringTabsHaveSixPointGap() {
        let panel = CGRect(x: 500, y: 100, width: 364, height: 620)
        for inward in [false, true] {
            let first = SideTabGeometry.frame(panel: panel, index: 0, width: 120, inward: inward)
            let second = SideTabGeometry.frame(panel: panel, index: 1, width: 120, inward: inward)
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
        for inward in [false, true] {
            for step in 0...120 {
                let progress = CGFloat(step) / 120
                let sample = SideTabGeometry.snapshot(panel: panel, fullWidths: [48, 111, 180], progress: progress, inward: inward)
                XCTAssertEqual(sample.textOpacity, Double(progress), accuracy: 0.000001)
                XCTAssertEqual(sample.window.width, 10 + 170 * progress + 2 * SideTabGeometry.shadowInset, accuracy: 0.000001)
                for (index, tab) in sample.tabs.enumerated() {
                    let fullWidth: CGFloat = [48, 111, 180][index]
                    XCTAssertEqual(tab.width, 10 + (fullWidth - 10) * progress, accuracy: 0.000001)
                    XCTAssertEqual(inward ? tab.minX : tab.maxX, panel.minX, accuracy: 0.000001)
                    XCTAssertTrue(sample.window.contains(tab))
                    // The first tab and its shadow start below the panel's corner.
                    XCTAssertLessThanOrEqual(tab.maxY, panel.maxY - 40)
                    let local = tab.offsetBy(dx: -sample.window.minX, dy: -sample.window.minY)
                    XCTAssertEqual(local.offsetBy(dx: sample.window.minX, dy: sample.window.minY), tab)
                }
            }
        }
        XCTAssertEqual(SideTabGeometry.snapshot(panel: panel, fullWidths: [111], progress: -1, inward: false).textOpacity, 0)
        XCTAssertEqual(SideTabGeometry.snapshot(panel: panel, fullWidths: [111], progress: 2, inward: false).textOpacity, 1)
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

    func testDirectionUsesExpandedWidthAndEightyPointHysteresis() {
        var placement = SideTabPlacement()
        placement.update(availableSpace: 110, expandedWidth: 110)
        XCTAssertFalse(placement.inward)
        placement.update(availableSpace: 109, expandedWidth: 110)
        XCTAssertTrue(placement.inward)
        for room: CGFloat in [110, 109, 111, 150, 190] {
            placement.update(availableSpace: room, expandedWidth: 110)
            XCTAssertTrue(placement.inward)
        }
        placement.update(availableSpace: 191, expandedWidth: 110)
        XCTAssertFalse(placement.inward)
        XCTAssertTrue(SideTabGeometry.expandsInward(availableSpace: -900 - (-1000), expandedWidth: 120, wasInward: false))
    }

    func testModeSwitchUsesCurrentSpaceImmediatelyWithoutRetractingOrRestartingExpansion() {
        var placement = SideTabPlacement()
        var animation = SideTabExpansion()
        placement.update(availableSpace: 240, expandedWidth: 120)
        animation.setExpanded(true, at: 10, reduceMotion: false)
        let midExpansion = animation.progress(at: 10.08)
        XCTAssertGreaterThan(midExpansion, 0)
        XCTAssertLessThan(midExpansion, 1)
        placement.update(availableSpace: 119, expandedWidth: 120)
        XCTAssertTrue(placement.inward, "Switch anchors at the threshold, including during expansion")
        XCTAssertEqual(animation.progress(at: 10.08), midExpansion)
        XCTAssertEqual(animation.target, 1)
        XCTAssertEqual(animation.progress(at: 10.16), 1, accuracy: 0.000001)
        for (step, room) in [119.0, 121, 118, 120, 122, 119].enumerated() {
            let time = 11 + Double(step) * 0.02
            placement.update(availableSpace: room, expandedWidth: 120)
            XCTAssertTrue(placement.inward, "Small reversals must stay inside the hysteresis band")
            XCTAssertEqual(animation.progress(at: time), 1)
        }
        for room: CGFloat in [120, 119, 121, 150, 199, 200] {
            placement.update(availableSpace: room, expandedWidth: 120)
            XCTAssertTrue(placement.inward)
        }
        placement.update(availableSpace: 201, expandedWidth: 120, canSwitch: false)
        XCTAssertTrue(placement.inward, "Do not change direction during native tab mouse capture")
        placement.update(availableSpace: 201, expandedWidth: 120)
        XCTAssertFalse(placement.inward)
        XCTAssertEqual(animation.progress(at: 12), 1)
    }

    func testInwardFramesUseAvailableLeftStripAndOverlayOnlyBelowToolbar() {
        for room: CGFloat in [0, 3, 9, 10, 60] {
            let panel = CGRect(x: -1000 + room, y: 100, width: 364, height: 620)
            for progress: CGFloat in [0, 0.25, 0.5, 1] {
                let sample = SideTabGeometry.snapshot(panel: panel, fullWidths: [80, 120], progress: progress,
                    inward: true, visibleMinX: -1000)
                XCTAssertEqual(sample.window.minX, max(-1000, panel.minX - 10))
                XCTAssertGreaterThanOrEqual(sample.window.minX, -1000)
                XCTAssertLessThanOrEqual(sample.window.maxX, panel.maxX)
                XCTAssertEqual(sample.window.maxY, panel.maxY - 40)
                for tab in sample.tabs { XCTAssertTrue(sample.window.contains(tab)) }
                if room == 0 { XCTAssertTrue(panel.contains(sample.window)) }
            }
        }
        XCTAssertEqual(SideTabGeometry.childOrder(inward: true, expanded: true, progress: 0), .above)
        XCTAssertEqual(SideTabGeometry.childOrder(inward: true, expanded: false, progress: 0.001), .above)
        XCTAssertEqual(SideTabGeometry.childOrder(inward: true, expanded: false, progress: 0), .below)
        XCTAssertEqual(SideTabGeometry.childOrder(inward: false, expanded: true, progress: 1), .below)
    }

    func testFramesStayFlushForEveryIntermediateMoveAndResize() {
        for step in 0...120 {
            let t = CGFloat(step) / 120
            let panel = CGRect(x: -1100 + 800 * t, y: 100 + 120 * t, width: 364 + 100 * t, height: 620 - 200 * t)
            for inward in [false, true] {
                let window = SideTabGeometry.windowFrame(panel: panel, count: 4, width: 120, inward: inward)
                for index in 0..<4 {
                    for width: CGFloat in [10, 48, 120] {
                        let tab = SideTabGeometry.frame(panel: panel, index: index, width: width, inward: inward)
                        XCTAssertEqual(inward ? tab.minX : tab.maxX, panel.minX, accuracy: 0.000001)
                        XCTAssertEqual(tab.maxY, panel.maxY - 40 - CGFloat(index) * 40, accuracy: 0.000001)
                        XCTAssertTrue(window.insetBy(dx: -0.000001, dy: -0.000001).contains(tab))
                    }
                }
            }
        }
    }

    func testTranslationAndHeightChangesPreserveTopAnchor() {
        let initial = CGRect(x: 600, y: 100, width: 364, height: 620)
        let before = SideTabGeometry.frame(panel: initial, index: 2, width: 80, inward: false)
        let translated = SideTabGeometry.frame(panel: initial.offsetBy(dx: -240, dy: 51), index: 2, width: 80, inward: false)
        XCTAssertEqual(translated, before.offsetBy(dx: -240, dy: 51))
        let resized = CGRect(x: 600, y: 200, width: 500, height: 520)
        XCTAssertEqual(SideTabGeometry.frame(panel: resized, index: 2, width: 80, inward: false), before)
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
        let lifted = SideTabGeometry.frame(panel: panel, index: 1, width: 80, inward: false, offsetY: -40)
        XCTAssertEqual(lifted, SideTabGeometry.frame(panel: panel, index: 2, width: 80, inward: false))
    }
}

@MainActor
final class SideTabLabelRenderingTests: XCTestCase {
    func testCompleteTabTreeRendersNamesAndSixPointGapsInBothAppearances() throws {
        let names = ["工作計畫", "Work projects", "Projets de travail"]
        for scheme in [ColorScheme.light, .dark] {
            for inward in [false, true] {
                let expanded = try XCTUnwrap(SideTabsSnapshot.render(names: names, language: "fr", scheme: scheme,
                    inward: inward, expanded: true))
                let background = try XCTUnwrap(SideTabsSnapshot.render(names: names, language: "fr", scheme: scheme,
                    inward: inward, expanded: true, showLabels: false))
                let collapsed = try XCTUnwrap(SideTabsSnapshot.render(names: names, language: "fr", scheme: scheme,
                    inward: inward, expanded: false))
                let collapsedBackground = try XCTUnwrap(SideTabsSnapshot.render(names: names, language: "fr", scheme: scheme,
                    inward: inward, expanded: false, showLabels: false))
                let pixels = NSBitmapImageRep(cgImage: expanded.image)
                let paper = NSBitmapImageRep(cgImage: background.image)
                var counts: [Int] = []
                for rect in expanded.tabs {
                    let count = differingPixels(pixels, paper, in: rect)
                    counts.append(count)
                    XCTAssertGreaterThan(count, 25, "Every complete tab must contain readable text: \(scheme), inward=\(inward)")
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
                print("SideTabs raster \(scheme) inward=\(inward): text pixels=\(counts); gaps=6pt transparent; collapsed text=\(narrowText)")
            }
        }
    }

    func testConnectionEdgeIsSquareAndOnlyOuterCornersRoundInEitherDirection() throws {
        for inward in [false, true] {
            for expanded in [false, true] {
                let sample = try XCTUnwrap(SideTabsSnapshot.render(names: ["Work"], language: "en",
                    scheme: .light, inward: inward, expanded: expanded, showLabels: false, opacity: 100))
                let bitmap = NSBitmapImageRep(cgImage: sample.image)
                let connectionX = inward ? 0 : bitmap.pixelsWide - 1
                let outerX = inward ? bitmap.pixelsWide - 1 : 0
                for y in 0..<bitmap.pixelsHigh {
                    XCTAssertEqual(bitmap.colorAt(x: connectionX, y: y)?.alphaComponent ?? 0, 1,
                                   accuracy: 0.005, "Connection edge is flush through both corners: inward=\(inward), expanded=\(expanded), y=\(y)")
                }
                for y in [0, bitmap.pixelsHigh - 1] {
                    XCTAssertEqual(bitmap.colorAt(x: outerX, y: y)?.alphaComponent ?? 0, 0,
                                   "Only the outer two corners are rounded")
                }
                XCTAssertEqual(bitmap.colorAt(x: outerX, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0, 1, accuracy: 0.005)
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

    private func clearedBitmap(_ source: CGImage) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.width, pixelsHigh: source.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.setBlendMode(.copy)
        graphics.cgContext.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        graphics.flushGraphics()
        return bitmap
    }

    private func renderToClearedBitmap<Content: View>(_ renderer: ImageRenderer<Content>, size: CGSize) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        renderer.render { measured, draw in
            XCTAssertEqual(measured, size)
            draw(graphics.cgContext)
        }
        graphics.flushGraphics()
        return bitmap
    }

    func testExpandedNamesRenderAndCollapsedNamesAreFullyTransparent() async throws {
        for (language, name) in [("zh-CN", "全部"), ("en", "Work projects"), ("fr", "Projets de travail"), ("zh-Hant", "工作與生活")] {
            let text = name as NSString
            let fullWidth = SideTabGeometry.expandedWidth(textWidth: max(
                text.size(withAttributes: [.font: DotistDesign.nativeFont(13, serif: true, language: language)]).width,
                text.size(withAttributes: [.font: DotistDesign.nativeFont(13, weight: .semibold, serif: true, language: language)]).width))
            for inward in [false, true] {
                for expanded in [false, true] {
                    let label = SideTabLabel(name: name, language: language, selected: true, hovered: false,
                        right: inward, width: expanded ? fullWidth : 10, fullWidth: fullWidth, textOpacity: expanded ? 1 : 0)
                    let renderer = ImageRenderer(content: label.environment(\.colorScheme, .light))
                    renderer.scale = 1
                    renderer.proposedSize = ProposedViewSize(width: expanded ? fullWidth : 10, height: SideTabGeometry.height)
                    // Preserve the OLD default-proposal/default-scale shortcut
                    // independently, so host diagnostics can still reproduce it.
                    let legacyRenderer = ImageRenderer(content: label.environment(\.colorScheme, .light))
                    let source = try XCTUnwrap(legacyRenderer.cgImage)
                    let legacy = NSBitmapImageRep(cgImage: source)
                    let sourceCopy = try clearedBitmap(source)
                    let bitmap = try renderToClearedBitmap(renderer, size: CGSize(width: expanded ? fullWidth : 10, height: SideTabGeometry.height))
                    var copiedPixels = 0
                    for y in 0..<sourceCopy.pixelsHigh { for x in 0..<sourceCopy.pixelsWide {
                        if (sourceCopy.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { copiedPixels += 1 }
                    }}
                    var legacyPixels = 0
                    for y in 0..<legacy.pixelsHigh { for x in 0..<legacy.pixelsWide {
                        if (legacy.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { legacyPixels += 1 }
                    }}
                    if !expanded && legacyPixels > 0 {
                        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/feedback-host-audit/current")
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try XCTUnwrap(legacy.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("legacy-transparent-\(language)-\(inward).png"))
                        try XCTUnwrap(sourceCopy.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("cgimage-copy-transparent-\(language)-\(inward).png"))
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("direct-render-transparent-\(language)-\(inward).png"))
                    }
                    print("COLLAPSED RASTER language=\(language), inward=\(inward), expanded=\(expanded), source=\(source.width)x\(source.height), sourceAlpha=\(source.alphaInfo.rawValue), legacyScale=\(legacyRenderer.scale), legacyPixels=\(legacyPixels), cgImageCopyPixels=\(copiedPixels), directRenderDestinationInitialized=true")
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
                    // Independent native rendering of the SAME label verifies
                    // that opacity/clipping does not leave actual foreground.
                    let fixture = NativeRenderingFixture(label.environment(\.colorScheme, .light), size: CGSize(width: expanded ? fullWidth : 10, height: SideTabGeometry.height))
                    fixture.window.isOpaque = false; fixture.window.backgroundColor = .clear
                    let native = try await fixture.capture(scale: fixture.window.backingScaleFactor)
                    var nativePixels = 0
                    for y in 0..<native.pixelsHigh { for x in 0..<native.pixelsWide {
                        if (native.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { nativePixels += 1 }
                    }}
                    if expanded {
                        XCTAssertGreaterThan(nativePixels, 10, "Native capture must actually draw visible expanded labels")
                    } else {
                        XCTAssertEqual(nativePixels, 0, "Native collapsed foreground must be absent too")
                        XCTAssertEqual(nativePixels, foregroundPixels, "Cleared direct rendering and the native view must agree")
                    }
                    print("LABEL NATIVE \(language), inward=\(inward), expanded=\(expanded), alphaPixels=\(nativePixels), canonicalPixels=\(foregroundPixels), legacyPixels=\(legacyPixels), windowVisible=\(fixture.window.isVisible)")
                    XCTAssertFalse(fixture.window.isVisible)
                    fixture.close()
                }
            }
        }
    }
}

@MainActor
final class SideTabWindowSynchronizationTests: XCTestCase {
    private func assertOrderedAbove(_ front: NSWindow, _ back: NSWindow, _ message: String = "",
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        // orderedIndex belongs to the scripting window list, which excludes
        // these panels and returns NSNotFound even while both are on screen.
        // Ask WindowServer for the visible windows in actual front-to-back order.
        let numbers = try XCTUnwrap(NSWindow.windowNumbers(options: []), file: file, line: line)
        let frontIndex = try XCTUnwrap(numbers.firstIndex(of: NSNumber(value: front.windowNumber)),
                                       "Front panel must be on screen. \(message)", file: file, line: line)
        let backIndex = try XCTUnwrap(numbers.firstIndex(of: NSNumber(value: back.windowNumber)),
                                      "Back panel must be on screen. \(message)", file: file, line: line)
        XCTAssertLessThan(frontIndex, backIndex, message, file: file, line: line)
    }

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
        var environment = SideTabsController.Environment()
        environment.visible = { _ in true }
        environment.reduceMotion = { true }
        environment.desktopEvents = false
        environment.mouse = { CGPoint(x: -10_000, y: -10_000) }
        let controller = SideTabsController(parent: parent, model: model, state: TaskPanelState(), motion: motion, environment: environment)
        defer { controller.stop() }
        let child = try XCTUnwrap(parent.childWindows?.first { $0.identifier?.rawValue == "dotist.side-tabs" })
        let content = try XCTUnwrap(child.contentView)
        try await Task.sleep(for: .milliseconds(60))
        content.layoutSubtreeIfNeeded()
        let before = model.visibleGroups.map(\.id)
        let inward = child.frame.minX >= parent.frame.minX
        for index in 0...before.count {
            let frame = SideTabGeometry.frame(panel: parent.frame, index: index, width: 10, inward: inward)
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
        let inward = false
        let tab = SideTabGeometry.frame(panel: parent.frame, index: 0, width: 10, inward: inward)
        let mouse = CGPoint(x: tab.midX, y: tab.midY)
        controller.synchronize(mouse: CGPoint(x: parent.frame.maxX - 20, y: parent.frame.minY + 20))
        try await Task.sleep(for: .milliseconds(500))
        controller.synchronize(mouse: CGPoint(x: parent.frame.maxX - 20, y: parent.frame.minY + 20))
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
        XCTAssertEqual(inward ? actual.minX : actual.maxX, parent.frame.minX, accuracy: 0.001)
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
        XCTAssertEqual(narrow.bounds.width, SideTabGeometry.selectedWidth, accuracy: 0.001)
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
        let inward = false
        controller.synchronize(mouse: CGPoint(x: parent.frame.maxX - 20, y: parent.frame.minY + 20))
        try await Task.sleep(for: .milliseconds(500))
        let point = SideTabGeometry.frame(panel: parent.frame, index: 1, width: 10, inward: inward)
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
            let frame = SideTabGeometry.frame(panel: parent.frame, index: index, width: 10, inward: inward)
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

        let allFrame = SideTabGeometry.frame(panel: parent.frame, index: 0, width: 10, inward: inward)
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

    func testInwardWindowPromotesAbovePanelAndRestoresBelowWithVisibleHitTestableEar() async throws {
        _ = NSApplication.shared
        guard let area = NSScreen.main?.visibleFrame else {
            throw XCTSkip("Native window ordering requires a WindowServer display")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wN1-inward-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let parent = DotistPanel(contentRect: CGRect(x: area.minX, y: area.midY - 220, width: 364, height: 440),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentView = NSView(frame: CGRect(origin: .zero, size: parent.frame.size))
        defer { parent.close() }
        let motion = PanelMotion(model: model, panel: parent, size: parent.frame.size, title: { "test" })
        defer { motion.stop() }
        let controller = SideTabsController(parent: parent, model: model, state: TaskPanelState(), motion: motion)
        defer { controller.stop() }
        parent.orderFront(nil)
        let child = try XCTUnwrap(parent.childWindows?.first { $0.identifier?.rawValue == "dotist.side-tabs" })
        let content = try XCTUnwrap(child.contentView)
        let container = try XCTUnwrap(parent.contentView)
        let resting = try XCTUnwrap(container.subviews.first { $0.identifier?.rawValue == "dotist.side-tabs-rest" })
        let outside = CGPoint(x: parent.frame.maxX - 20, y: parent.frame.minY + 20)
        controller.synchronize(mouse: outside)
        try await Task.sleep(for: .milliseconds(500))
        controller.synchronize(mouse: outside)
        XCTAssertTrue(parent.frame.contains(child.frame))
        XCTAssertEqual(child.frame.width, 15)
        try assertOrderedAbove(parent, child, "Resting child must be below its parent")
        XCTAssertFalse(resting.isHidden, "The in-panel ear must remain visible when its window is below")
        let ear = SideTabGeometry.frame(panel: parent.frame, index: 0, width: 10, inward: true, visibleMinX: area.minX)
        let mouse = CGPoint(x: ear.midX, y: ear.midY)
        let restingCapture = try XCTUnwrap(hitTarget(in: resting, atWindowPoint: parent.convertPoint(fromScreen: mouse)))
        XCTAssertEqual(String(describing: type(of: restingCapture)), "PointerView")
        let gap = CGPoint(x: mouse.x, y: ear.minY - 3)
        XCTAssertNil(hitTarget(in: resting, atWindowPoint: parent.convertPoint(fromScreen: gap)), "Six-point gaps must pass through to panel content")
        controller.synchronize(mouse: mouse)
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(10))
            controller.synchronize(mouse: mouse)
            XCTAssertEqual(child.frame.minX, parent.frame.minX, accuracy: 0.001)
            XCTAssertEqual(child.frame.maxY, parent.frame.maxY - 40, accuracy: 0.001)
            try assertOrderedAbove(child, parent, "Inward expansion must composite over the panel")
        }
        XCTAssertGreaterThan(child.frame.width, 10)
        XCTAssertTrue(parent.frame.contains(child.frame))
        XCTAssertTrue(resting.isHidden)
        content.layoutSubtreeIfNeeded()
        let capture = try XCTUnwrap(hitTarget(in: content, atWindowPoint: child.convertPoint(fromScreen: mouse)))
        let actual = child.convertToScreen(capture.convert(capture.bounds, to: nil))
        XCTAssertEqual(actual.minX, parent.frame.minX, accuracy: 0.001)
        XCTAssertEqual(actual.width, SideTabGeometry.expandedWidth(name: model.text("全部"), language: model.language), accuracy: 0.001)
        // Toolbar and horizontal/vertical gaps stay outside native capture.
        controller.synchronize(mouse: CGPoint(x: parent.frame.minX + 5, y: parent.frame.maxY - 20))
        XCTAssertTrue(child.ignoresMouseEvents)
        for _ in 0..<42 {
            try await Task.sleep(for: .milliseconds(10))
            controller.synchronize(mouse: outside)
            if child.frame.width > 10 { try assertOrderedAbove(child, parent) }
        }
        XCTAssertEqual(child.frame.width, 10, accuracy: 0.001)
        try assertOrderedAbove(parent, child)
        XCTAssertFalse(resting.isHidden)
        for room: CGFloat in [4, 10, 40] {
            parent.setFrameOrigin(CGPoint(x: area.minX + room, y: parent.frame.minY))
            controller.synchronize(mouse: outside)
            XCTAssertEqual(child.frame.minX, max(area.minX, parent.frame.minX - 10), accuracy: 0.001)
            XCTAssertEqual(resting.isHidden, room >= 10)
        }
        controller.stop()
        XCTAssertNil(resting.superview, "Stopping tabs must also remove the in-panel ear")
    }

    func testDraggingPanelAcrossThresholdChangesAnchorImmediatelyAtFullWidthWithoutJitter() async throws {
        _ = NSApplication.shared
        guard let area = NSScreen.main?.visibleFrame else {
            throw XCTSkip("Live panel dragging requires a WindowServer display")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wN1-threshold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let width = ([model.text("全部")] + model.visibleGroups.map { model.text($0.name) })
            .map { SideTabGeometry.expandedWidth(name: $0, language: model.language) }.max() ?? 48
        let parent = DotistPanel(contentRect: CGRect(x: area.minX + width + 100, y: area.midY - 220, width: 364, height: 440),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let motion = PanelMotion(model: model, panel: parent, size: parent.frame.size, title: { "test" })
        defer { motion.stop() }
        let controller = SideTabsController(parent: parent, model: model, state: TaskPanelState(), motion: motion)
        defer { controller.stop() }
        parent.orderFront(nil)
        let child = try XCTUnwrap(parent.childWindows?.first { $0.identifier?.rawValue == "dotist.side-tabs" })
        let mouse = CGPoint(x: parent.frame.minX - 5, y: parent.frame.maxY - 50)
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(10))
            controller.synchronize(mouse: mouse)
        }
        XCTAssertEqual(child.frame.width, width, accuracy: 0.001)
        // Every move triggers AppKit didMove. Keep the pointer on the new tab so
        // ordinary mouse-leave collapse cannot mask a forced direction collapse.
        for step in 0..<40 {
            parent.setFrameOrigin(CGPoint(x: area.minX + width + (step.isMultiple(of: 2) ? -1 : 1), y: parent.frame.minY))
            let point = CGPoint(x: parent.frame.minX + 5, y: parent.frame.maxY - 50)
            controller.synchronize(mouse: point)
            XCTAssertEqual(child.frame.minX, parent.frame.minX - 10, accuracy: 0.001,
                "Switch on the first frame and stay inward throughout the hysteresis band")
            XCTAssertEqual(child.frame.width, width, accuracy: 0.001, "Direction changes must not retract the tabs")
            try assertOrderedAbove(child, parent)
            XCTAssertFalse(child.ignoresMouseEvents)
            XCTAssertEqual(child.frame.maxY, parent.frame.maxY - 40, accuracy: 0.001)
            XCTAssertEqual(child.alphaValue, parent.alphaValue, "Never hide the child to switch modes")
            XCTAssertTrue(child.parent === parent)
            try await Task.sleep(for: .milliseconds(10))
        }
        parent.setFrameOrigin(CGPoint(x: area.minX + width + 81, y: parent.frame.minY))
        controller.synchronize(mouse: CGPoint(x: parent.frame.minX - 5, y: parent.frame.maxY - 50))
        XCTAssertEqual(child.frame.maxX, parent.frame.minX, accuracy: 0.001)
        XCTAssertEqual(child.frame.width, width, accuracy: 0.001)
        try assertOrderedAbove(parent, child)
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

        var placement = SideTabPlacement()
        func assertAttached(file: StaticString = #filePath, line: UInt = #line) {
            let frame = parent.frame
            let visibleMinX = (parent.screen ?? NSScreen.main)?.visibleFrame.minX ?? frame.minX
            let maxWidth = ([model.text("全部")] + model.visibleGroups.map { model.text($0.name) })
                .map { SideTabGeometry.expandedWidth(name: $0, language: model.language) }.max() ?? 10
            placement.update(availableSpace: frame.minX - visibleMinX, expandedWidth: maxWidth)
            let inward = placement.inward
            XCTAssertEqual(child.frame, SideTabGeometry.snapshot(panel: frame,
                fullWidths: Array(repeating: SideTabGeometry.collapsedWidth, count: model.visibleGroups.count + 1),
                progress: 0, inward: inward, visibleMinX: visibleMinX, selectedIndex: 0,
                entrance: Array(repeating: 0, count: model.visibleGroups.count + 1)).window, file: file, line: line)
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
