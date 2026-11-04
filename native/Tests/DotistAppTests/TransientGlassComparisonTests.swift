import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

/// Diagnostic captures, never visual acceptance for WindowServer refraction.
/// Keep each case in its own hidden window: compositor effects can clear the
/// entire cacheDisplay target, contaminating siblings on a single large board.
@MainActor
final class TransientGlassComparisonTests: XCTestCase {
    private struct Variant {
        let name: String
        var glass: Glass = .regular
        var tint = "production"
        var interactive = true
        var container = "none"
        var layer = "none"
    }

    private var variants: [Variant] {
        [Variant(name: "production", layer: "production"),
         Variant(name: "regular"),
         Variant(name: "clear", glass: .clear),
         Variant(name: "identity", glass: .identity),
         Variant(name: "regular-no-tint", tint: "none"),
         Variant(name: "regular-weak-tint", tint: "weak"),
         Variant(name: "regular-strong-tint", tint: "strong"),
         Variant(name: "clear-no-tint", glass: .clear, tint: "none"),
         Variant(name: "clear-weak-tint", glass: .clear, tint: "weak"),
         Variant(name: "clear-strong-tint", glass: .clear, tint: "strong"),
         Variant(name: "regular-not-interactive", interactive: false),
         Variant(name: "clear-not-interactive", glass: .clear, interactive: false),
         Variant(name: "regular-separate-containers", container: "separate"),
         Variant(name: "regular-shared-container", container: "shared"),
         Variant(name: "clear-shared-container", glass: .clear, container: "shared"),
         Variant(name: "identity-shared-container", glass: .identity, container: "shared"),
         Variant(name: "diagnostic-paper-overlay", layer: "paper"),
         Variant(name: "diagnostic-double-glass", layer: "double"),
         Variant(name: "diagnostic-double-clip", layer: "clip")]
    }

    private func surface(_ variant: Variant, width: CGFloat, scheme: ColorScheme) -> AnyView {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let tint: Color?
        switch variant.tint {
        case "none": tint = nil
        case "weak": tint = DotistTheme.tint(.orange, scheme).opacity(1.0 / 3)
        case "strong": tint = Color(nsColor: NSColor(DotistTheme.tint(.orange, scheme)).withAlphaComponent(1))
        default: tint = DotistTheme.tint(.orange, scheme)
        }
        let glass = variant.glass.tint(tint).interactive(variant.interactive)
        let bare = Color.clear.frame(width: width, height: 48).glassEffect(glass, in: shape)
        let material: AnyView
        switch variant.layer {
        case "production":
            material = AnyView(FloatingSurface(opacity: 60, frost: 40, compact: true,
                transitioning: false, onRight: true, size: CGSize(width: width, height: 48), reveal: 1, color: .orange))
        case "paper": material = AnyView(bare.overlay(shape.fill(DotistDesign.paper.opacity(0.3))))
        case "double": material = AnyView(bare.glassEffect(glass, in: shape))
        case "clip": material = AnyView(bare.clipShape(shape).clipShape(shape))
        default: material = AnyView(bare)
        }
        return AnyView(ZStack {
            material
            Text(width == 48 ? "7" : "Review the next small thing   7")
                .font(.system(size: width == 48 ? 20 : 13, weight: .medium))
                .foregroundStyle(scheme == .dark ? .white : .black)
        }.frame(width: width, height: 48))
    }

    @ViewBuilder private func pair(_ variant: Variant, scheme: ColorScheme) -> some View {
        if variant.container == "shared" {
            // The 12pt gap is within the explicit 24pt blending distance.
            GlassEffectContainer(spacing: 24) {
                HStack(spacing: 12) { surface(variant, width: 48, scheme: scheme); surface(variant, width: 240, scheme: scheme) }
            }
        } else if variant.container == "separate" {
            HStack(spacing: 12) {
                GlassEffectContainer(spacing: 24) { surface(variant, width: 48, scheme: scheme) }
                GlassEffectContainer(spacing: 24) { surface(variant, width: 240, scheme: scheme) }
            }
        } else {
            HStack(spacing: 12) { surface(variant, width: 48, scheme: scheme); surface(variant, width: 240, scheme: scheme) }
        }
    }

    @ViewBuilder private func backdrop(_ scheme: ColorScheme) -> some View {
        (scheme == .dark ? Color(white: 0.08) : Color(white: 0.90))
        HStack(spacing: 14) {
            ForEach(0..<20) { index in
                Rectangle().fill(index.isMultiple(of: 2) ? Color.orange.opacity(0.45) : Color.blue.opacity(0.45)).frame(width: 10)
            }
        }.rotationEffect(.degrees(18))
    }

