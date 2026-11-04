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
        panel.hasShadow = true
        defer { panel.close() }
        let host = DotistHostingView(rootView: FloatingSurface(opacity: 73, frost: 22,
            compact: true, transitioning: false, onRight: true, size: CGSize(width: 280, height: 48), reveal: 0, color: .orange)
            .environment(\._accessibilityReduceTransparency, true))
        host.sizingOptions = []
        panel.contentView = host
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
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / width
                let surfaceWidth = 48 + (width - 48) * reveal
                let minX = onRight ? width - surfaceWidth : 0
                let maskRenderer = ImageRenderer(content: Color.white
                    .clipShape(FloatingPanelShape(compact: true, transitioning: false, onRight: onRight, reveal: reveal))
                    .frame(width: size.width, height: size.height)
                    .environment(\.displayScale, scale))
                maskRenderer.scale = scale
                let mask = NSBitmapImageRep(cgImage: try XCTUnwrap(maskRenderer.cgImage))
                var maximumExteriorAlpha: CGFloat = 0
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
                            maximumExteriorAlpha = max(maximumExteriorAlpha, try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent)
                        }
                    }
                }
                XCTAssertEqual(maximumExteriorAlpha, 0, "Window-backed compositing must not add an offset plate at reveal=\(reveal)")
                XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: Int((minX + surfaceWidth / 2) * scale), y: Int(24 * scale))).alphaComponent, 0.05)
                XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
            }
        }
    }

    func testAllTaskAndQuickPanelsUseSystemShadowWithoutShadowChildren() throws {
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
        XCTAssertTrue(try XCTUnwrap(group.window).hasShadow)
        XCTAssertFalse(try XCTUnwrap(group.window).isOpaque)
        for size in [NSSize(width: 560, height: 112), NSSize(width: 600, height: 372)] {
            let quick = QuickPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            quick.isReleasedWhenClosed = false
            XCTAssertTrue(quick.hasShadow)
            quick.close()
        }
        let area = NSRect(x: 0, y: 0, width: 1440, height: 1000)
        for _ in 0..<3 {
            motion.toggleBubble(in: area, animated: false)
            motion.setHover(true, in: area)
            motion.finishHover(true)
            panel.setFrameOrigin(NSPoint(x: 20, y: 20))
            _ = motion.finishBubbleMove()
            motion.setHover(false, in: area)
            motion.finishHover(false)
            motion.refreshShadow()
            XCTAssertTrue(panel.hasShadow)
            XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
            XCTAssertTrue(group.window?.childWindows?.isEmpty ?? true)
        }
    }

    func testHiddenPanelFrameRequestsCompleteSynchronouslyWithoutShadowChildren() throws {
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
            XCTAssertTrue(panel.hasShadow)
            XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
            XCTAssertEqual(durationRequests, 0, "Do not queue native animations for hidden windows")
            XCTAssertEqual(input.pendingFrameAnimationCount, 0)
        }
        XCTAssertEqual(remembered.count, 1, "Synchronous expansion must still finish its lifecycle handoff")
        XCTAssertEqual(remembered.first?.size, frame.size)
    }

    func testControlledFrameAnimationsKeepSystemShadowAtIntermediateSizes() throws {
        let model = try model()
        let input = PanelMotionTestEnvironment()
        let frame = NSRect(x: 100, y: 100, width: 364, height: 620)
        let panel = DotistPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let motion = PanelMotion(model: model, panel: panel, size: frame.size, title: { "" }, environment: input.environment)
        defer { motion.stop(); panel.close() }
        for compact in [true, false] {
            XCTAssertFalse(panel.isVisible)
            XCTAssertNotNil(motion.environment.animateFrame)
            motion.toggleBubble(in: input.area)
            XCTAssertTrue(motion.animationInProgress)
            XCTAssertEqual(input.pendingFrameAnimationCount, 1)
            for progress in [CGFloat(0.25), 0.5, 0.75] {
                try input.sampleFrameAnimation(for: panel, progress: progress)
                XCTAssertTrue(motion.animationInProgress)
                XCTAssertTrue(panel.hasShadow)
                XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
            }
            try input.completeFrameAnimation(for: panel)
            XCTAssertFalse(motion.animationInProgress)
            XCTAssertEqual(motion.bubble, compact)
            XCTAssertEqual(panel.frame.size, compact ? NSSize(width: 48, height: 48) : frame.size)
            XCTAssertTrue(panel.hasShadow)
            XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
        }
        XCTAssertEqual(input.pendingFrameAnimationCount, 0)
    }

    func testShadowRefreshContinuesAfterViewUpdatesAndStopsWhenRemoved() async throws {
        _ = NSApplication.shared
        let panel = ShadowCountingPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 48), styleMask: [.borderless], backing: .buffered, defer: false)
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
