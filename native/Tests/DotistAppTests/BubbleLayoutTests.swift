import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

/// Real window-backed captures of the production bubble, surface and clip.
/// The ink-only pass isolates text from glass; no desktop window is ordered in.
@MainActor
final class BubbleLayoutTests: XCTestCase {
    private let area = NSRect(x: 0, y: 0, width: 1440, height: 1000)

    override func setUp() async throws {
        _ = NSApplication.shared
        print("Bubble capture environment: WindowServer displays=\(NSScreen.screens.count)")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
    }

    private func fixture(title: String, metadata: Bool, count: Int = 1) throws -> (AppModel, PanelMotion) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-bubble-layout-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        var settings = DotistSettingsPatch()
        settings.language = "en"
        _ = try store.updateSettings(settings)
        _ = try store.addTask(title: title, category: metadata ? "work" : DotistGroup.inboxID,
                              dueDate: metadata ? "2027-02-12" : nil)
        for index in 1..<count { _ = try store.addTask(title: "Other \(index)", category: DotistGroup.inboxID) }
        let model = try AppModel(store: store)
        let panel = DotistPanel(contentRect: NSRect(x: 100, y: 100, width: 364, height: 620),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { model.bubbleTitle },
                                 environment: PanelMotionTestEnvironment(area: area).environment)
        addTeardownBlock { motion.stop(); panel.close() }
        motion.toggleBubble(in: area, animated: false)
        return (model, motion)
    }

    private func capture(model: AppModel, motion: PanelMotion, width: CGFloat, reveal: CGFloat,
                         surface: Bool, scale: CGFloat = 1, scheme: ColorScheme = .light,
                         expectedOnRight: Bool? = nil) throws -> NSBitmapImageRep {
        let onRight = expectedOnRight ?? motion.bubbleOnRight
        XCTAssertEqual(motion.bubbleOnRight, onRight, "The fixture must enter the capture on the requested side")
        XCTAssertFalse(motion.hoverAnimating, "Finish the previous geometry handoff before replacing its host")
        let size = CGSize(width: width, height: 48)
        let shape = FloatingPanelShape(compact: true, transitioning: false, onRight: onRight, reveal: reveal)
        let content = FloatingBubble(model: model, motion: motion, details: BubbleContent(model: model),
            groupName: nil, contextMenu: { _, _ in }, width: width, reveal: reveal)
            .background {
                if surface {
                    FloatingSurface(opacity: 73, frost: 22, compact: true, transitioning: false,
                        onRight: onRight, size: size, reveal: reveal, color: .orange)
                }
            }
            .clipShape(shape)
            .environment(\.colorScheme, scheme)
            .environment(\.displayScale, scale)
        let host = DotistHostingView(rootView: content)
        host.sizingOptions = []
        // Local snapshot coordinates do not require relocating the native window.
        // Keep the core at its real fixture position when changing capture width.
        let frame = motion.panel.frame
        let origin = NSPoint(x: onRight ? frame.maxX - width : frame.minX, y: frame.minY)
        motion.panel.setFrame(NSRect(origin: origin, size: size), display: false)
        motion.panel.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.display()
        func containsLivePointer(_ view: NSView) -> Bool {
            String(describing: type(of: view)) == "BubblePointerView" || view.subviews.contains(where: containsLivePointer)
        }
        XCTAssertFalse(containsLivePointer(host), "Raster fixtures must not install real desktop tracking callbacks")
        let bitmap = try snapshot(host, scale: scale)
        XCTAssertEqual(motion.bubbleOnRight, onRight, "Drawing must not change the fixture's direction")
        XCTAssertFalse(motion.hoverAnimating)
        XCTAssertEqual(motion.panel.frame, NSRect(origin: origin, size: size))
        return bitmap
    }

    private func snapshot(_ host: NSView, scale: CGFloat = 1) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(host.bounds.width * scale), pixelsHigh: Int(host.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// Keep the failing first capture as the assertion's input. Additional draws
    /// are diagnostic only: a successful repaint must never turn a failure green.
    private func saveFailureDiagnostics(_ bitmap: NSBitmapImageRep, motion: PanelMotion,
                                        scale: CGFloat, label: String, output: URL, expectedOnRight: Bool) {
        func save(_ image: NSBitmapImageRep, suffix: String) {
            do {
                guard let png = image.representation(using: .png, properties: [:]) else {
                    print("Could not encode bubble diagnostic \(suffix)")
                    return
                }
                try png.write(to: output.appendingPathComponent(label + suffix + ".png"))
            } catch { print("Could not save bubble diagnostic \(suffix): \(error)") }
        }
        save(bitmap, suffix: "-failed-first-capture")
        guard let host = motion.panel.contentView else { return }
        func tree(_ view: NSView, depth: Int = 0) -> [String] {
            let layer = view.layer.map {
                "layerFrame=\($0.frame) layerBounds=\($0.bounds) contents=\($0.contents != nil) needsDisplay=\($0.needsDisplay()) opacity=\($0.opacity) hidden=\($0.isHidden) transform=\($0.transform)"
            } ?? "no layer"
            let line = "\(String(repeating: "  ", count: depth))\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) hidden=\(view.isHiddenOrHasHiddenAncestor) alpha=\(view.alphaValue) needsDisplay=\(view.needsDisplay) needsLayout=\(view.needsLayout) windowAttached=\(view.window === motion.panel) \(layer)"
            return [line] + view.subviews.flatMap { tree($0, depth: depth + 1) }
        }
        let core = CGRect(x: expectedOnRight ? bitmap.size.width - 48 : 0, y: 0, width: 48, height: 48)
        let actualCore = CGRect(x: motion.bubbleOnRight ? bitmap.size.width - 48 : 0, y: 0, width: 48, height: 48)
        var diagnostics = ["\(label): displays=\(NSScreen.screens.count) scale=\(scale) backingScale=\(motion.panel.backingScaleFactor) panel=\(motion.panel.frame) visible=\(motion.panel.isVisible)",
                           "expectedOnRight=\(expectedOnRight) actualOnRight=\(motion.bubbleOnRight) hovering=\(motion.hovering) hoverAnimating=\(motion.hoverAnimating) fixtureButtons=\(motion.environment.pressedMouseButtons()) fixturePointer=\(motion.environment.mouseLocation())",
                           "First capture core ink=\(String(describing: ink(bitmap, in: core))) whole ink=\(String(describing: ink(bitmap, in: CGRect(origin: .zero, size: bitmap.size))))",
                           "Actual-direction core ink=\(String(describing: ink(bitmap, in: actualCore)))",
                           "Before diagnostic drawing:"] + tree(host)
        func nativeTextViews(_ view: NSView) -> [NSView] {
            (String(describing: type(of: view)) == "BubbleTextView" ? [view] : [])
                + view.subviews.flatMap(nativeTextViews)
        }
        for (index, view) in nativeTextViews(host).enumerated() where !view.bounds.isEmpty {
            do {
                let native = try snapshot(view, scale: scale)
                save(native, suffix: "-native-\(index)")
                diagnostics.append("Native view \(index) isolated ink=\(String(describing: ink(native, in: view.bounds)))")
            } catch { diagnostics.append("Native view \(index) snapshot failed: \(error)") }
        }
        // Distinguish cached host composition from a native glyph drawing failure.
        // This is deliberately after saving the first frame and is never retried
        // by the test's assertion path.
        host.display()
        do {
            let displayed = try snapshot(host, scale: scale)
            save(displayed, suffix: "-after-display")
            diagnostics.append("After explicit display core ink=\(String(describing: ink(displayed, in: core)))")
        }
        catch { diagnostics.append("Diagnostic host snapshot failed: \(error)") }
        diagnostics += ["After diagnostic drawing:"] + tree(host)
        let report = diagnostics.joined(separator: "\n")
        print("Bubble capture failure diagnostics: \(output.path)/\(label)-diagnostics.txt\n\(report)")
        do {
            try report.write(to: output.appendingPathComponent(label + "-diagnostics.txt"), atomically: true, encoding: .utf8)
        } catch { print("Could not save bubble diagnostics: \(error)") }
    }

    private func ink(_ bitmap: NSBitmapImageRep, in rect: CGRect, threshold: CGFloat = 0.1, onSurface: Bool = false) -> CGRect? {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        var bounds = CGRect.null
        for y in max(0, Int(rect.minY * scale))..<min(bitmap.pixelsHigh, Int(rect.maxY * scale)) {
            for x in max(0, Int(rect.minX * scale))..<min(bitmap.pixelsWide, Int(rect.maxX * scale)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > threshold && (!onSurface || max(color.redComponent, color.greenComponent, color.blueComponent) < 0.65) {
                    bounds = bounds.union(CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale))
                }
            }
        }
        return bounds.isNull ? nil : bounds
    }

    func testWindowBackedBubbleLayoutMatrix() throws {
        try assertLayoutMatrix(scale: 1)
        try assertLayoutMatrix(scale: 2)
    }

    private func assertLayoutMatrix(scale: CGFloat) throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOTIST_BUBBLE_ARTIFACTS"] ?? "/private/tmp/dotist-bubble-layout")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var rows = ["title,metadata,onRight,reveal,width,measuredTextWidth,coreInk,textInk"]
        defer {
            try? rows.joined(separator: "\n").write(to: output.appendingPathComponent("measurements-\(scale)x.csv"), atomically: true, encoding: .utf8)
            print("Bubble AppKit captures and measurements: \(output.path)")
        }
        for long in [false, true] {
            for metadata in [false, true] {
                let (model, motion) = try fixture(title: long ? "Inbox — prepare the very long project handoff and review all pending tasks 中文" : "Inbox", metadata: metadata)
                let details = BubbleContent(model: model)
                for onRight in [false, true] {
                    motion.bubbleOnRight = onRight
                    let coreX = onRight ? motion.panel.frame.maxX - 24 : motion.panel.frame.minX + 24
                    motion.setHover(true, in: area)
                    motion.finishHover(true)
                    XCTAssertFalse(motion.hoverAnimating)
                    XCTAssertEqual(motion.bubbleOnRight, onRight)
                    XCTAssertEqual(onRight ? motion.panel.frame.maxX - 24 : motion.panel.frame.minX + 24, coreX, accuracy: 0.01)
                    let width = motion.panel.frame.width
                    let measured = details.textWidth(language: model.language)
                    XCTAssertEqual(width, min(440, ceil(78 + measured)), accuracy: 1,
                                   "Short strips must fit their actual content without a fixed 250pt floor")
                    for reveal in [CGFloat(0), 0.3, 0.6, 1] {
                        let label = "\(long ? "long" : "short")-\(metadata ? "two-line" : "one-line")-\(onRight ? "right" : "left")-\(reveal)@\(scale)x"
                        let bitmap = try capture(model: model, motion: motion, width: width, reveal: reveal,
                                                 surface: false, scale: scale, expectedOnRight: onRight)
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(label + "-ink.png"))
                        let core = CGRect(x: onRight ? width - 48 : 0, y: 0, width: 48, height: 48)
                        let textRect = CGRect(x: onRight ? 0 : 48, y: 0, width: width - 48, height: 48)
                        let measuredCoreInk = ink(bitmap, in: core)
                        let textInk = ink(bitmap, in: textRect, threshold: max(0.02, reveal * 0.1))
                        rows.append([long ? "long" : "short", "\(metadata)", "\(onRight)", "\(reveal)", "\(width)", "\(measured)", "\(String(describing: measuredCoreInk))", "\(String(describing: textInk))"]
                            .map { "\"\($0)\"" }.joined(separator: ","))
                        if measuredCoreInk == nil || (reveal == 1 && textInk == nil) {
                            saveFailureDiagnostics(bitmap, motion: motion, scale: scale, label: label, output: output, expectedOnRight: onRight)
                        }
                        let coreInk = try XCTUnwrap(measuredCoreInk, label)
                        XCTAssertEqual(coreInk.midX, core.midX, accuracy: 0.5, label)
                        XCTAssertEqual(coreInk.midY, 24, accuracy: 0.5, label)
                        if reveal == 0 { XCTAssertNil(textInk, label) }
                        if reveal == 1 {
                            let textInk = try XCTUnwrap(textInk, label)
                            XCTAssertEqual(textInk.midY, coreInk.midY, accuracy: 0.5, "Whole text block should be visually centered: \(label)")
                            XCTAssertEqual(textInk.minX, onRight ? 12 : 66, accuracy: 2, "Text stays left aligned on both sides: \(label)")
                            if metadata {
                                let titleInk = try XCTUnwrap(ink(bitmap, in: CGRect(x: textRect.minX, y: 0, width: textRect.width, height: 24)))
                                let metadataInk = try XCTUnwrap(ink(bitmap, in: CGRect(x: textRect.minX, y: 24, width: textRect.width, height: 24)))
                                XCTAssertEqual(titleInk.minX, metadataInk.minX, accuracy: 1, label)
                            }
                        }
                        let composite = try capture(model: model, motion: motion, width: width, reveal: reveal,
                                                    surface: true, scale: scale, expectedOnRight: onRight)
                        try XCTUnwrap(composite.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(label + ".png"))
                        if reveal == 1 {
                            if ink(composite, in: textRect, onSurface: true) == nil || ink(composite, in: core, onSurface: true) == nil {
                                saveFailureDiagnostics(composite, motion: motion, scale: scale, label: label + "-composite", output: output, expectedOnRight: onRight)
                            }
                            let visibleText = try XCTUnwrap(ink(composite, in: textRect, onSurface: true))
                            let visibleCount = try XCTUnwrap(ink(composite, in: core, onSurface: true))
                            XCTAssertEqual(visibleText.midY, 24, accuracy: 0.5, "Final composite text axis: \(label)")
                            XCTAssertEqual(visibleCount.midY, 24, accuracy: 0.5, "Final composite count axis: \(label)")
                            XCTAssertEqual(visibleText.minX, onRight ? 12 : 66, accuracy: 2, label)
                        }
                        // Expected production silhouette, independently rasterized, with
                        // one pixel tolerance for native continuous-corner antialiasing.
                        let maskRenderer = ImageRenderer(content: Color.white.clipShape(FloatingPanelShape(compact: true,
                            transitioning: false, onRight: onRight, reveal: reveal)).frame(width: width, height: 48))
                        maskRenderer.scale = scale
                        let mask = NSBitmapImageRep(cgImage: try XCTUnwrap(maskRenderer.cgImage))
                        var exteriorAlpha: CGFloat = 0
                        for y in 0..<composite.pixelsHigh {
                            for x in 0..<composite.pixelsWide {
                                let boundary = (-1...1).contains { dy in (-1...1).contains { dx in
                                    let mx = x + dx, my = y + dy
                                    return mx >= 0 && my >= 0 && mx < mask.pixelsWide && my < mask.pixelsHigh
                                        && (mask.colorAt(x: mx, y: my)?.alphaComponent ?? 0) > 0
                                } }
                                if !boundary { exteriorAlpha = max(exteriorAlpha, composite.colorAt(x: x, y: y)?.alphaComponent ?? 0) }
                            }
                        }
                        XCTAssertEqual(exteriorAlpha, 0, "No offset plate outside the real window-backed capsule: \(label)")
                        XCTAssertFalse(motion.panel.hasShadow, "Compact panels have no window shadow")
                        XCTAssertTrue(motion.panel.childWindows?.isEmpty ?? true)
                    }
                    motion.setHover(false, in: area)
                    motion.finishHover(false)
                    XCTAssertFalse(motion.hoverAnimating, "Retraction must settle before the next matrix side")
                    XCTAssertEqual(motion.panel.frame.width, 48)
                }
            }
        }
    }

    func testFullFloatingPanelHostRetractsWithoutLeakingItsHiddenMainContent() async throws {
        for onRight in [false, true] {
            let (model, motion) = try fixture(title: "Inbox", metadata: true)
            motion.bubbleOnRight = onRight
            let host = DotistHostingView(rootView: FloatingPanelView(model: model, motion: motion,
                colorState: TaskPanelState(), title: model.bubbleTitle, remaining: model.remainingCount,
                total: model.topLevelTasks.count, groupName: nil, contextMenu: { _, _ in }, content: Color.red)
                .environment(\.colorScheme, .light))
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            motion.panel.contentView = host
            for active in [false, true, false] {
                if active != motion.hovering {
                    let finished = expectation(description: "The production reveal/retraction completion fires")
                    motion.environment.hoverDidFinish = { completed in
                        if completed == active { finished.fulfill() }
                    }
                    motion.setHover(active, in: area)
                    host.layoutSubtreeIfNeeded()
                    await fulfillment(of: [finished], timeout: 2)
                    motion.environment.hoverDidFinish = { _ in }
                }
                host.layoutSubtreeIfNeeded()
                let bitmap = try snapshot(host)
                XCTAssertEqual(motion.panel.frame.width, active ? 180 : 48, accuracy: 1)
                XCTAssertFalse(motion.hoverAnimating)
                var redPixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if color.alphaComponent > 0.1 && color.redComponent > 0.8 && color.greenComponent < 0.2 { redPixels += 1 }
                    }
                }
                XCTAssertEqual(redPixels, 0, "The full-size main content must remain invisible under the bubble")
                if active {
                    let rect = CGRect(x: onRight ? 0 : 48, y: 0, width: host.bounds.width - 48, height: 48)
                    let text = try XCTUnwrap(ink(bitmap, in: rect, onSurface: true))
                    XCTAssertEqual(text.midY, 24, accuracy: 0.5)
                    XCTAssertEqual(text.minX, onRight ? 12 : 66, accuracy: 2)
                }
                XCTAssertFalse(motion.panel.hasShadow, "Compact panels have no window shadow")
                XCTAssertTrue(motion.panel.childWindows?.isEmpty ?? true)
            }
        }
    }

    func testNativeCountKeepsItsInkAxisAndContrastForBothAppearances() throws {
        for count in [1, 12, 51] {
            let (model, motion) = try fixture(title: "中文任务", metadata: false, count: count)
            motion.bubbleOnRight = false
            for scheme in [ColorScheme.light, .dark] {
                for scale in [CGFloat(1), 2] {
                    let bitmap = try capture(model: model, motion: motion, width: 180, reveal: 1,
                        surface: false, scale: scale, scheme: scheme)
                    let bounds = try XCTUnwrap(ink(bitmap, in: CGRect(x: 0, y: 0, width: 48, height: 48)))
                    XCTAssertEqual(bounds.midX, 24, accuracy: 0.5)
                    XCTAssertEqual(bounds.midY, 24, accuracy: 0.5)
                    var brightestAlpha: CGFloat = 0
                    var luminance: CGFloat = 0
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<Int(48 * scale) {
                            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            if color.alphaComponent > brightestAlpha {
                                brightestAlpha = color.alphaComponent
                                luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                            }
                        }
                    }
                    XCTAssertGreaterThan(brightestAlpha, 0.9)
                    if scheme == .dark { XCTAssertGreaterThan(luminance, 0.8) }
                    else { XCTAssertLessThan(luminance, 0.2) }
                }
            }
        }
    }

    func testFiftyOneRemainingKeepsShortStripsContentSizedAndLeftAligned() throws {
        let (model, motion) = try fixture(title: "Inbox", metadata: false, count: 51)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOTIST_BUBBLE_ARTIFACTS"] ?? "/private/tmp/dotist-bubble-layout")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let details = BubbleContent(model: model)
        XCTAssertEqual(details.remaining, 51)
        let expectedWidth = ceil(78 + details.textWidth(language: model.language))
        XCTAssertLessThan(expectedWidth, 250)
        for onRight in [false, true] {
            motion.bubbleOnRight = onRight
            let coreX = onRight ? motion.panel.frame.maxX - 24 : motion.panel.frame.minX + 24
            motion.setHover(true, in: area)
            motion.finishHover(true)
            XCTAssertEqual(motion.panel.frame.width, expectedWidth)
            XCTAssertEqual(onRight ? motion.panel.frame.maxX - 24 : motion.panel.frame.minX + 24, coreX)
            for scale in [CGFloat(1), 2] {
                let bitmap = try capture(model: model, motion: motion, width: expectedWidth, reveal: 1,
                                         surface: false, scale: scale, expectedOnRight: onRight)
                let label = "count-51-short-\(onRight ? "right" : "left")@\(scale)x"
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(label + "-ink.png"))
                let core = CGRect(x: onRight ? expectedWidth - 48 : 0, y: 0, width: 48, height: 48)
                let text = CGRect(x: onRight ? 0 : 48, y: 0, width: expectedWidth - 48, height: 48)
                let coreInk = try XCTUnwrap(ink(bitmap, in: core))
                let textInk = try XCTUnwrap(ink(bitmap, in: text))
                XCTAssertEqual(coreInk.midX, core.midX, accuracy: 0.5)
                XCTAssertEqual(coreInk.midY, 24, accuracy: 0.5)
                XCTAssertEqual(textInk.minX, onRight ? 12 : 66, accuracy: 2)
                XCTAssertEqual(textInk.midY, coreInk.midY, accuracy: 0.5)
                let composite = try capture(model: model, motion: motion, width: expectedWidth, reveal: 1,
                                            surface: true, scale: scale, expectedOnRight: onRight)
                try XCTUnwrap(composite.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(label + ".png"))
                let visibleText = try XCTUnwrap(ink(composite, in: text, onSurface: true))
                XCTAssertEqual(visibleText.minX, onRight ? 12 : 66, accuracy: 2)
                XCTAssertEqual(visibleText.midY, 24, accuracy: 0.5)
            }
            motion.setHover(false, in: area)
            motion.finishHover(false)
            XCTAssertFalse(motion.hoverAnimating)
            XCTAssertEqual(motion.panel.frame.width, 48)
        }
    }
}
