import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class GlassBrightnessTests: XCTestCase {
    private func center<V: View>(_ view: V) throws -> NSColor {
        let renderer = ImageRenderer(content: view.frame(width: 80, height: 80).environment(\.colorScheme, .light))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        return try XCTUnwrap(bitmap.colorAt(x: 40, y: 40)?.usingColorSpace(.sRGB))
    }

    func testNeutralGlassRequestsGentleWhiteInsteadOfOverbrightOrUntintedMaterial() throws {
        let lightTint = try center(DotistTheme.tint(.none, .light))
        XCTAssertEqual(lightTint.alphaComponent, 0.10, accuracy: 0.005)
        XCTAssertEqual(lightTint.redComponent, 1, accuracy: 0.005)
        XCTAssertEqual(lightTint.greenComponent, 1, accuracy: 0.005)
        XCTAssertEqual(lightTint.blueComponent, 1, accuracy: 0.005)

        let darkTint = try center(DotistTheme.tint(.none, .dark))
        XCTAssertEqual(darkTint.alphaComponent, 0.08, accuracy: 0.005)
        XCTAssertEqual(darkTint.redComponent, 1, accuracy: 0.005)
        XCTAssertEqual(darkTint.greenComponent, 1, accuracy: 0.005)
        XCTAssertEqual(darkTint.blueComponent, 1, accuracy: 0.005)
    }

    func testFullyOpaqueNeutralReadingSurfaceUsesSoftPaperWhite() throws {
        let expectedPaper = try center(DotistDesign.paper)
        for frost: UInt8 in [0, 40, 100] {
            let pixel = try center(ExpandedReadingMaterial(opacity: 100, frost: frost, color: .none,
                scheme: .light, cornerRadius: 20))
            XCTAssertEqual(pixel.alphaComponent, 1, accuracy: 0.005)
            XCTAssertEqual(pixel.redComponent, expectedPaper.redComponent, accuracy: 0.005)
            XCTAssertEqual(pixel.greenComponent, expectedPaper.greenComponent, accuracy: 0.005)
            XCTAssertEqual(pixel.blueComponent, expectedPaper.blueComponent, accuracy: 0.005)
        }
    }
}
