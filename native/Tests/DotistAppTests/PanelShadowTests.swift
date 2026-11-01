import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class PanelShadowTests: XCTestCase {
    func testRenderedShadowExtendsOutsideBothShapesAndLeavesTheGlassInteriorTransparent() throws {
        for (compact, width, reveal, onRight) in [(false, 364.0, 0.0, true), (true, 48, 0, true),
                                                  (true, 280, 0, true), (true, 280, 0, false),
                                                  (true, 280, 0.5, true), (true, 280, 1, true)] {
            for scheme in [ColorScheme.light, .dark] {
                let state = PanelShadowState()
                state.compact = compact
                state.reveal = reveal
                state.onRight = onRight
                let size = NSSize(width: width, height: compact ? 48 : 620)
                let renderer = ImageRenderer(content: PanelShadowView(state: state)
                    .frame(width: size.width + 96, height: size.height + 96)
                    .environment(\.colorScheme, scheme))
                renderer.scale = 1
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                func alpha(_ x: Int, _ y: Int) throws -> CGFloat { try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent }
                let surfaceWidth = compact ? 48 + (width - 48) * reveal : width
                let surfaceMinX = 48 + (onRight ? width - surfaceWidth : 0)
                let centerX = Int(surfaceMinX + surfaceWidth / 2)
                XCTAssertLessThan(try alpha(centerX, Int(48 + size.height / 2)), 0.01, "The shadow must not darken the glass interior")
                XCTAssertGreaterThan(try alpha(centerX, Int(48 + size.height + 4)), 0.04, "The lower shadow must survive the window boundary")
                XCTAssertGreaterThan(try alpha(Int(surfaceMinX - 4), Int(48 + size.height / 2)), 0.01)
                XCTAssertLessThan(try alpha(centerX, Int(size.height + 95)), 0.01, "The transparent margin must contain the shadow's falloff")
                if compact && width == 280 && reveal == 0 {
                    let unusedX = onRight ? 100 : 280
                    XCTAssertLessThan(try alpha(unusedX, 72), 0.01, "The shadow must follow the revealed surface, not the full hover window")
                }
            }
        }
    }

    func testShadowHasTransparentMarginAndFollowsThePanelWithoutChangingItsHitArea() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-shadow-wJ3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let original = NSRect(x: 200, y: 200, width: 364, height: 620)
        let panel = DotistPanel(contentRect: original, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let motion = PanelMotion(model: model, panel: panel, size: original.size, title: { model.bubbleTitle })
        defer { motion.stop(); panel.close() }
        motion.refreshShadow()
        let shadow = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertFalse(panel.hasShadow, "The custom exterior shadow must not be doubled by AppKit")
        XCTAssertTrue(shadow.ignoresMouseEvents)
        XCTAssertFalse(shadow.hasShadow)
        XCTAssertFalse(shadow.canBecomeKey)
        XCTAssertFalse(shadow.canBecomeMain)
        XCTAssertTrue(shadow.isExcludedFromWindowsMenu)
        XCTAssertTrue(shadow.collectionBehavior.contains([.transient, .ignoresCycle]))
        XCTAssertTrue(shadow.frame.contains(panel.frame))
        XCTAssertGreaterThanOrEqual(panel.frame.minX - shadow.frame.minX, 40)
        XCTAssertEqual(panel.frame, original)

        for frame in [NSRect(x: 300, y: 250, width: 400, height: 500),
                      NSRect(x: 410, y: 380, width: 48, height: 48),
                      NSRect(x: 178, y: 380, width: 280, height: 48)] {
            panel.setFrame(frame, display: true)
            assertSynchronized(shadow, panel)
        }
        motion.stop()
        XCTAssertNil(shadow.parent)
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
        XCTAssertNil(panel.synchronizePanelShadow)
    }

    /// Exercise the same bitmap used inside the actual child window. Testing just
    /// an ImageRenderer SwiftUI tree missed the window-backed compositing bug.
    func testEveryInteriorPixelIsClearAndExteriorHasAGradientAtBothDisplayScales() throws {
        let cases: [(Bool, Bool, CGFloat, CGFloat, Bool)] = [
            (false, false, 364, 0, true), (true, false, 48, 0, true),
            (true, false, 280, 0, true), (true, false, 280, 0, false),
            (true, false, 280, 0.5, true), (true, false, 280, 1, false),
            (true, true, 210, 0, true), (false, true, 210, 0, false)
        ]
        for (compact, transitioning, width, reveal, onRight) in cases {
            let size = CGSize(width: width + 96, height: (compact && !transitioning ? 48 : 350) + 96)
            let path = PanelShadowRenderer.surfacePath(size: size, compact: compact,
                transitioning: transitioning, onRight: onRight, reveal: reveal)
            for scale in [CGFloat(1), 2] {
                let image = try XCTUnwrap(PanelShadowRenderer.image(size: size, scale: scale,
                    compact: compact, transitioning: transitioning, onRight: onRight, reveal: reveal))
                let data = try XCTUnwrap(image.dataProvider?.data)
                let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
                var maxInteriorAlpha: UInt8 = 0
                var exteriorAlphas: Set<UInt8> = []
                var interiorPixels = 0
                for y in 0..<image.height {
                    for x in 0..<image.width {
                        let alpha = bytes[y * image.bytesPerRow + x * 4 + 3]
                        let point = CGPoint(x: (CGFloat(x) + 0.5) / scale,
                                            y: size.height - (CGFloat(y) + 0.5) / scale)
                        if path.contains(point) {
                            interiorPixels += 1
                            maxInteriorAlpha = max(maxInteriorAlpha, alpha)
                        } else {
                            exteriorAlphas.insert(alpha)
                        }
                    }
                }
                XCTAssertGreaterThan(interiorPixels, 1_000)
                XCTAssertEqual(maxInteriorAlpha, 0, "Every interior pixel must be transparent: \(compact), \(width), \(reveal), \(scale)x")
                XCTAssertGreaterThan(exteriorAlphas.count, 16, "Shadow must fade through multiple alpha levels")
                XCTAssertTrue(exteriorAlphas.contains(0))
                XCTAssertGreaterThan(exteriorAlphas.max() ?? 0, 10)
            }
        }
    }

    func testSynchronousCollapseDragSnapHoverAndExpansionFramesNeverDrift() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-shadow-wL2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let panel = DotistPanel(contentRect: NSRect(x: 100, y: 100, width: 364, height: 620),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" })
        defer { motion.stop(); panel.close() }
        motion.refreshShadow()
        let shadow = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertTrue(shadow.collectionBehavior.contains(panel.collectionBehavior))
        let area = NSRect(x: 0, y: 0, width: 1440, height: 1000)
        motion.toggleBubble(in: area, animated: false)
        XCTAssertTrue(motion.bubble)
        XCTAssertFalse(motion.animationInProgress)
        XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))
        assertSynchronized(shadow, panel)
        motion.toggleBubble(in: area, animated: false)
        XCTAssertFalse(motion.bubble)
        XCTAssertEqual(panel.frame.size, NSSize(width: 364, height: 620))
        assertSynchronized(shadow, panel)
        // Intermediate widths must not be clamped to the expanded minimum size.
        panel.minSize = NSSize(width: 48, height: 48)
        let expanded = panel.frame
        let bubble = NSRect(x: expanded.maxX - 48, y: expanded.maxY - 48, width: 48, height: 48)
        // Drive deterministic animation ticks synchronously through PanelMotion's
        // installed frame hook, without a live timer or moving the user's mouse.
        for step in 0...30 {
            let t = CGFloat(step) / 30
            panel.setFrame(interpolate(expanded, bubble, t), display: false)
            assertSynchronized(shadow, panel)
        }
        for step in 0...30 {
            panel.setFrameOrigin(NSPoint(x: bubble.minX - CGFloat(step) * 9, y: bubble.minY + CGFloat(step) * 3))
            assertSynchronized(shadow, panel)
        }
        // The boundary clamp and hover expansion use these two AppKit setters.
        panel.setFrameOrigin(NSPoint(x: 0, y: 0))
        assertSynchronized(shadow, panel)
        let moved = panel.frame
        for width in [CGFloat(280), 48, 320, 48] {
            panel.setFrame(NSRect(origin: moved.origin, size: NSSize(width: width, height: 48)), display: false)
            assertSynchronized(shadow, panel)
        }
        for step in 0...30 {
            panel.setFrame(interpolate(moved, expanded, CGFloat(step) / 30), display: false)
            assertSynchronized(shadow, panel)
        }
    }

    func testCollapseAndExpandKeepsEveryObservedFrameSynchronized() async throws {
        _ = NSApplication.shared
        // Native frame animations require a display. Headless runs still execute
        // the same transition and its completion synchronously, without a skip.
        let animated = NSScreen.main != nil
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 1000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-shadow-animation-wL2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let frame = NSRect(x: area.minX + 20, y: area.minY + 20, width: 364, height: 620)
        let panel = DotistPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let motion = PanelMotion(model: model, panel: panel, size: frame.size, title: { "" })
        defer { motion.stop(); panel.close() }
        motion.refreshShadow()
        let shadow = try XCTUnwrap(panel.childWindows?.first)
        for compact in [true, false] {
            motion.toggleBubble(in: area, animated: animated)
            for _ in 0..<150 {
                assertSynchronized(shadow, panel)
                if !motion.animationInProgress { break }
                try await Task.sleep(for: .milliseconds(8))
            }
            XCTAssertFalse(motion.animationInProgress)
            XCTAssertEqual(motion.bubble, compact)
            XCTAssertEqual(panel.frame.size, compact ? NSSize(width: 48, height: 48) : frame.size)
            assertSynchronized(shadow, panel)
        }
    }

    func testWindowBackedContentAlsoHasAHoleAfterEachResize() async throws {
        _ = NSApplication.shared
        let state = PanelShadowState()
        let host = NSHostingView(rootView: PanelShadowView(state: state))
        host.sizingOptions = []
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 716),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = host
        defer { window.close() }
        for (compact, width, reveal, onRight) in [(false, 364.0, 0.0, true), (true, 48, 0, true),
                                                  (true, 280, 0.5, true), (true, 280, 1, false),
                                                  (true, 48, 0, false), (false, 364, 0, true)] {
            state.compact = compact
            state.reveal = reveal
            state.onRight = onRight
            let size = CGSize(width: width + 96, height: (compact ? 48 : 620) + 96)
            window.setFrame(NSRect(origin: .zero, size: size), display: false)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / size.width
            let surface = PanelShadowRenderer.surfaceRect(size: size, compact: compact,
                transitioning: false, onRight: onRight, reveal: reveal)
            let centerX = Int(surface.midX * scale)
            let centerY = Int(surface.midY * scale)
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: centerX, y: centerY)).alphaComponent, 0)
            let outsideX = Int((surface.minX - 4) * scale)
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: outsideX, y: centerY)).alphaComponent, 0.01)
        }
    }

    private func assertSynchronized(_ shadow: NSWindow, _ panel: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(shadow.frame.midX - panel.frame.midX, 0, file: file, line: line)
        XCTAssertEqual(shadow.frame.midY - panel.frame.midY, 0, file: file, line: line)
        XCTAssertEqual(shadow.frame.width - panel.frame.width, PanelShadowRenderer.margin * 2, file: file, line: line)
        XCTAssertEqual(shadow.frame.height - panel.frame.height, PanelShadowRenderer.margin * 2, file: file, line: line)
        XCTAssertEqual(shadow.contentView?.frame.size, shadow.frame.size, file: file, line: line)
    }

    private func interpolate(_ start: NSRect, _ end: NSRect, _ t: CGFloat) -> NSRect {
        NSRect(x: start.minX + (end.minX - start.minX) * t, y: start.minY + (end.minY - start.minY) * t,
               width: start.width + (end.width - start.width) * t, height: start.height + (end.height - start.height) * t)
    }
}
