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

    func testNeutralGlassRequestsWhiteInsteadOfDefaultUntintedMaterial() throws {
        for scheme in [ColorScheme.light, .dark] {
            let tint = try center(DotistTheme.tint(.none, scheme))
            XCTAssertGreaterThan(tint.alphaComponent, 0.1)
            XCTAssertEqual(tint.redComponent, 1, accuracy: 0.005)
            XCTAssertEqual(tint.greenComponent, 1, accuracy: 0.005)
            XCTAssertEqual(tint.blueComponent, 1, accuracy: 0.005)
        }
    }

    func testFullyOpaqueNeutralReadingSurfaceIsWhite() throws {
        for frost: UInt8 in [0, 40, 100] {
            let pixel = try center(ExpandedReadingMaterial(opacity: 100, frost: frost, color: .none,
                scheme: .light, cornerRadius: 20))
            XCTAssertEqual(pixel.alphaComponent, 1, accuracy: 0.005)
            XCTAssertEqual(pixel.redComponent, 1, accuracy: 0.005)
            XCTAssertEqual(pixel.greenComponent, 1, accuracy: 0.005)
            XCTAssertEqual(pixel.blueComponent, 1, accuracy: 0.005)
        }
    }
}
