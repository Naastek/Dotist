import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

/// Compare the same shapes through independent rendering paths. The CSV is
/// evidence, not a replacement for the strict production pixel assertions.
@MainActor
final class NativePixelPathDiagnosticsTests: XCTestCase {
    func testCompareWindowAndRendererShapePaths() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/integration-install/pixel-evidence/path-comparison")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var records = ["case,path,width,height,x,y,red,green,blue,alpha,centerRed,centerGreen,centerBlue,centerAlpha"]
        let size = CGSize(width: 280, height: 48)
        let shape = FloatingPanelShape(compact: true, transitioning: false, onRight: false, reveal: 0)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        defer { panel.close() }
        let candidates: [(String, AnyView)] = [
            ("reference-fill", AnyView(shape.fill(Color.white).frame(width: size.width, height: size.height))),
            ("reference-clip", AnyView(Color.white.clipShape(shape).frame(width: size.width, height: size.height))),
            ("production-solid", AnyView(FloatingSurface(opacity: 73, frost: 22, compact: true, transitioning: false, onRight: false, size: size, reveal: 0, color: .orange).environment(\._accessibilityReduceTransparency, true)))
        ]
        for (name, view) in candidates {
            let host = DotistHostingView(rootView: view); host.sizingOptions = []; panel.contentView = host
            host.frame = CGRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(35))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let renderer = ImageRenderer(content: view); renderer.scale = CGFloat(bitmap.pixelsWide) / size.width
            let rendered = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            for (path, image) in [("window", bitmap), ("renderer", rendered)] {
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("panel-\(name)-\(path).png"))
                let scale = CGFloat(image.pixelsWide) / size.width
                let center = try XCTUnwrap(image.colorAt(x: Int(24 * scale), y: Int(24 * scale))?.usingColorSpace(.deviceRGB))
                for y in 0..<image.pixelsHigh { for x in 0..<min(image.pixelsWide, Int(50 * scale)) {
                    let pixel = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if pixel.alphaComponent > 0 {
                        records.append("\(name),\(path),\(image.pixelsWide),\(image.pixelsHigh),\(x),\(y),\(pixel.redComponent),\(pixel.greenComponent),\(pixel.blueComponent),\(pixel.alphaComponent),\(center.redComponent),\(center.greenComponent),\(center.blueComponent),\(center.alphaComponent)")
                    }
                } }
            }
        }
        // Recreate the exact uneven shape at the dimensions of the host's
        // unselected expanded tab. Compare an opaque flat fill against the
        // same fill with a compositing group, in both native appearances.
        for scheme in [ColorScheme.light, .dark] {
            let shape = UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
            let fill = DotistDesign.paper.mix(with: DotistDesign.ink, by: 0.06, in: .device)
            for grouped in [false, true] {
                let view = AnyView(Group { if grouped { shape.fill(fill).compositingGroup() } else { shape.fill(fill) } }
                    .frame(width: 179, height: 34).environment(\.colorScheme, scheme))
                let renderer = ImageRenderer(content: view); renderer.scale = 1
                var cg: CGImage?
                NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { cg = renderer.cgImage }
                let image = NSBitmapImageRep(cgImage: try XCTUnwrap(cg))
                let center = try XCTUnwrap(image.colorAt(x: 89, y: 17)?.usingColorSpace(.deviceRGB))
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("tab-\(scheme)-grouped-\(grouped).png"))
                for y in 0..<image.pixelsHigh { for x in 0..<image.pixelsWide {
                    let pixel = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if pixel.alphaComponent > 0 {
                        records.append("tab-\(scheme)-grouped-\(grouped),renderer,\(image.pixelsWide),\(image.pixelsHigh),\(x),\(y),\(pixel.redComponent),\(pixel.greenComponent),\(pixel.blueComponent),\(pixel.alphaComponent),\(center.redComponent),\(center.greenComponent),\(center.blueComponent),\(center.alphaComponent)")
                    }
                } }
            }
        }
        try records.joined(separator: "\n").write(to: output.appendingPathComponent("paths.csv"), atomically: true, encoding: .utf8)
        print("PIXEL PATH COMPARISON \(output.path), screens=\(NSScreen.screens.count)")
    }
}
