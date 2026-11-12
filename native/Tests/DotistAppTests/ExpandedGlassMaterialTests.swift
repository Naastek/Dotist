import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class ExpandedGlassMaterialTests: XCTestCase {
    private func bitmap<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2, scheme: ColorScheme = .light) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme))
        renderer.scale = scale
        var image: CGImage?
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image))
    }

    /// Offscreen rendering proves composition, not native refraction. The
    /// existing thin reflection must remain visible and independent of density.
    func testExpandedRimDoesNotFadeWithReadingPreferences() throws {
        let size = CGSize(width: 260, height: 140)
        for scheme in [ColorScheme.light, .dark] {
            var reference: CGFloat?
            for (opacity, frost): (UInt8, UInt8) in [(20, 0), (80, 40), (100, 100)] {
                let image = try bitmap(FloatingPanelSurface(opacity: opacity, frost: frost, compact: false,
                    color: .pink, solid: false, scheme: scheme), size: size, scheme: scheme)
                let alpha = try XCTUnwrap(image.colorAt(x: 260, y: 2)).alphaComponent
                if let reference { XCTAssertEqual(alpha, reference, accuracy: 1.0 / 255, "Reading settings must not paint outside the optical clearance: \(scheme)") }
                else { reference = alpha }
            }
        }
    }

    func testExpandedInteriorRetainsDensityFrostAndTint() throws {
        let size = CGSize(width: 260, height: 140)
        for scheme in [ColorScheme.light, .dark] {
            // Resolve the real production reading layer independently: native
            // glass may already return alpha 1 on a rendering-capable host.
            func center(_ opacity: UInt8, _ frost: UInt8, _ color: DotistGroupColor = .pink, composite: Bool = false) throws -> NSColor {
                let image = try bitmap(ZStack {
                    if composite { Color(red: 0.12, green: 0.32, blue: 0.58) }
                    ExpandedReadingMaterial(opacity: opacity, frost: frost, color: color, scheme: scheme, cornerRadius: 18)
                }, size: size, scheme: scheme)
                if !composite {
                    XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 260, y: 0)).alphaComponent,
                        try XCTUnwrap(image.colorAt(x: 260, y: 140)).alphaComponent, accuracy: 1.0 / 255,
                        "Reading paint must reach the straight edge without an inset step")
                    XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 0, y: 0)).alphaComponent, 0,
                        "Reading layers must not create a rectangular plate")
                }
                return try XCTUnwrap(image.colorAt(x: 260, y: 140))
            }
            // Independent source-over formula catches ignored/clamped inputs,
            // omitted frost/tint, or an accidental extra whole-layer fade.
            for (opacity, frost): (UInt8, UInt8) in [(20, 0), (20, 100), (80, 40), (100, 100)] {
                let expected = 1 - (1 - Double(opacity) / 100) * (1 - Double(frost) / 100 * 0.12) * (1 - (scheme == .dark ? 0.18 : 0.16))
                XCTAssertEqual(try center(opacity, frost).alphaComponent, CGFloat(expected), accuracy: 2.0 / 255)
            }
            XCTAssertGreaterThan(try center(80, 40).alphaComponent, 0.8, "80/40 must retain the reading backing")
            XCTAssertGreaterThan(try center(80, 40).alphaComponent, try center(20, 40).alphaComponent + 0.2)
            XCTAssertGreaterThan(try center(20, 100).alphaComponent, try center(20, 0).alphaComponent + 0.04)
            let pink = try XCTUnwrap(center(80, 40).usingColorSpace(.deviceRGB))
            let neutral = try XCTUnwrap(center(80, 40, .none).usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(abs(pink.redComponent - neutral.redComponent)
                + abs(pink.greenComponent - neutral.greenComponent), 0.01)

            func rgbDistance(_ a: NSColor, _ b: NSColor) throws -> CGFloat {
                let a = try XCTUnwrap(a.usingColorSpace(.deviceRGB)), b = try XCTUnwrap(b.usingColorSpace(.deviceRGB))
                XCTAssertEqual(a.alphaComponent, 1); XCTAssertEqual(b.alphaComponent, 1)
                return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
            }
            // RGB must still change when destination alpha is saturated. The
            // guarded desktop fixture separately checks the full native surface.
            XCTAssertGreaterThan(try rgbDistance(center(20, 40, composite: true), center(80, 40, composite: true)), 0.1)
            XCTAssertGreaterThan(try rgbDistance(center(20, 0, composite: true), center(20, 100, composite: true)), 0.02)
            XCTAssertGreaterThan(try rgbDistance(center(80, 40, composite: true), center(80, 40, .none, composite: true)), 0.01)
        }
    }

    func testExpandedContentClipMatchesOpticalShapeAndPreservesTransitions() {
        let rect = CGRect(x: 0, y: 0, width: 364, height: 620)
        for compact in [false, true] {
            for transitioning in [false, true] {
                let panel = FloatingPanelShape(compact: compact, transitioning: transitioning, onRight: true, reveal: 0.5)
                let actual = FloatingPanelContentShape(panelShape: panel).path(in: rect)
                let expected = !compact && !transitioning
                    ? RoundedRectangle(cornerRadius: DotistDesign.windowCornerRadius - ExpandedReadingMaterial.opticalClearance, style: .continuous)
                        .path(in: rect.insetBy(dx: ExpandedReadingMaterial.opticalClearance, dy: ExpandedReadingMaterial.opticalClearance))
                    : panel.path(in: rect)
                XCTAssertEqual(actual.cgPath, expected.cgPath)
            }
        }
    }

    func testGlassInteriorAlphaEndpointsAndMonotonicity() {
        for dark in [false, true] {
            for frost: UInt8 in [0, 40, 100] {
                XCTAssertEqual(ExpandedReadingMaterial.glassInteriorAlpha(opacity: 100, frost: frost, dark: dark), 1, accuracy: 0.000001)
            }
            XCTAssertEqual(ExpandedReadingMaterial.glassInteriorAlpha(opacity: 0, frost: 0, dark: dark), 0, accuracy: 0.000001)
            XCTAssertEqual(ExpandedReadingMaterial.glassInteriorAlpha(opacity: 0, frost: 100, dark: dark), 1, accuracy: 0.000001)
            XCTAssertEqual(ExpandedReadingMaterial.glassInteriorAlpha(opacity: 80, frost: 40, dark: dark), 0.88, accuracy: 0.000001)
            for opacity in 0...100 {
                for frost in 0...100 {
                    let value = ExpandedReadingMaterial.glassInteriorAlpha(opacity: UInt8(opacity), frost: UInt8(frost), dark: dark)
                    if opacity < 100 { XCTAssertGreaterThanOrEqual(ExpandedReadingMaterial.glassInteriorAlpha(opacity: UInt8(opacity + 1), frost: UInt8(frost), dark: dark), value) }
                    if frost < 100 { XCTAssertGreaterThanOrEqual(ExpandedReadingMaterial.glassInteriorAlpha(opacity: UInt8(opacity), frost: UInt8(frost + 1), dark: dark), value) }
                }
            }
        }
    }

    /// An independent plain silhouette supplies the raster allowance. Any alpha
    /// beyond its one-pixel neighborhood is a real exterior plate, not rounding.
    private func exteriorAlpha(_ image: NSBitmapImageRep, size: CGSize, compact: Bool, scale: CGFloat) throws -> CGFloat {
        let radius: CGFloat = compact ? 24 : 20
        let mask = try bitmap(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white), size: size, scale: scale)
        var maximum: CGFloat = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                // Check the corner areas; the middle of each straight edge is
                // inside the expected silhouette at every transition size.
                if x > Int(25 * scale), x < image.pixelsWide - Int(25 * scale) { continue }
                if y > Int(25 * scale), y < image.pixelsHigh - Int(25 * scale) { continue }
                var inside = false
                for dy in -1...1 { for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0, yy >= 0, xx < mask.pixelsWide, yy < mask.pixelsHigh,
                       (mask.colorAt(x: xx, y: yy)?.alphaComponent ?? 0) > 0 { inside = true }
                } }
                if !inside { maximum = max(maximum, try XCTUnwrap(image.colorAt(x: x, y: y)).alphaComponent) }
            }
        }
        return maximum
    }

    private func assertNoExteriorPlate(_ image: NSBitmapImageRep, size: CGSize, compact: Bool,
                                       transitioning: Bool, scale: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try exteriorAlpha(image, size: size, compact: compact, scale: scale), 0,
            "Exterior alpha: compact=\(compact), transition=\(transitioning), size=\(size), scale=\(scale)", file: file, line: line)
    }

    func testBoundaryOracleDetectsAnUnmaskedReadingPlate() throws {
        let size = CGSize(width: 171, height: 273)
        for scale: CGFloat in [1, 2] {
            let wrong = try bitmap(Color.white.opacity(0.8), size: size, scale: scale)
            XCTAssertGreaterThan(try exteriorAlpha(wrong, size: size, compact: false, scale: scale), 0.7)
            let correct = try bitmap(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white), size: size, scale: scale)
            XCTAssertEqual(try exteriorAlpha(correct, size: size, compact: false, scale: scale), 0)
        }
    }

    func testExpandedAndTransitionBoundaryAlphaWithAccessibilityAndMotion() throws {
        for scale: CGFloat in [1, 2] {
            for protection in 0...2 {
                for reduced in [false, true] {
                    for compact in [false, true] {
                        for size in [CGSize(width: 48, height: 48), CGSize(width: 171, height: 273), CGSize(width: 364, height: 620)] {
                            let insets = EdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
                            let image = try bitmap(FloatingSurface(opacity: 80, frost: 40, compact: compact,
                                transitioning: true, onRight: true, size: size, reveal: 1, color: .pink, frameInsets: insets)
                                .environment(\._accessibilityReduceTransparency, protection == 1)
                                .environment(\._colorSchemeContrast, protection == 2 ? .increased : .standard)
                                .environment(\._accessibilityReduceMotion, reduced), size: size, scale: scale)
                            try assertNoExteriorPlate(image, size: size, compact: compact, transitioning: true, scale: scale)
                            if protection > 0 {
                                XCTAssertEqual(try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)).alphaComponent, 1)
                            }
                        }
                    }
                }
            }
        }
    }

    func testRealPanelMotionKeepsMaterialContainedAtNormalAndReducedDurations() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/expanded-glass/motion-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try TaskStore(databasePath: root.appendingPathComponent("fixture.sqlite").path)
        let model = try AppModel(store: store)
        for (reduced, initialX, expectedRight): (Bool, CGFloat, Bool) in [
            (false, 300, false), (false, 900, true), (true, 300, false), (true, 900, true)
        ] {
            let area = NSRect(x: 0, y: 0, width: 1400, height: 1000)
            let initial = NSRect(x: initialX, y: 200, width: 364, height: 620)
            let panel = DotistPanel(contentRect: initial, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            var environment = PanelMotion.Environment()
            environment.pointerEventsEnabled = false
            environment.visibleFrame = { _ in area }
            environment.mouseLocation = { NSPoint(x: -1000, y: -1000) }
            environment.frameAnimationDuration = { compact in reduced ? 0 : (compact ? 0.28 : 0.34) }
            let motion = PanelMotion(model: model, panel: panel, size: initial.size, title: { "Synthetic fixture" }, environment: environment)
            defer { motion.stop(); panel.close() }
            var checkedFrames = 0
            motion.environment.animateFrame = { panel, target, duration, complete in
                XCTAssertTrue(motion.animationInProgress)
                XCTAssertEqual(duration, reduced ? 0 : (motion.bubble ? 0.28 : 0.34))
                let start = panel.frame
                for fraction: CGFloat in reduced ? [1] : [0, 0.25, 0.5, 0.75, 1] {
                    func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * fraction }
                    panel.setFrame(NSRect(x: mix(start.minX, target.minX), y: mix(start.minY, target.minY),
                        width: mix(start.width, target.width), height: mix(start.height, target.height)), display: false)
                    let size = panel.frame.size
                    XCTAssertGreaterThanOrEqual(motion.surfaceInsets.top, 0)
                    XCTAssertLessThanOrEqual(motion.surfaceInsets.top, 2)
                    do {
                        let image = try self.bitmap(FloatingSurface(opacity: 80, frost: 40, compact: motion.bubble,
                            transitioning: motion.animationInProgress, onRight: motion.bubbleOnRight, size: size,
                            reveal: 1, color: .pink, frameInsets: motion.surfaceInsets)
                            .environment(\._accessibilityReduceMotion, reduced), size: size)
                        try self.assertNoExteriorPlate(image, size: size, compact: motion.bubble, transitioning: true, scale: 2)
                        checkedFrames += 1
                    } catch { XCTFail("Transition render failed: \(error)") }
                }
                XCTAssertEqual(motion.surfaceInsets.top, motion.bubble ? 2 : 0)
                complete()
            }
            motion.toggleBubble(in: area)
            XCTAssertTrue(motion.bubble); XCTAssertFalse(motion.animationInProgress)
            XCTAssertEqual(motion.bubbleOnRight, expectedRight)
            motion.toggleBubble(in: area)
            XCTAssertFalse(motion.bubble); XCTAssertFalse(motion.animationInProgress)
            XCTAssertEqual(panel.frame.size, initial.size)
            XCTAssertEqual(checkedFrames, reduced ? 2 : 10)
        }
    }
}
