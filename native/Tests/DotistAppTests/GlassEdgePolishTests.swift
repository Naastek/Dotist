import AppKit
import SwiftUI
import XCTest
@testable import DotistApp

/// Only the actual SwiftUI edge pixels are compared here. ImageRenderer does
/// not establish WindowServer glass refraction or the native window shadow.
@MainActor
final class GlassEdgePolishTests: XCTestCase {
    private struct Specimen: Identifiable {
        let id: String
        let size: CGSize
        let compact: Bool
        var radius: CGFloat { compact ? 24 : DotistDesign.windowCornerRadius }
    }
    private let specimens = [
        Specimen(id: "ball", size: CGSize(width: 48, height: 48), compact: true),
        Specimen(id: "strip", size: CGSize(width: 240, height: 48), compact: true),
        Specimen(id: "panel", size: CGSize(width: 364, height: 620), compact: false)
    ]

    // Exact b079d6a edge treatment; the expanded surface had no edge layer.
    private func previous(_ specimen: Specimen) -> some View {
        let shape = RoundedRectangle(cornerRadius: specimen.radius, style: .continuous)
        let light = LinearGradient(stops: [
            .init(color: .white.opacity(0.85), location: 0),
            .init(color: .white.opacity(0.55), location: 0.20),
            .init(color: .white.opacity(0.04), location: 0.52),
            .init(color: .white.opacity(0.12), location: 0.78),
            .init(color: .white.opacity(0.38), location: 1)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
        return ZStack {
            if specimen.compact {
                shape.strokeBorder(light, lineWidth: 1.25)
                shape.inset(by: 2).strokeBorder(light.opacity(0.38), lineWidth: 4)
                    .blur(radius: 2).clipShape(shape)
            }
        }.frame(width: specimen.size.width, height: specimen.size.height)
    }

    private func current(_ specimen: Specimen, _ scheme: ColorScheme) -> some View {
        GlassEdge(cornerRadius: specimen.radius, compact: specimen.compact, scheme: scheme)
            .frame(width: specimen.size.width, height: specimen.size.height)
    }

    private func bitmap<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func sample(_ image: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        XCTAssertTrue((0..<image.pixelsWide).contains(x) && (0..<image.pixelsHigh).contains(y),
            "Sample (\(x), \(y)) outside \(image.pixelsWide)x\(image.pixelsHigh)")
        guard (0..<image.pixelsWide).contains(x), (0..<image.pixelsHigh).contains(y) else {
            throw NSError(domain: "GlassEdgePolishTests.sample", code: 1)
        }
        return try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    /// Use a known, cleared pixel buffer even when ImageRenderer optimizes an
    /// entirely transparent cgImage. Coordinates are always 2 pixels per point.
    private func fixedBitmap<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let scale: CGFloat = 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: info))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.render { _, draw in draw(context) }
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        XCTAssertEqual(image.pixelsWide, width)
        XCTAssertEqual(image.pixelsHigh, height)
        XCTAssertTrue(image.hasAlpha)
        return image
    }

