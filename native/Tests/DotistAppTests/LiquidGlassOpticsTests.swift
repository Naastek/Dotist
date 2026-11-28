import AppKit
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class LiquidGlassOpticsTests: XCTestCase {
    func testPhysicalRimLeavesInteriorCrystalClearAndExhibitsDualLobeGlare() throws {
        let specs: [(LiquidGlassOpticsRenderer.FormKind, CGSize, CGFloat)] = [
            (.bubble, CGSize(width: 44, height: 44), 22),
            (.strip, CGSize(width: 236, height: 44), 22),
            (.expanded, CGSize(width: 360, height: 616), 18),
        ]
        for dark in [false, true] {
            for (form, size, radius) in specs {
                let cg = try XCTUnwrap(LiquidGlassOpticsRenderer.rimImage(
                    size: size, cornerRadius: radius, form: form, dark: dark, scale: 2
                ))
                let rep = NSBitmapImageRep(cgImage: cg)
                // Interior center must be 100% transparent (zero milky backing)
                let center = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                XCTAssertEqual(center.alphaComponent, 0, accuracy: 0.002,
                    "Center must stay crystal clear for form=\(form) dark=\(dark)")

                // Top-leading glare peak must be visibly brighter than quiet side flanks
                func peakLuminance(xs: ClosedRange<Int>, ys: ClosedRange<Int>) throws -> CGFloat {
                    var best: CGFloat = 0
                    for y in ys {
                        for x in xs {
                            guard x >= 0, x < rep.pixelsWide, y >= 0, y < rep.pixelsHigh else { continue }
                            let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                            let lum = (0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent) * c.alphaComponent
                            best = max(best, lum)
                        }
                    }
                    return best
                }

                let topPeak = try peakLuminance(xs: (rep.pixelsWide / 2 - 8)...(rep.pixelsWide / 2 + 8), ys: 0...8)
                let bottomPeak = try peakLuminance(xs: (rep.pixelsWide / 2 - 8)...(rep.pixelsWide / 2 + 8), ys: (rep.pixelsHigh - 9)...(rep.pixelsHigh - 1))
                let rightFlank = try peakLuminance(xs: (rep.pixelsWide - 9)...(rep.pixelsWide - 1), ys: (rep.pixelsHigh / 2 - 8)...(rep.pixelsHigh / 2 + 8))

                XCTAssertGreaterThan(topPeak, 0.25, "Top specular rim must be visible for form=\(form) dark=\(dark)")
                XCTAssertGreaterThan(bottomPeak, 0.14, "Opposite-side caustic bounce must be visible for form=\(form) dark=\(dark)")
                XCTAssertGreaterThan(topPeak, bottomPeak * 1.1, "Primary top-leading glare should lead opposite-side caustic")
                XCTAssertGreaterThan(bottomPeak, rightFlank * 1.15, "Caustic rim should lead quiet perpendicular flank")
            }
        }
    }

    func testFeatheredInteriorMaskTransitionsSmoothlyWithoutHardSeam() throws {
        let size = CGSize(width: 360, height: 616)
        let cg = try XCTUnwrap(LiquidGlassOpticsRenderer.featheredInteriorMask(
            size: size, cornerRadius: 18, insetPt: 1.75, featherPt: 10.5, scale: 1
        ))
        let rep = NSBitmapImageRep(cgImage: cg)
        let midY = rep.pixelsHigh / 2
        // Outer refractive rim (x = 0, 1) must be completely clear (0)
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 0, y: midY)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 1, y: midY)).alphaComponent, 0, accuracy: 0.01)
        // Mid-feather zone (x = 6) must be strictly intermediate (smooth ramp, no hard step)
        let midFeather = try XCTUnwrap(rep.colorAt(x: 6, y: midY)).alphaComponent
        XCTAssertGreaterThan(midFeather, 0.20)
        XCTAssertLessThan(midFeather, 0.85)
        // Deep interior (x = 24) must be fully opaque (1)
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 24, y: midY)).alphaComponent, 1.0, accuracy: 0.01)
    }
}
