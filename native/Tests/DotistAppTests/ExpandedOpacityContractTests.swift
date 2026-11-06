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

    func testCompleteBackgroundHonorsOpacityBudgetIncludingFrostAndGroupTint() async throws {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            for color in [DotistGroupColor.none, .orange, .pink] {
                for opacity: UInt8 in [0, 4, 38, 80, 95, 100] {
                    for frost: UInt8 in [0, 40, 100] {
                        let fixture = NativeRenderingFixture(FloatingPanelSurface(opacity: opacity, frost: frost, compact: false,
                            color: color, solid: false, scheme: scheme).frame(width: 300, height: 120)
                            .environment(\.colorScheme, scheme), size: size)
                        fixture.window.isOpaque = false; fixture.window.backgroundColor = .clear
                        let image = try await fixture.capture(scale: 1)
                        fixture.close()
                        for (x, y) in [(60, 25), (150, 60), (240, 95)] {
                            let alpha = try XCTUnwrap(image.colorAt(x: x, y: y)).alphaComponent
                            XCTAssertLessThanOrEqual(alpha, CGFloat(opacity) / 100 + 2.0 / 255,
                                "The complete background must fit the opacity budget: \(scheme), \(color), opacity=\(opacity), frost=\(frost)")
                            if opacity == 0 { XCTAssertEqual(alpha, 0, accuracy: 1.0 / 255) }
                            if opacity == 100 { XCTAssertGreaterThan(alpha, 0.98) }
                        }
                    }
                }
            }
        }
    }

    /// Same full-background reference as the existing pre-edge contract, now
    /// exercised at intermediate opacity and with independent foreground ink.
    func testNativeWindowCompositionMatchesLegacyCenterAndKeepsTextOpaque() async throws {
        _ = NSApplication.shared
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        for scheme in [ColorScheme.light, .dark] {
            for opacity: UInt8 in [0, 4, 38, 80, 95, 100] {
                let amount = Double(opacity) / 100
                let control = Color.clear.glassEffect(.regular.tint(DotistTheme.tint(.pink, scheme)), in: shape)
                    .overlay(DotistDesign.paper.opacity(amount).overlay(DotistDesign.paper.opacity(0.4 * 0.12)))
                    .overlay(DotistTheme.swatch(.pink).opacity(scheme == .dark ? 0.18 : 0.16))
                    .opacity(amount).clipShape(shape)
                    .frame(width: 300, height: 120).environment(\.colorScheme, scheme)
                let reference = NativeRenderingFixture(control, size: size)
                reference.window.isOpaque = false; reference.window.backgroundColor = .clear
                let expected = try await reference.capture(scale: 1)
                reference.close()
                let content = Text("Readable sample text").font(.system(size: 16)).foregroundStyle(DotistDesign.ink)
                    .frame(width: 300, height: 120)
                    .background(FloatingPanelSurface(opacity: opacity, frost: 40, compact: false,
                        color: .pink, solid: false, scheme: scheme))
                    .environment(\.colorScheme, scheme)
                let fixture = NativeRenderingFixture(content, size: size)
                fixture.window.isOpaque = false; fixture.window.backgroundColor = .clear
                let actual = try await fixture.capture(scale: 1)
                fixture.close()
                for (x, y) in [(60, 25), (150, 25), (240, 95)] {
                    let a = try XCTUnwrap(actual.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let b = try XCTUnwrap(expected.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 0.015, "Legacy center alpha at \(scheme), opacity=\(opacity)")
                    for (aa, bb) in [(a.redComponent, b.redComponent), (a.greenComponent, b.greenComponent), (a.blueComponent, b.blueComponent)] {
                        XCTAssertEqual(aa * a.alphaComponent, bb * b.alphaComponent, accuracy: 0.015,
                            "Legacy center pigment at \(scheme), opacity=\(opacity)")
                    }
                }
                var maxInk: CGFloat = 0
                for y in 45..<75 { for x in 60..<240 { maxInk = max(maxInk, actual.colorAt(x: x, y: y)?.alphaComponent ?? 0) } }
                XCTAssertGreaterThan(maxInk, 0.9, "Background opacity must not fade foreground text")
            }
        }
    }

    func testAccessibilityKeepsWholeBackgroundOpaqueAtZeroOpacity() throws {
        for scheme in [ColorScheme.light, .dark] {
            for protection in 1...2 {
                let image = try fixedBitmap(FloatingPanelMaterial(opacity: 0, frost: 100, compact: false, color: .pink)
                    .environment(\.colorScheme, scheme)
                    .environment(\._accessibilityReduceTransparency, protection == 1)
                    .environment(\._colorSchemeContrast, protection == 2 ? .increased : .standard))
                XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 300, y: 120)).alphaComponent, 1, accuracy: 0.01)
            }
        }
    }
}
