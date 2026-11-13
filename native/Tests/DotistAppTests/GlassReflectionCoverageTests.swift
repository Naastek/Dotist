import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class GlassReflectionCoverageTests: XCTestCase {
    private func image<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: 240, height: 140).environment(\.colorScheme, .light))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }
    func testReadingPaintLeavesNativeReflectionExposed() throws {
        let bitmap = try image(ExpandedReadingMaterial(opacity: 82, frost: 68, color: .teal, scheme: .light, cornerRadius: 18))
        // First physical pixel inside the retained native silhouette (0.5pt clip).
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 240, y: 1)).alphaComponent, 0.02)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 240, y: 140)).alphaComponent, 0.7)
    }
    func testDecorationsLeaveNativeReflectionExposed() throws {
        for tier in [CompactGlassStyle.Tier.compact, .expanded] {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            let gloss = try image(GlassGloss(shape: shape, intensity: tier, scheme: .light))
            let edge = try image(GlassEdge(cornerRadius: 18, compact: tier == .compact, scheme: .light))
            // The lit top-left section has nonzero decorative alpha before the fix.
            for bitmap in [gloss, edge] {
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 60, y: 1)).alphaComponent, 0.02)
            }
        }
    }
}