    func testNativeMaterialContainerTintInteractionAndLayerComparisons() async throws {
        let output = URL(fileURLWithPath: "/tmp/dotist-glass2")
        let captures = output.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        var records = ["scheme,layout,backdrop,variant,blankAlpha,visible,hostingVisualEffectViews"]
        for scheme in [ColorScheme.light, .dark] {
            for layout in ["pair", "dot", "strip"] {
                var images: [(String, NSBitmapImageRep)] = []
                for variant in variants {
                    for hasBackdrop in [false, true] {
                        let canvas = ZStack {
                            if hasBackdrop { backdrop(scheme) }
                            if layout == "pair" {
                                pair(variant, scheme: scheme)
                            } else if variant.container != "none" {
                                GlassEffectContainer(spacing: 24) {
                                    surface(variant, width: layout == "dot" ? 48 : 240, scheme: scheme)
                                }
                            } else {
                                surface(variant, width: layout == "dot" ? 48 : 240, scheme: scheme)
                            }
                        }.frame(width: 348, height: 96).clipped()
                            .environment(\.colorScheme, scheme)
                            .environment(\._accessibilityReduceTransparency, false)
                            .environment(\._colorSchemeContrast, .standard)
                        let fixture = NativeRenderingFixture(canvas, size: CGSize(width: 348, height: 96))
                        fixture.window.isOpaque = false
                        fixture.window.backgroundColor = .clear
                        fixture.window.hasShadow = true
                        fixture.window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        let bitmap = try await fixture.capture(scale: 2)
                        XCTAssertFalse(fixture.window.isVisible)
                        XCTAssertEqual(bitmap.pixelsWide, 696)
                        XCTAssertEqual(bitmap.pixelsHigh, 192)
                        let name = "\(scheme)-\(layout)-\(variant.name)-backdrop\(hasBackdrop).png"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: captures.appendingPathComponent(name))
                        // Blank point inside the shape, below the text's baseline.
                        let alpha = try XCTUnwrap(bitmap.colorAt(x: (layout == "pair" ? 228 : 174) * 2, y: 64 * 2)).alphaComponent
                        records.append("\(scheme),\(layout),\(hasBackdrop),\(variant.name),\(alpha),\(fixture.window.isVisible),\(fixture.descendants(NSVisualEffectView.self).count)")
                        fixture.close()
                        if hasBackdrop { images.append((variant.name, bitmap)) }
                    }
                }
                try contactSheet(images, layout: layout, scheme: scheme, output: output)
            }
        }
        try records.joined(separator: "\n").write(to: output.appendingPathComponent("captures.csv"), atomically: true, encoding: .utf8)
        print("GLASS2: 228 hidden native captures and 6 contact sheets in \(output.path); compositor optics are unverified")
    }

    private func contactSheet(_ images: [(String, NSBitmapImageRep)], layout: String, scheme: ColorScheme, output: URL) throws {
        // Arrange already captured, unmodified pixels. Labels and this sheet's
        // background are outside the specimen; they are not replacement glass.
        let columns = 3, cellWidth = 744, cellHeight = 250, header = 88
        let rows = (images.count + columns - 1) / columns
        let sheet = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: columns * cellWidth,
            pixelsHigh: rows * cellHeight + header, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: sheet))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let bounds = NSRect(x: 0, y: 0, width: sheet.pixelsWide, height: sheet.pixelsHigh)
        (scheme == .dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
        bounds.fill()
        let ink = scheme == .dark ? NSColor.white : NSColor.black
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: ink]
        ("\(scheme) / \(layout) | Hidden captures | Glass may be absent; NOT desktop visual acceptance" as NSString)
            .draw(at: NSPoint(x: 24, y: sheet.pixelsHigh - 42), withAttributes: attrs)
        for (index, item) in images.enumerated() {
            let x = (index % columns) * cellWidth + 24
            let y = sheet.pixelsHigh - header - (index / columns + 1) * cellHeight
            (item.0 as NSString).draw(at: NSPoint(x: x, y: y + 214), withAttributes: attrs)
            let captured = NSImage(cgImage: try XCTUnwrap(item.1.cgImage), size: NSSize(width: 696, height: 192))
            captured.draw(in: NSRect(x: x, y: y + 12, width: 696, height: 192),
                from: .zero, operation: .sourceOver, fraction: 1)
        }
        try XCTUnwrap(sheet.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("comparison-\(layout)-\(scheme).png"))
    }
}