    private func logRendererMetadata<V: View>(_ view: V, label: String) throws {
        let renderer = ImageRenderer(content: view); renderer.scale = 2
        let raw = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: raw)
        print("GLASS BITMAP CONTROL: \(label) cg=\(raw.width)x\(raw.height) alphaInfo=\(raw.alphaInfo.rawValue) bytesPerRow=\(raw.bytesPerRow) rep=\(rep.pixelsWide)x\(rep.pixelsHigh) hasAlpha=\(rep.hasAlpha) bytesPerRow=\(rep.bytesPerRow)")
    }

    func testTransparentBitmapControlsAndRendererMetadata() throws {
        let size = CGSize(width: 12, height: 10)
        let controls: [(String, Color, CGFloat)] = [
            ("clear", .clear, 0), ("black-zero", .black.opacity(0), 0),
            ("black-half", .black.opacity(0.5), 0.5), ("black-solid", .black, 1)
        ]
        for (name, color, expected) in controls {
            let view = color.frame(width: size.width, height: size.height)
            try logRendererMetadata(view, label: name)
            let fixed = try fixedBitmap(view, size: size)
            let pixel = try sample(fixed, x: 12, y: 10)
            XCTAssertEqual(pixel.alphaComponent, expected, accuracy: 0.01, "Fixed RGBA control: \(name)")
            if expected > 0 { XCTAssertLessThan(pixel.redComponent, 0.01, "Black control must remain black") }
        }
    }

    func testProductionEdgesDifferFromBaselineAndLeaveInteriorClear() throws {
        for scheme in [ColorScheme.light, .dark] {
            for specimen in specimens {
                let old = try bitmap(previous(specimen))
                let new = try bitmap(current(specimen, scheme))
                let center = try sample(new, x: new.pixelsWide / 2, y: new.pixelsHigh / 2)
                XCTAssertLessThan(center.alphaComponent, 0.01, "\(scheme) \(specimen.id) center")
                var difference: CGFloat = 0
                var edgeAlpha: CGFloat = 0
                for y in stride(from: 0, to: new.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: new.pixelsWide, by: 2) {
                        let a = try sample(old, x: x, y: y)
                        let b = try sample(new, x: x, y: y)
                        difference += abs(a.alphaComponent - b.alphaComponent)
                            + abs(a.redComponent * a.alphaComponent - b.redComponent * b.alphaComponent)
                        edgeAlpha = max(edgeAlpha, b.alphaComponent)
                    }
                }
                XCTAssertGreaterThan(difference, 5, "The production pixels must differ from b079d6a")
                XCTAssertGreaterThan(edgeAlpha, 0.15, "The edge must be visible")
            }
        }
    }

    func testEdgeContainsOnlyWhitePigment() throws {
        for scheme in [ColorScheme.light, .dark] {
            for specimen in specimens {
                let image = try fixedBitmap(current(specimen, scheme), size: specimen.size)
                var checked = 0
                for y in 0..<image.pixelsHigh {
                    for x in 0..<image.pixelsWide {
                        let pixel = try sample(image, x: x, y: y)
                        guard pixel.alphaComponent >= 0.1 else { continue }
                        checked += 1
                        // Ignore nearly transparent pixels, where unpremultiplication amplifies rounding.
                        XCTAssertGreaterThan(pixel.redComponent, 0.95, "Black pigment: \(scheme) \(specimen.id) (\(x), \(y))")
                        XCTAssertGreaterThan(pixel.greenComponent, 0.95)
                        XCTAssertGreaterThan(pixel.blueComponent, 0.95)
                    }
                }
                XCTAssertGreaterThan(checked, 0, "Must inspect visible edge pixels")
            }
        }
    }

    func testExpandedOpacityEndpointsAndOpaqueAccessibilityFallback() throws {
        for scheme in [ColorScheme.light, .dark] {
            for compact in [false, true] {
                let size = compact ? CGSize(width: 240, height: 48) : CGSize(width: 364, height: 620)
                for opacity in [UInt8(0), 100] {
                    for solid in [false, true] {
                        let image = try fixedBitmap(FloatingPanelSurface(opacity: opacity, frost: 40, compact: compact,
                            color: .orange, solid: solid, scheme: scheme)
                            .frame(width: size.width, height: size.height).environment(\.colorScheme, scheme), size: size)
                        let center = try sample(image, x: image.pixelsWide / 2, y: image.pixelsHigh / 2)
                        if solid { XCTAssertEqual(center.alphaComponent, 1, accuracy: 0.01) }
                        if !compact && !solid && opacity == 100 { XCTAssertGreaterThan(center.alphaComponent, 0.1) }
                    }
                }
            }
        }
    }

    func testExpandedNativeGlassAgainstInteriorStrengthControl() throws {
        let size = CGSize(width: 364, height: 620)
        let shape = RoundedRectangle(cornerRadius: DotistDesign.windowCornerRadius, style: .continuous)
        for scheme in [ColorScheme.light, .dark] {
            for opacity in [UInt8(0), 100] {
                let amount = DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false)
                // Interior glass with reading planes, without the edge.
                let control = Color.clear.glassEffect(.regular.tint(DotistTheme.tint(.orange, scheme)), in: shape)
                    .opacity(1 - 0.6 * (1 - amount))
                    .overlay(DotistDesign.paper.opacity(amount * amount))
                    .overlay(DotistDesign.paper.opacity(0.4 * GlassTintMaterial.expandedFrostScale * amount))
                    .overlay(DotistTheme.swatch(.orange).opacity((scheme == .dark ? GlassTintMaterial.expandedDarkTint : GlassTintMaterial.expandedLightTint) * amount))
                    .clipShape(shape)
                    .frame(width: size.width, height: size.height).environment(\.colorScheme, scheme)
                let actual = FloatingPanelSurface(opacity: opacity, frost: 40, compact: false,
                    color: .orange, solid: false, scheme: scheme)
                    .frame(width: size.width, height: size.height).environment(\.colorScheme, scheme)
                try logRendererMetadata(control, label: "baseline-\(scheme)-\(opacity)")
                try logRendererMetadata(actual, label: "current-\(scheme)-\(opacity)")
                let expectedAlpha = try sample(fixedBitmap(control, size: size), x: 364, y: 620).alphaComponent
                let actualAlpha = try sample(fixedBitmap(actual, size: size), x: 364, y: 620).alphaComponent
                print("GLASS OPACITY CONTROL: scheme=\(scheme), opacity=\(opacity), baseline=\(expectedAlpha), current=\(actualAlpha)")
                XCTAssertEqual(actualAlpha, expectedAlpha, accuracy: 0.01,
                    "The added edge must not alter the center; compare native offscreen glass with the interior-strength control")
            }
        }
    }

    func testExpandedEdgeObeysOpacityEndpointsWithoutNativeGlass() throws {
        for scheme in [ColorScheme.light, .dark] {
            for opacity in [UInt8(0), 100] {
                let amount = DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: false)
                let edge = GlassEdge(cornerRadius: DotistDesign.windowCornerRadius, compact: false, scheme: scheme)
                    .frame(width: 364, height: 620).opacity(amount)
                try logRendererMetadata(edge, label: "edge-\(scheme)-\(opacity)")
                let image = try fixedBitmap(edge, size: CGSize(width: 364, height: 620))
                var peak: CGFloat = 0
                for y in 0..<8 {
                    for x in stride(from: 80, to: 240, by: 2) {
                        peak = max(peak, try sample(image, x: x, y: y).alphaComponent)
                    }
                }
                if opacity == 0 { XCTAssertLessThan(peak, 0.01, "The controlled edge must disappear at zero opacity") }
                else { XCTAssertGreaterThan(peak, 0.1, "The controlled edge must be visible at full opacity") }
            }
        }
    }

    func testAccessibilityEnvironmentSelectsOpaqueSurface() throws {
        for scheme in [ColorScheme.light, .dark] {
            for compact in [false, true] {
                let size = compact ? CGSize(width: 48, height: 48) : CGSize(width: 364, height: 620)
                for reducedTransparency in [false, true] {
                    let image = try bitmap(FloatingPanelMaterial(opacity: 0, frost: 0, compact: compact, color: .orange)
                        .frame(width: size.width, height: size.height)
                        .environment(\.colorScheme, scheme)
                        .environment(\._accessibilityReduceTransparency, reducedTransparency)
                        .environment(\._colorSchemeContrast, reducedTransparency ? .standard : .increased))
                    XCTAssertEqual(try sample(image, x: image.pixelsWide / 2, y: image.pixelsHigh / 2).alphaComponent,
                        1, accuracy: 0.01)
                }
            }
        }
    }

    func testWriteBeforeAfterEdgeComparison() throws {
        // A patterned, two-colour backdrop makes transparent edge pixels legible.
        // The specimen is the production edge view itself, not a substitute.
        let board = VStack(alignment: .leading, spacing: 12) {
            Text("b079d6a → current | edge layers only | offscreen: native glass and system shadow unverified")
                .font(.system(size: 14, weight: .semibold))
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(self.specimens) { specimen in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(scheme == .dark ? "dark" : "light") / \(specimen.id) / before → after")
                                .font(.system(size: 11))
                            HStack(spacing: 4) {
                                self.comparisonCell(specimen, scheme: scheme, after: false)
                                self.comparisonCell(specimen, scheme: scheme, after: true)
                            }
                        }
                    }
                }
            }
        }.padding(12).background(Color(white: 0.85))
        let image = try bitmap(board)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent(".cache/glass-edge-polish")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("edge-before-after.png"))
        print("GLASS EDGE POLISH: \(output.path)/edge-before-after.png (offscreen edges only)")
    }

    private func comparisonCell(_ specimen: Specimen, scheme: ColorScheme, after: Bool) -> some View {
        ZStack {
            (scheme == .dark ? Color(white: 0.12) : Color(white: 0.88))
            HStack(spacing: 0) {
                Color.orange.opacity(0.30)
                Color.blue.opacity(0.30)
            }
            if after { current(specimen, scheme) } else { previous(specimen) }
        }.frame(width: specimen.size.width, height: specimen.size.height).clipped()
    }
}
