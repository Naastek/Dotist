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

    func testThreeFloatingShapesPreserveNativeGlassAcrossOpacityRange() throws {
        let forms = [(CGSize(width: 260, height: 140), false),
                     (CGSize(width: 44, height: 44), true),
                     (CGSize(width: 178, height: 44), true)]
        for scheme in [ColorScheme.light, .dark] {
            func centers(opacity: UInt8, frost: UInt8) throws -> [CGFloat] {
                try forms.map { size, compact in
                    let image = try bitmap(FloatingPanelSurface(opacity: opacity, frost: frost,
                        compact: compact, color: .none, solid: false, scheme: scheme), size: size, scheme: scheme)
                    return try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)).alphaComponent
                }
            }
            // Native .clear Liquid Glass stays mounted across the full opacity range,
            // including opacity=0 (100% transparency) so frosted glass and compact forms never vanish.
            let clear = try centers(opacity: 0, frost: 68)
            let muted = try centers(opacity: 44, frost: 68)
            let frosted = try centers(opacity: 82, frost: 68)
            for index in forms.indices {
                XCTAssertGreaterThan(clear[index], 0.95)
                XCTAssertGreaterThan(muted[index], 0.95)
                XCTAssertEqual(frosted[index], frosted[0], accuracy: 1.0 / 255)
            }
        }
    }

    func testExpandedGlassCalibrationIsFullRangeOrthogonalAndConvergesFeather() {
        for dark in [false, true] {
            // 1. Endpoints
            let fullTransparentNoFrost = ExpandedGlassCalibration.resolve(opacity: 0, frost: 0, dark: dark, hasGroupColor: true)
            XCTAssertEqual(fullTransparentNoFrost.washAlpha, 0, accuracy: 0.001)
            XCTAssertEqual(fullTransparentNoFrost.glassAlpha, 0, accuracy: 0.001)
            XCTAssertEqual(fullTransparentNoFrost.frostAlpha, 0, accuracy: 0.001)
            XCTAssertFalse(fullTransparentNoFrost.showsFrost)
            XCTAssertEqual(fullTransparentNoFrost.tintAlpha, 0, accuracy: 0.001)
            XCTAssertEqual(fullTransparentNoFrost.maskInsetPt, 1.75, accuracy: 0.01)
            XCTAssertEqual(fullTransparentNoFrost.maskFeatherPt, 10.5, accuracy: 0.01)

            let fullOpaqueNoFrost = ExpandedGlassCalibration.resolve(opacity: 1, frost: 0, dark: dark, hasGroupColor: true)
            XCTAssertEqual(fullOpaqueNoFrost.washAlpha, 1.0, accuracy: 0.001)
            XCTAssertEqual(fullOpaqueNoFrost.glassAlpha, 0, accuracy: 0.001)
            XCTAssertEqual(fullOpaqueNoFrost.frostAlpha, 0, accuracy: 0.001)
            XCTAssertFalse(fullOpaqueNoFrost.showsFrost)
            XCTAssertEqual(fullOpaqueNoFrost.tintAlpha, dark ? GlassTintMaterial.expandedDarkTint : GlassTintMaterial.expandedLightTint, accuracy: 0.001)
            XCTAssertEqual(fullOpaqueNoFrost.maskInsetPt, 0.5, accuracy: 0.01)
            XCTAssertEqual(fullOpaqueNoFrost.maskFeatherPt, 1.5, accuracy: 0.01)

            // 2. High transparency (100% transparent, opacity=0) + full frost (100%) yields pure colorless frost
            let pureFrost = ExpandedGlassCalibration.resolve(opacity: 0, frost: 1, dark: dark, hasGroupColor: true)
            XCTAssertEqual(pureFrost.washAlpha, 0, accuracy: 0.001)
            XCTAssertEqual(pureFrost.tintAlpha, 0, accuracy: 0.001)
            XCTAssertEqual(pureFrost.glassAlpha, 1.0, accuracy: 0.001)
            XCTAssertTrue(pureFrost.showsFrost)
            XCTAssertEqual(pureFrost.frostAlpha, 1.0, accuracy: 0.001)
            XCTAssertEqual(pureFrost.maskInsetPt, 0.5, accuracy: 0.01)
            XCTAssertEqual(pureFrost.maskFeatherPt, 1.5, accuracy: 0.01)

            // 3. Strict orthogonality: changing frost never alters washAlpha or tintAlpha
            for opacity in [0.0, 0.08, 0.38, 0.5, 0.6, 1.0] {
                let f0 = ExpandedGlassCalibration.resolve(opacity: opacity, frost: 0, dark: dark, hasGroupColor: true)
                let f50 = ExpandedGlassCalibration.resolve(opacity: opacity, frost: 0.5, dark: dark, hasGroupColor: true)
                let f100 = ExpandedGlassCalibration.resolve(opacity: opacity, frost: 1.0, dark: dark, hasGroupColor: true)
                XCTAssertEqual(f0.washAlpha, f50.washAlpha, accuracy: 0.0001)
                XCTAssertEqual(f0.washAlpha, f100.washAlpha, accuracy: 0.0001)
                XCTAssertEqual(f0.tintAlpha, f100.tintAlpha, accuracy: 0.0001)
            }

            // 4. Strict orthogonality: changing opacity never alters glassAlpha, frostAlpha, or showsFrost
            for frost in [0.0, 0.04, 0.22, 0.4, 0.5, 1.0] {
                let o0 = ExpandedGlassCalibration.resolve(opacity: 0, frost: frost, dark: dark, hasGroupColor: false)
                let o50 = ExpandedGlassCalibration.resolve(opacity: 0.5, frost: frost, dark: dark, hasGroupColor: false)
                let o100 = ExpandedGlassCalibration.resolve(opacity: 1.0, frost: frost, dark: dark, hasGroupColor: false)
                XCTAssertEqual(o0.glassAlpha, o50.glassAlpha, accuracy: 0.0001)
                XCTAssertEqual(o0.glassAlpha, o100.glassAlpha, accuracy: 0.0001)
                XCTAssertEqual(o0.frostAlpha, o50.frostAlpha, accuracy: 0.0001)
                XCTAssertEqual(o0.frostAlpha, o100.frostAlpha, accuracy: 0.0001)
                XCTAssertEqual(o0.showsFrost, o100.showsFrost)
            }

            // 5. Monotonic progression across locked presets (ultra 8/4 < clear 38/22 < standard 60/40 < solid 100/100)
            let ultra = ExpandedGlassCalibration.resolve(opacity: 0.08, frost: 0.04, dark: dark, hasGroupColor: false)
            let clear = ExpandedGlassCalibration.resolve(opacity: 0.38, frost: 0.22, dark: dark, hasGroupColor: false)
            let standard = ExpandedGlassCalibration.resolve(opacity: 0.60, frost: 0.40, dark: dark, hasGroupColor: false)
            XCTAssertLessThan(ultra.washAlpha, clear.washAlpha)
            XCTAssertLessThan(clear.washAlpha, standard.washAlpha)
            XCTAssertLessThan(standard.washAlpha, fullOpaqueNoFrost.washAlpha)
            XCTAssertLessThan(ultra.glassAlpha, clear.glassAlpha)
            XCTAssertLessThan(clear.glassAlpha, standard.glassAlpha)
            XCTAssertLessThan(ultra.frostAlpha, clear.frostAlpha)
            XCTAssertLessThan(clear.frostAlpha, standard.frostAlpha)
            XCTAssertLessThan(standard.frostAlpha, pureFrost.frostAlpha)
            // Airy presets keep generous refractive feathering
            XCTAssertGreaterThanOrEqual(ultra.maskFeatherPt, 9.0)
            XCTAssertGreaterThanOrEqual(clear.maskFeatherPt, 7.5)
            XCTAssertGreaterThan(standard.maskFeatherPt, fullOpaqueNoFrost.maskFeatherPt)
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
                    XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 260, y: 0)).alphaComponent, 0,
                        "Reading paint must leave the native optical band clear")
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

    /// An independent plain silhouette supplies the raster allowance. Any alpha
    /// beyond its one-pixel neighborhood is a real exterior plate, not rounding.
    private func exteriorAlpha(_ image: NSBitmapImageRep, size: CGSize, compact: Bool, transitioning: Bool = false, scale: CGFloat) throws -> CGFloat {
        let radius = FloatingSurface.outerCornerRadius(for: size, compact: compact, transitioning: transitioning)
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
        XCTAssertEqual(try exteriorAlpha(image, size: size, compact: compact, transitioning: transitioning, scale: scale), 0,
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
