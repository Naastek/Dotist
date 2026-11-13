import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class CompactNativeGlassTests: XCTestCase {
    private func bitmap<V: View>(_ view: V, size: CGSize, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    func testCompactKeepsUnclippedNativeRimCenterClearAndInnerLensDepthInsideInset() throws {
        for scheme in [ColorScheme.light, .dark] {
            for color in DotistGroupColor.allCases {
                for width: CGFloat in [44, 236] {
                    let size = CGSize(width: width, height: 44)
                    let actual = try bitmap(TransientGlassSurface(cornerRadius: 24, color: color, compact: true, solid: false, scheme: scheme)
                        .modifier(FloatingSurfaceClipping(shape: FloatingPanelShape(compact: true, transitioning: false,
                            onRight: true, reveal: 1), clipsSilhouette: false)), size: size, scheme: scheme)
                    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
                    let reference = try bitmap(Color.clear.dotistGlass(.regular.tint(DotistTheme.tint(color, scheme)), in: shape)
                        .environment(\.appearsActive, true), size: size, scheme: scheme)
                    // Center interior stays clear of optical edge shading.
                    let cx = Int(width), cy = 44
                    let a = try XCTUnwrap(actual.colorAt(x: cx, y: cy)?.usingColorSpace(.sRGB))
                    let b = try XCTUnwrap(reference.colorAt(x: cx, y: cy)?.usingColorSpace(.sRGB))
                    XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 1.0 / 255)
                    XCTAssertEqual(a.redComponent * a.alphaComponent, b.redComponent * b.alphaComponent, accuracy: 1.0 / 255)
                    // Inner lens depth must stay strictly inside inset(1), leaving the 0..1pt native rim unpainted.
                    let depth = try bitmap(GlassLensDepth(shape: shape, compact: true, scheme: scheme), size: size, scheme: scheme)
                    let rim = shape.inset(by: 1).path(in: CGRect(origin: .zero, size: size))
                    var outsideAlpha: CGFloat = 0
                    var insidePeakAlpha: CGFloat = 0
                    for y in 0..<depth.pixelsHigh {
                        for x in 0..<depth.pixelsWide {
                            let pt = CGPoint(x: (CGFloat(x) + 0.5) / 2, y: (CGFloat(y) + 0.5) / 2)
                            let corners = [CGPoint(x: pt.x - 0.25, y: pt.y - 0.25), CGPoint(x: pt.x + 0.25, y: pt.y - 0.25),
                                           CGPoint(x: pt.x - 0.25, y: pt.y + 0.25), CGPoint(x: pt.x + 0.25, y: pt.y + 0.25)]
                            let pxAlpha = try XCTUnwrap(depth.colorAt(x: x, y: y)).alphaComponent
                            if corners.allSatisfy({ !rim.contains($0) }) {
                                outsideAlpha = max(outsideAlpha, pxAlpha)
                            } else {
                                insidePeakAlpha = max(insidePeakAlpha, pxAlpha)
                            }
                        }
                    }
                    XCTAssertLessThan(outsideAlpha, 0.02, "Outer 1pt native rim must remain unpainted: \(scheme), \(color), \(width)")
                    XCTAssertGreaterThan(insidePeakAlpha, 0.02, "Inner lens bevel must be present inside inset(1): \(scheme), \(color), \(width)")
                }
            }
        }
    }
}
