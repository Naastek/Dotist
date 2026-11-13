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
    func testEveryThemeLeavesTheWholeNativeRimUnpainted() throws {
        let size = CGSize(width: 240, height: 140)
        let radius: CGFloat = 18
        let protectedInterior = RoundedRectangle(cornerRadius: radius, style: .continuous)
            .inset(by: 1).path(in: CGRect(origin: .zero, size: size))
        for scheme in [ColorScheme.light, .dark] {
            for color in DotistGroupColor.allCases {
                let paint = ExpandedReadingMaterial(opacity: 100, frost: 100, color: color, scheme: scheme, cornerRadius: radius)
                let edge = GlassEdge(cornerRadius: radius, compact: false, scheme: scheme, color: color)
                let renderer = ImageRenderer(content: ZStack {
                    paint
                    GlassGloss(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), intensity: .expanded, scheme: scheme)
                    edge
                }.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme))
                renderer.scale = 2
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                var maximumAlpha: CGFloat = 0
                for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                    let point = CGPoint(x: (CGFloat(x) + 0.5) / 2, y: (CGFloat(y) + 0.5) / 2)
                    // 只检查整个像素都在保护区内的样本，避免把边界抗锯齿当作覆盖。
                    let corners = [CGPoint(x: point.x - 0.25, y: point.y - 0.25),
                                   CGPoint(x: point.x + 0.25, y: point.y - 0.25),
                                   CGPoint(x: point.x - 0.25, y: point.y + 0.25),
                                   CGPoint(x: point.x + 0.25, y: point.y + 0.25)]
                    if corners.allSatisfy({ !protectedInterior.contains($0) }) {
                        maximumAlpha = max(maximumAlpha, try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent)
                    }
                } }
                XCTAssertLessThan(maximumAlpha, 0.02, "Native rim covered: \(scheme), \(color)")
            }
        }
    }

}
