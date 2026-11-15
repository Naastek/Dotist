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

    func testGlassAndReadingCompositionAtEachOpacity() async throws {
        _ = NSApplication.shared
        let radius = DotistDesign.windowCornerRadius - ExpandedReadingMaterial.opticalClearance
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        for scheme in [ColorScheme.light, .dark] {
            for opacity: UInt8 in [0, 4, 38, 80, 95, 100] {
                let amount = DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false)
                let glassAlpha = 1 - 0.6 * (1 - amount)
                let control = ZStack {
                    Color.clear.dotistGlass(.regular.tint(DotistTheme.tint(.pink, scheme)), in: shape)
                        .mask {
                            Color.white.overlay {
                                shape.inset(by: 3).fill(.white).blur(radius: 1)
                                    .clipShape(shape.inset(by: 1))
                                    .opacity(1 - glassAlpha).blendMode(.destinationOut)
                            }.compositingGroup()
                        }
                    ReadingDensityContract(opacity: opacity, frost: 40, color: .pink, scheme: scheme, cornerRadius: radius)
                    GlassGloss(shape: shape.inset(by: GlassSilhouette.glassClip), intensity: .expanded, scheme: scheme)
                }.clipShape(shape.inset(by: GlassSilhouette.glassClip)).padding(ExpandedReadingMaterial.opticalClearance).environment(\.colorScheme, scheme)
                let reference = NativeRenderingFixture(control, size: size)
                reference.window.isOpaque = false; reference.window.backgroundColor = .clear
                let expected = try await reference.capture(scale: 1)
                reference.close()
                let content = Text("Readable sample text").font(.system(size: 16)).foregroundStyle(DotistDesign.ink)
                    .frame(width: 300, height: 120)
                    .background(FloatingPanelSurface(opacity: opacity, frost: 40, compact: false,
                        color: .pink, solid: false, scheme: scheme)).environment(\.colorScheme, scheme)
                let fixture = NativeRenderingFixture(content, size: size)
                fixture.window.isOpaque = false; fixture.window.backgroundColor = .clear
                let actual = try await fixture.capture(scale: 1)
                fixture.close()
                for (x, y) in [(60, 25), (150, 25), (240, 95)] {
                    let a = try XCTUnwrap(actual.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let b = try XCTUnwrap(expected.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 0.015)
                    for (aa, bb) in [(a.redComponent, b.redComponent), (a.greenComponent, b.greenComponent), (a.blueComponent, b.blueComponent)] {
                        XCTAssertEqual(aa * a.alphaComponent, bb * b.alphaComponent, accuracy: 0.015)
                    }
                }
                var maxInk: CGFloat = 0
                for y in 45..<75 { for x in 60..<240 { maxInk = max(maxInk, actual.colorAt(x: x, y: y)?.alphaComponent ?? 0) } }
                XCTAssertGreaterThan(maxInk, 0.9, "Background opacity must not fade foreground text")
            }
        }
    }

    func testApprovedReadingDensityEndpointsAndIntermediateSamples() throws {
        // Frozen numeric source-over alpha table for 12% frost and 16%/18% wash.
        // The production helper/constants are deliberately not used as the oracle.
        let samples: [(UInt8, UInt8, Double, Double)] = [
            (0, 0, 0.0000000000, 0.0000000000),
            (0, 40, 0.0000000000, 0.0000000000),
            (0, 100, 0.0000000000, 0.0000000000),
            (4, 0, 0.0461440000, 0.0469120000),
            (4, 40, 0.0479754035, 0.0487419290),
            (4, 100, 0.0507225088, 0.0514868224),
            (38, 0, 0.4176960000, 0.4224080000),
            (38, 40, 0.4283172250, 0.4329432781),
            (38, 100, 0.4442490624, 0.4487461952),
            (80, 0, 0.8256000000, 0.8288000000),
            (80, 40, 0.8322969600, 0.8353740800),
            (80, 100, 0.8423424000, 0.8452352000),
            (95, 0, 0.9576000000, 0.9585500000),
            (95, 40, 0.9595334400, 0.9604401200),
            (95, 100, 0.9624336000, 0.9632753000),
            (100, 0, 1.0000000000, 1.0000000000),
            (100, 40, 1.0000000000, 1.0000000000),
            (100, 100, 1.0000000000, 1.0000000000),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (opacity, frost, light, dark) in samples {
                let paint = ExpandedReadingMaterial(opacity: opacity, frost: frost, color: .pink,
                    scheme: scheme, cornerRadius: 18).environment(\.colorScheme, scheme)
                let bitmap = try fixedBitmap(paint)
                let actual = try XCTUnwrap(bitmap.colorAt(x: 300, y: 120)).alphaComponent
                XCTAssertEqual(actual, scheme == .dark ? dark : light, accuracy: 0.015,
                    "Approved linear paper/frost/wash: \(scheme), opacity=\(opacity), frost=\(frost)")
            }
            for opacity: UInt8 in [0, 4, 38, 80, 95, 100] {
                let bitmap = try fixedBitmap(ExpandedReadingMaterial(opacity: opacity, frost: 0,
                    color: .none, scheme: scheme, cornerRadius: 18).environment(\.colorScheme, scheme))
                XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 300, y: 120)).alphaComponent,
                    Double(opacity) / 100, accuracy: 0.015, "Paper density is linear, never squared")
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
