import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class TransientGlassEdgeTests: XCTestCase {
    /// Compositor glass is not guaranteed to appear in cacheDisplay. These are
    /// evidence captures, not a visual acceptance test for desktop refraction.
    func testOffscreenProductionVersusBareNativeGlassMatrix() async throws {
        let phase = ProcessInfo.processInfo.environment["DOTIST_GLASS_PHASE"] ?? "after"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent(".cache/glass-edge-polish/native-edge").appendingPathComponent(phase)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var records = ["scheme,width,backdrop,tint,variant,centerAlpha"]
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(48), 240] {
                for backdrop in [false, true] {
                    for color in [DotistGroupColor.none, .orange] {
                        for variant in ["production", "legacy-double-clip", "bare-regular", "matched-regular", "bare-clear", "container"] {
                            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
                            let size = CGSize(width: width, height: 48)
                            let tint: Color? = color == .none ? nil : DotistTheme.tint(color, scheme)
                            let surface = FloatingSurface(opacity: 60, frost: 40, compact: true,
                                transitioning: false, onRight: true, size: size, reveal: 1, color: color)
                            let material: AnyView
                            switch variant {
                            case "production": material = AnyView(surface)
                            case "legacy-double-clip":
                                material = AnyView(Color.clear.glassEffect(.regular.tint(tint).interactive(), in: shape)
                                    .clipShape(shape).clipShape(shape))
                            case "bare-regular": material = AnyView(Color.clear.glassEffect(.regular, in: shape))
                            case "matched-regular": material = AnyView(Color.clear.glassEffect(.regular.tint(tint).interactive(), in: shape))
                            case "bare-clear": material = AnyView(Color.clear.glassEffect(.clear, in: shape))
                            default:
                                material = AnyView(GlassEffectContainer { Color.clear.glassEffect(.regular.tint(tint).interactive(), in: shape) })
                            }
                            let canvas = ZStack {
                                if backdrop {
                                    (scheme == .dark ? Color(white: 0.08) : Color(white: 0.88))
                                    HStack(spacing: 10) {
                                        ForEach(0..<18) { index in
                                            Rectangle().fill(index.isMultiple(of: 2) ? Color.orange.opacity(0.6) : Color.blue.opacity(0.6))
                                                .frame(width: 9)
                                        }
                                    }.rotationEffect(.degrees(18))
                                }
                                ZStack {
                                    material
                                    Text(width == 48 ? "7" : "Review the next small thing   7")
                                        .font(.system(size: width == 48 ? 20 : 13, weight: .medium))
                                        .foregroundStyle(scheme == .dark ? .white : .black)
                                }.frame(width: width, height: 48)
                            }.frame(width: width + 48, height: 96).clipped()
                                .environment(\.colorScheme, scheme)
                                .environment(\._accessibilityReduceTransparency, false)
                                .environment(\._colorSchemeContrast, .standard)
                            let fixture = NativeRenderingFixture(canvas, size: CGSize(width: width + 48, height: 96))
                            fixture.window.isOpaque = false
                            fixture.window.backgroundColor = .clear
                            let image = try await fixture.capture(scale: 2)
                            XCTAssertFalse(fixture.window.isVisible)
                            fixture.close()
                            XCTAssertEqual(image.pixelsWide, Int((width + 48) * 2))
                            let name = "\(scheme)-\(Int(width))-backdrop\(backdrop)-\(color)-\(variant).png"
                            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
                            // Blank area below the ink, inside the material.
                            let alpha = try XCTUnwrap(image.colorAt(x: Int((24 + width / 2) * 2), y: 124)).alphaComponent
                            records.append("\(scheme),\(width),\(backdrop),\(color),\(variant),\(alpha)")
                        }
                    }
                }
            }
        }
        try records.joined(separator: "\n").write(to: output.appendingPathComponent("captures.csv"), atomically: true, encoding: .utf8)
        print("GLASS EDGE EVIDENCE: \(output.path); not desktop visual acceptance")
    }
}
