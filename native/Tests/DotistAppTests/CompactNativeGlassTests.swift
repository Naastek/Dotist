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

    func testCompactMatchesChosenSingleNativeSurfaceWithoutPaintedLight() throws {
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
                    var difference: CGFloat = 0
                    for y in 0..<actual.pixelsHigh { for x in 0..<actual.pixelsWide {
                        let a = try XCTUnwrap(actual.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        let b = try XCTUnwrap(reference.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        difference = max(difference, abs(a.alphaComponent - b.alphaComponent))
                        for (aa, bb) in [(a.redComponent,b.redComponent),(a.greenComponent,b.greenComponent),(a.blueComponent,b.blueComponent)] {
                            difference = max(difference, abs(aa*a.alphaComponent - bb*b.alphaComponent))
                        }
                    } }
                    XCTAssertLessThanOrEqual(difference, 1.0/255, "Compact glass must match the selected native material: \(scheme), \(color), \(width)")
                }
            }
        }
    }
}
