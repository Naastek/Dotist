import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

/// Full production surfaces and full foreground/background compositions. These
/// checks deliberately do not infer the final contract from isolated paint.
@MainActor
final class ExpandedOpacityContractTests: XCTestCase {
    private let size = CGSize(width: 300, height: 120)

    private func fixedBitmap<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 240, bitsPerComponent: 8, bytesPerRow: 2400,
            space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 600, height: 240))
        context.scaleBy(x: 2, y: 2)
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.render { _, draw in draw(context) }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }

    func testCompleteBackgroundUsesNativeGlassStylesWithoutFrostSlab() async throws {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            for color in [DotistGroupColor.none, .orange, .pink] {
                for material in DotistPanelMaterial.allCases {
                    let fixture = NativeRenderingFixture(FloatingPanelSurface(material: material, compact: false,
                        color: color, solid: false, scheme: scheme).frame(width: 300, height: 120)
                        .environment(\.colorScheme, scheme), size: size)
                    fixture.window.isOpaque = false; fixture.window.backgroundColor = .clear
                    _ = try await fixture.capture(scale: 1)
                    defer { fixture.close() }
                    let glass = try XCTUnwrap(fixture.descendants(NSGlassEffectView.self).first)
                    let host = try XCTUnwrap(glass.superview)
                    XCTAssertTrue(host.subviews.compactMap { $0 as? NSVisualEffectView }.isEmpty,
                        "Expanded native glass must not stack a separate NSVisualEffectView")
                    let pigmentView = try XCTUnwrap(host.subviews.last)
                    let sublayers = try XCTUnwrap(pigmentView.layer?.sublayers)
                    let washLayer = try XCTUnwrap(sublayers.first { $0.name == "dotist.wash" })
                    let tintLayer = try XCTUnwrap(sublayers.first { $0.name == "dotist.tint" })
                    let washColor = try XCTUnwrap(washLayer.backgroundColor)
                    let tintColor = try XCTUnwrap(tintLayer.backgroundColor)
                    let expected = ExpandedGlassProfile.resolve(
                        material: material,
                        dark: scheme == .dark,
                        hasGroupColor: color != .none
                    )
                    XCTAssertEqual(glass.style, expected.glassStyle)
                    XCTAssertEqual(Double(glass.alphaValue), 1.0, accuracy: 0.001)
                    XCTAssertEqual(Double(washColor.alpha), 0.0, accuracy: 0.001)
                    XCTAssertEqual(Double(tintColor.alpha), expected.tintAlpha, accuracy: 0.001)
                }
            }
        }
    }

    /// Exercise the center composition across both native glass styles with independent foreground ink.
    func testNativeWindowCompositionKeepsTextOpaqueAcrossMaterialModes() async throws {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            for material in DotistPanelMaterial.allCases {
                let background = FloatingPanelSurface(material: material, compact: false,
                    color: .pink, solid: false, scheme: scheme)
                let control = background.frame(width: 300, height: 120)
                    .environment(\.colorScheme, scheme)
                let reference = NativeRenderingFixture(control, size: size)
                reference.window.isOpaque = false; reference.window.backgroundColor = .clear
                let expected = try await reference.capture(scale: 1)
                reference.close()
                let content = Text("Readable sample text").font(.system(size: 16)).foregroundStyle(DotistDesign.ink)
                    .frame(width: 300, height: 120)
                    .background(background)
                    .environment(\.colorScheme, scheme)
                let fixture = NativeRenderingFixture(content, size: size)
                fixture.window.isOpaque = false; fixture.window.backgroundColor = .clear
                let actual = try await fixture.capture(scale: 1)
                fixture.close()
                for (x, y) in [(60, 25), (150, 25), (240, 95)] {
                    let a = try XCTUnwrap(actual.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let b = try XCTUnwrap(expected.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 0.015, "Center alpha at \(scheme), material=\(material)")
                    for (aa, bb) in [(a.redComponent, b.redComponent), (a.greenComponent, b.greenComponent), (a.blueComponent, b.blueComponent)] {
                        XCTAssertEqual(aa * a.alphaComponent, bb * b.alphaComponent, accuracy: 0.015,
                            "Center pigment at \(scheme), material=\(material)")
                    }
                }
                var maxInk: CGFloat = 0
                for y in 45..<75 { for x in 60..<240 { maxInk = max(maxInk, actual.colorAt(x: x, y: y)?.alphaComponent ?? 0) } }
                XCTAssertGreaterThan(maxInk, 0.9, "Background material must not fade foreground text")
            }
        }
    }

    func testAccessibilityKeepsWholeBackgroundOpaqueInBothMaterialModes() throws {
        for scheme in [ColorScheme.light, .dark] {
            for material in DotistPanelMaterial.allCases {
                for protection in 1...2 {
                    let image = try fixedBitmap(FloatingPanelMaterial(material: material, compact: false, color: .pink)
                        .environment(\.colorScheme, scheme)
                        .environment(\._accessibilityReduceTransparency, protection == 1)
                        .environment(\._colorSchemeContrast, protection == 2 ? .increased : .standard))
                    XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 300, y: 120)).alphaComponent, 1, accuracy: 0.01)
                }
            }
        }
    }
}
