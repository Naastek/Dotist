import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class PanelShadowTests: XCTestCase {
    private func model() throws -> AppModel {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-shadow-wN3-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
    }

    func testAccessibleHoverIntermediateWidthsHaveNoPixelsOutsideTheirOnlySurface() throws {
        // Rasterizers omit compositor-only glass. Exercise the production opaque
        // accessibility branch so these positive coverage/shape assertions stay
        // meaningful at both display scales and on both sides of the screen.
        // The SDK backing environment key is injected only inside this fixture.
        for reveal in [CGFloat(0), 0.3, 0.6, 1] {
            for onRight in [false, true] {
                for scale in [CGFloat(1), 2] {
                    for scheme in [ColorScheme.light, .dark] {
                        let size = CGSize(width: 280, height: 48)
                        let surfaceWidth = 48 + (size.width - 48) * reveal
                        let x = onRight ? size.width - surfaceWidth : 0
                        let content = FloatingSurface(opacity: 73, frost: 22, compact: true,
                            transitioning: false, onRight: onRight, size: size, reveal: reveal, color: .orange)
                            .frame(width: size.width, height: size.height).padding(12)
                            .environment(\.colorScheme, scheme)
                            .environment(\.displayScale, scale)
                            .environment(\._accessibilityReduceTransparency, true)
                        let renderer = ImageRenderer(content: content)
                        renderer.scale = scale
                        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                        // Rasterize the expected shape at the same display scale;
                        // continuous corners use a different native rasterization
                        // from testing CGPath.contains at pixel centers.
                        let maskRenderer = ImageRenderer(content: Color.white
                            .clipShape(FloatingPanelShape(compact: true, transitioning: false, onRight: onRight, reveal: reveal))
                            .frame(width: size.width, height: size.height).padding(12)
                            .environment(\.displayScale, scale))
                        maskRenderer.scale = scale
                        let mask = NSBitmapImageRep(cgImage: try XCTUnwrap(maskRenderer.cgImage))
                        var exteriorPixels = 0
                        var maximumExteriorAlpha: CGFloat = 0
                        var exteriorPoint = CGPoint.zero
                        for py in 0..<bitmap.pixelsHigh {
                            for px in 0..<bitmap.pixelsWide {
                                let point = CGPoint(x: (CGFloat(px) + 0.5) / scale, y: (CGFloat(py) + 0.5) / scale)
                                // Partial alpha belongs to the antialiased boundary.
                                guard mask.colorAt(x: px, y: py)?.alphaComponent == 0 else { continue }
                                exteriorPixels += 1
                                let alpha = try XCTUnwrap(bitmap.colorAt(x: px, y: py)).alphaComponent
                                if alpha > maximumExteriorAlpha { maximumExteriorAlpha = alpha; exteriorPoint = point }
                            }
                        }
                        XCTAssertGreaterThan(exteriorPixels, 500)
                        XCTAssertEqual(maximumExteriorAlpha, 0,
                            "Second surface outside capsule: reveal=\(reveal), side=\(onRight), scale=\(scale), point=\(exteriorPoint)")
                        // Compare the interior with a single isolated production
                        // material. A second filled layer would change its alpha/tint.
                        let reference = ImageRenderer(content: FloatingPanelMaterial(opacity: 73, frost: 22, compact: true, color: .orange)
                            .frame(width: surfaceWidth, height: 48)
                            .environment(\.colorScheme, scheme)
                            .environment(\.displayScale, scale)
                            .environment(\._accessibilityReduceTransparency, true))
                        reference.scale = scale
                        let referenceBitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(reference.cgImage))
                        for fraction in [CGFloat(0.25), 0.5, 0.75] {
                            let px = Int((12 + x + surfaceWidth * fraction) * scale)
                            let expected = try XCTUnwrap(referenceBitmap.colorAt(x: Int(surfaceWidth * fraction * scale), y: Int(24 * scale))?.usingColorSpace(.sRGB))
                            let actual = try XCTUnwrap(bitmap.colorAt(x: px, y: Int(36 * scale))?.usingColorSpace(.sRGB))
                            XCTAssertGreaterThan(actual.alphaComponent, 0.05)
                            XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.01)
                            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.02)
                            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.02)
                            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.02)
                        }
                    }
                }
            }
        }
    }

    func testAccessibleWindowBackedHoverSurfaceKeepsUnusedWindowAreaTransparentAfterResizes() async throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 48),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        defer { panel.close() }
        let evidence = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/integration-install/pixel-evidence/panel-shadow")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        var pixelEvidence = ["onRight,width,reveal,scale,x,y,red,green,blue,alpha,maskAlpha,neighborMaskMax"]
        let host = DotistHostingView(rootView: FloatingSurface(opacity: 73, frost: 22,
            compact: true, transitioning: false, onRight: true, size: CGSize(width: 280, height: 48), reveal: 0, color: .orange)
            .environment(\._accessibilityReduceTransparency, true))
        host.sizingOptions = []
        panel.contentView = host
        let referencePanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 48),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        referencePanel.isReleasedWhenClosed = false; referencePanel.isOpaque = false
        referencePanel.backgroundColor = .clear; referencePanel.hasShadow = false
        defer { referencePanel.close() }
        let referenceHost = DotistHostingView(rootView: AnyView(Color.clear))
        referenceHost.sizingOptions = []
        referencePanel.contentView = referenceHost
        for onRight in [false, true] {
            for (width, reveal) in [(CGFloat(280), CGFloat(0)), (320, 0.3), (250, 0.6), (280, 1), (48, 0)] {
                let size = CGSize(width: width, height: 48)
                panel.setFrame(NSRect(origin: .zero, size: size), display: false)
                host.frame = CGRect(origin: .zero, size: size)
                host.rootView = FloatingSurface(opacity: 73, frost: 22, compact: true,
                    transitioning: false, onRight: onRight, size: size, reveal: reveal, color: .orange)
                    .environment(\._accessibilityReduceTransparency, true)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(35))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / width
                let surfaceWidth = 48 + (width - 48) * reveal
                let minX = onRight ? width - surfaceWidth : 0
                // Capture the independent shape through the same window-backed
                // raster path and scale as the production surface. A separately
                // rendered ImageRenderer mask has different corner coverage.
                referencePanel.setFrame(NSRect(origin: .zero, size: size), display: false)
                referenceHost.frame = CGRect(origin: .zero, size: size)
                referenceHost.rootView = AnyView(FloatingPanelShape(compact: true, transitioning: false,
                    onRight: onRight, reveal: reveal).fill(Color.white).frame(width: size.width, height: size.height))
                referenceHost.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(35))
                referenceHost.layoutSubtreeIfNeeded()
                let mask = try XCTUnwrap(referenceHost.bitmapImageRepForCachingDisplay(in: referenceHost.bounds))
                try XCTUnwrap(mask.bitmapData).initialize(repeating: 0, count: mask.bytesPerRow * mask.pixelsHigh)
                referenceHost.cacheDisplay(in: referenceHost.bounds, to: mask)
                XCTAssertEqual(mask.pixelsWide, bitmap.pixelsWide)
                XCTAssertEqual(mask.pixelsHigh, bitmap.pixelsHigh)
                let captureName = "right-\(onRight)-width-\(Int(width))-reveal-\(reveal)"
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: evidence.appendingPathComponent(captureName + "-actual.png"))
                try XCTUnwrap(mask.representation(using: .png, properties: [:])).write(to: evidence.appendingPathComponent(captureName + "-mask.png"))
                var maximumExteriorAlpha: CGFloat = 0
                var plateControlAlpha: CGFloat = 0
                let plateX = ((bitmap.pixelsWide - 6) / 3) * 3
                let plateY = ((bitmap.pixelsHigh / 2) / 3) * 3
                let control = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
                    pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                try XCTUnwrap(control.bitmapData).initialize(repeating: 0, count: control.bytesPerRow * control.pixelsHigh)
                for y in plateY..<min(plateY + 6, control.pixelsHigh) {
                    for x in plateX..<min(plateX + 6, control.pixelsWide) {
                        control.setColor(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1), atX: x, y: y)
                    }
                }
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                        // cacheDisplay and ImageRenderer may differ by one
                        // antialias pixel at a native continuous corner.
                        let boundary = (-1...1).contains { dy in
                            (-1...1).contains { dx in
                                let mx = x + dx, my = y + dy
                                return mx >= 0 && my >= 0 && mx < mask.pixelsWide && my < mask.pixelsHigh
                                    && (mask.colorAt(x: mx, y: my)?.alphaComponent ?? 0) > 0
                            }
                        }
                        if !boundary {
                            plateControlAlpha = max(plateControlAlpha, try XCTUnwrap(control.colorAt(x: x, y: y)).alphaComponent)
                            let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            maximumExteriorAlpha = max(maximumExteriorAlpha, pixel.alphaComponent)
                            if pixel.alphaComponent > 0 {
                                let maskAlpha = mask.colorAt(x: x, y: y)?.alphaComponent ?? 0
                                let neighborMax = (-1...1).flatMap { dy in (-1...1).map { dx -> CGFloat in
                                    let mx = x + dx, my = y + dy
                                    guard mx >= 0, my >= 0, mx < mask.pixelsWide, my < mask.pixelsHigh else { return 0 }
                                    return mask.colorAt(x: mx, y: my)?.alphaComponent ?? 0
                                } }.max() ?? 0
                                pixelEvidence.append("\(onRight),\(width),\(reveal),\(scale),\(x),\(y),\(pixel.redComponent),\(pixel.greenComponent),\(pixel.blueComponent),\(pixel.alphaComponent),\(maskAlpha),\(neighborMax)")
                            }
                        }
                    }
                }
                if !onRight && width == 280 && reveal == 0 {
                    XCTAssertEqual(plateControlAlpha, 1, "The same exterior detector must reject an injected opaque plate")
                }
                XCTAssertEqual(maximumExteriorAlpha, 0, "Window-backed compositing must not add an offset plate at reveal=\(reveal)")
                XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: Int((minX + surfaceWidth / 2) * scale), y: Int(24 * scale))).alphaComponent, 0.05)
                XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
            }
        }
        try pixelEvidence.joined(separator: "\n").write(to: evidence.appendingPathComponent("exterior-pixels.csv"), atomically: true, encoding: .utf8)
    }

    func testPureTranslationDoesNotRenderShadowAgain() throws {
        let model = try model()
        let frame = NSRect(x: 100, y: 100, width: 364, height: 620)
        let panel = DotistPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let motion = PanelMotion(model: model, panel: panel, size: frame.size, title: { "" },
                                 environment: PanelMotionTestEnvironment().environment)
        defer { motion.stop(); panel.close() }
        let shadow = try XCTUnwrap(motion.shadowController)
        let ambient = try XCTUnwrap(shadow.window.contentView?.layer?.sublayers?.first)
        ambient.shadowRadius = 123
        panel.setFrameOrigin(NSPoint(x: 180, y: 160))
        shadow.synchronize()
        XCTAssertEqual(ambient.shadowRadius, 123)
        panel.setFrame(NSRect(x: 180, y: 160, width: 400, height: 620), display: false)
        shadow.synchronize()
        XCTAssertNotEqual(ambient.shadowRadius, 123)
    }

    func testTaskPanelStateAndOtherPanelsUseExpectedShadowChildren() throws {
        let model = try model()
        let frame = NSRect(x: 100, y: 100, width: 364, height: 620)
        let panel = DotistPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let motion = PanelMotion(model: model, panel: panel, size: frame.size, title: { "" },
                                 environment: PanelMotionTestEnvironment().environment)
        defer { motion.stop(); panel.close() }
        let group = GroupPanelController(model: model, groupID: "work", near: frame,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, didClose: { _ in })
        defer { group.close() }
        XCTAssertFalse(try XCTUnwrap(group.window).hasShadow)
        XCTAssertFalse(try XCTUnwrap(group.window).isOpaque)
        for size in [NSSize(width: 560, height: 112), NSSize(width: 600, height: 372)] {
            let quick = QuickPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            quick.isReleasedWhenClosed = false
            XCTAssertFalse(quick.hasShadow)
            quick.close()
        }
        let area = NSRect(x: 0, y: 0, width: 1440, height: 1000)
        for _ in 0..<3 {
            motion.toggleBubble(in: area, animated: false)
            motion.setHover(true, in: area)
            XCTAssertFalse(panel.hasShadow)
            motion.finishHover(true)
            XCTAssertFalse(panel.hasShadow)
            panel.setFrameOrigin(NSPoint(x: 20, y: 20))
            _ = motion.finishBubbleMove()
            motion.setHover(false, in: area)
            XCTAssertFalse(panel.hasShadow)
            motion.finishHover(false)
            motion.refreshShadow()
            XCTAssertFalse(panel.hasShadow)
            XCTAssertEqual(panel.childWindows?.count, 1)
            XCTAssertEqual(group.window?.childWindows?.count, 1)
        }
    }

    func testMainAndGroupTaskPanelCreationDisableWindowShadowBeforeMotionIsInstalled() throws {
        // Launching the app delegate opens windows, reads real data and installs
        // global shortcuts. Check only its task-panel construction assignments.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for file in ["DotistApp.swift", "TaskPanel.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/DotistApp/" + file), encoding: .utf8)
            let creation = try XCTUnwrap(source.range(of: "panel = DotistPanel("))
            let motion = try XCTUnwrap(source.range(of: "motion = PanelMotion(", range: creation.upperBound..<source.endIndex))
            let setup = source[creation.lowerBound..<motion.lowerBound]
            XCTAssertTrue(setup.contains("panel.hasShadow = false"), file)
            XCTAssertFalse(setup.contains("panel.hasShadow = true"), file)
        }
    }

    func testGroupPanelShadowStaysDisabledThroughMotionHoverCancellationAndReduceMotion() throws {
        let model = try model()
        for reduceMotion in [false, true] {
            let input = PanelMotionTestEnvironment()
            let group = GroupPanelController(model: model, groupID: "work",
                near: NSRect(x: 100, y: 100, width: 364, height: 620),
                showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, didClose: { _ in })
            let panel = try XCTUnwrap(group.window as? DotistPanel)
            let motion = try XCTUnwrap(group.motion)
            defer { group.close() }
            motion.environment = input.environment
            if reduceMotion { motion.environment.frameAnimationDuration = { _ in 0 } }
            func check(_ phase: String) {
                XCTAssertFalse(panel.hasShadow, "reduceMotion=\(reduceMotion), \(phase)")
                XCTAssertFalse(panel.isVisible)
                XCTAssertEqual(panel.childWindows?.count ?? 0, motion.shadowController == nil ? 0 : 1)
            }
            check("initial expanded")
            for compact in [true, false] {
                motion.toggleBubble(in: input.area)
                check("frame start")
                XCTAssertEqual(try input.frameAnimationDuration(for: panel), reduceMotion ? 0 : (compact ? 0.28 : 0.34))
                for progress in [CGFloat(0.25), 0.5, 0.75] {
                    try input.sampleFrameAnimation(for: panel, progress: progress)
                    check("frame middle")
                }
                try input.completeFrameAnimation(for: panel)
                check("frame end")
                if compact {
                    for hover in [true, false] {
                        motion.setHover(hover, in: input.area)
                        check("hover start/middle")
                        XCTAssertTrue(motion.hoverAnimating)
                        motion.finishHover(hover)
                        check("hover end")
                    }
                }
            }
            // Cancel expansion after a genuine intermediate-size sample.
            motion.toggleBubble(in: input.area, animated: false)
            motion.toggleBubble(in: input.area)
            try input.sampleFrameAnimation(for: panel, progress: 0.5)
            let frame = panel.frame
            motion.stop()
            check("cancelled expansion")
            try input.completeFrameAnimation(for: panel)
            motion.refreshShadow()
            check("late completion")
            XCTAssertEqual(panel.frame, frame)
        }
    }

    func testHiddenPanelFrameRequestsCompleteSynchronouslyWithShadowChild() throws {
        let model = try model()
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 1000)
        let frame = NSRect(x: area.minX + 20, y: area.minY + 20, width: min(364, area.width), height: min(620, area.height))
        let panel = DotistPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let input = PanelMotionTestEnvironment(area: area, frameAnimations: .native)
        var environment = input.environment
        var durationRequests = 0
        environment.frameAnimationDuration = { compact in
            durationRequests += 1
            return compact ? 0.28 : 0.34
        }
        XCTAssertNil(environment.animateFrame, "This test must exercise production visibility rules")
        var remembered: [NSRect] = []
        let motion = PanelMotion(model: model, panel: panel, size: frame.size, title: { "" },
                                 environment: environment, rememberFrame: { remembered.append($0) })
        defer { motion.stop(); panel.close() }
        for compact in [true, false] {
            XCTAssertFalse(panel.isVisible)
            // animated=true is intentional: hidden windows still complete now,
            // without requesting a zero or nonzero native animation.
            motion.toggleBubble(in: area, animated: true)
            XCTAssertFalse(motion.animationInProgress)
            XCTAssertEqual(motion.bubble, compact)
            XCTAssertEqual(panel.frame.size, compact ? NSSize(width: 48, height: 48) : frame.size)
            XCTAssertEqual(panel.styleMask.contains(.resizable), !compact)
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(panel.hasShadow)
            XCTAssertEqual(panel.childWindows?.count, 1)
            XCTAssertEqual(durationRequests, 0, "Do not queue native animations for hidden windows")
            XCTAssertEqual(input.pendingFrameAnimationCount, 0)
        }
        XCTAssertEqual(remembered.count, 1, "Synchronous expansion must still finish its lifecycle handoff")
        XCTAssertEqual(remembered.first?.size, frame.size)
    }

    func testControlledFrameAnimationsKeepWindowShadowDisabledAtIntermediateSizes() throws {
        let model = try model()
        let input = PanelMotionTestEnvironment()
        let frame = NSRect(x: 100, y: 100, width: 364, height: 620)
        let panel = DotistPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let motion = PanelMotion(model: model, panel: panel, size: frame.size, title: { "" }, environment: input.environment)
        defer { motion.stop(); panel.close() }
        XCTAssertFalse(panel.hasShadow)
        for compact in [true, false] {
            XCTAssertFalse(panel.isVisible)
            XCTAssertNotNil(motion.environment.animateFrame)
            motion.toggleBubble(in: input.area)
            XCTAssertTrue(motion.animationInProgress)
            XCTAssertEqual(input.pendingFrameAnimationCount, 1)
            XCTAssertFalse(panel.hasShadow, "Animation start")
            for progress in [CGFloat(0.25), 0.5, 0.75] {
                try input.sampleFrameAnimation(for: panel, progress: progress)
                XCTAssertTrue(motion.animationInProgress)
                XCTAssertFalse(panel.hasShadow)
                motion.refreshShadow()
                XCTAssertFalse(panel.hasShadow)
                XCTAssertEqual(panel.childWindows?.count, 1)
            }
            try input.completeFrameAnimation(for: panel)
            XCTAssertFalse(motion.animationInProgress)
            XCTAssertEqual(motion.bubble, compact)
            XCTAssertEqual(panel.frame.size, compact ? NSSize(width: 48, height: 48) : frame.size)
            XCTAssertFalse(panel.hasShadow)
            XCTAssertEqual(panel.childWindows?.count, 1)
        }
        XCTAssertEqual(input.pendingFrameAnimationCount, 0)
    }

    func testGlassDebugChangesDoNotOverrideTaskPanelShadow() throws {
        let model = try model()
        let input = PanelMotionTestEnvironment()
        let panel = DotistPanel(contentRect: NSRect(x: 100, y: 100, width: 364, height: 620),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let debug = GlassDebugState.shared
        let original = debug.parameters
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" }, environment: input.environment)
        defer { debug.parameters = original; motion.stop(); panel.close() }
        debug.parameters.hasShadow = false
        XCTAssertFalse(panel.hasShadow)
        motion.toggleBubble(in: input.area, animated: false)
        XCTAssertFalse(panel.hasShadow)
        debug.parameters.hasShadow = true
        XCTAssertFalse(panel.hasShadow)
        motion.toggleBubble(in: input.area, animated: false)
        XCTAssertFalse(panel.hasShadow)
    }

    func testQueuedHoverToggleAndStoppedCompletionPreserveShadowPolicy() throws {
        let model = try model()
        let input = PanelMotionTestEnvironment()
        var environment = input.environment
        environment.frameAnimationDuration = { _ in 0 } // Reduce Motion path
        let frame = NSRect(x: 100, y: 100, width: 364, height: 620)
        let panel = DotistPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let motion = PanelMotion(model: model, panel: panel, size: frame.size, title: { "" }, environment: environment)
        defer { motion.stop(); panel.close() }
        XCTAssertFalse(panel.hasShadow)
        motion.toggleBubble(in: input.area)
        XCTAssertFalse(panel.hasShadow)
        motion.toggleBubble(in: input.area) // ignored while the frame transition runs
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(try input.frameAnimationDuration(for: panel), 0)
        try input.completeFrameAnimation(for: panel)
        motion.setHover(true, in: input.area)
        XCTAssertFalse(panel.hasShadow)
        motion.toggleBubble(in: input.area) // queued until hover finishes
        XCTAssertFalse(panel.hasShadow)
        motion.finishHover(true)
        XCTAssertFalse(motion.bubble)
        XCTAssertFalse(panel.hasShadow)
        try input.completeFrameAnimation(for: panel)
        XCTAssertFalse(panel.hasShadow)
        motion.toggleBubble(in: input.area)
        XCTAssertFalse(panel.hasShadow)
        motion.stop()
        try input.completeFrameAnimation(for: panel)
        motion.refreshShadow()
        XCTAssertFalse(panel.hasShadow)
    }

    func testShadowRefreshContinuesAfterViewUpdatesAndStopsWhenRemoved() async throws {
        _ = NSApplication.shared
        let panel = ShadowCountingPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 48), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = ShadowInvalidationView()
        panel.contentView = view
        view.refresh()
        let firstCount = panel.invalidations
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(panel.invalidations, firstCount + 1, "Invalidate after glass commits and on each reveal/tint animation tick")
        try await Task.sleep(for: .milliseconds(450))
        let settledCount = panel.invalidations
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(panel.invalidations, settledCount, "Static surfaces must not keep a refresh timer running")
        view.refresh()
        panel.close()
        let stoppedCount = panel.invalidations
        view.refresh()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(panel.invalidations, stoppedCount)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: panel)
        XCTAssertGreaterThan(panel.invalidations, stoppedCount, "Retained settings/search windows must resume refreshing when reopened")
        view.stop()
    }
}

private final class ShadowCountingPanel: NSPanel {
    var invalidations = 0
    override func invalidateShadow() {
        invalidations += 1
        super.invalidateShadow()
    }
}
