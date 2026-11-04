import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class TransientGlassDebugTests: XCTestCase {
    func testOnlyExactEnvironmentOptInEnablesDebug() {
        for value in [nil, "", "0", "true", "01", "1 "] as [String?] {
            XCTAssertFalse(GlassDebugState(environment: value.map { ["DOTIST_GLASS_DEBUG": $0] } ?? [:]).enabled)
        }
        XCTAssertTrue(GlassDebugState(environment: ["DOTIST_GLASS_DEBUG": "1"]).enabled)
    }

    func testStableCompleteCombinationAndAllParameterEnumsEncode() throws {
        let original = GlassDebugParameters()
        XCTAssertEqual(original.combination, "glass-v1;style=regular;interactive=true;tint=original;container=false;spacing=24;shape=continuous;radius=24;tintLayer=0;hasShadow=true;effectID=false")
        var variants = GlassDebugParameters.Preset.allCases.map(\.parameters)
        for option in GlassDebugParameters.Style.allCases { var p = original; p.style = option; variants.append(p) }
        for option in GlassDebugParameters.Tint.allCases { var p = original; p.tint = option; variants.append(p) }
        for option in GlassDebugParameters.TintLayer.allCases { var p = original; p.tintLayer = option; variants.append(p) }
        for option in GlassDebugParameters.Shape.allCases { var p = original; p.shape = option; variants.append(p) }
        for option in GlassDebugParameters.Spacing.allCases { var p = original; p.spacing = option; variants.append(p) }
        for option in GlassDebugParameters.Radius.allCases { var p = original; p.radius = option; variants.append(p) }
        for key in [\GlassDebugParameters.interactive, \.container, \.hasShadow, \.effectID] {
            var p = original; p[keyPath: key].toggle(); variants.append(p)
        }
        for variant in variants {
            let decoded = try JSONDecoder().decode(GlassDebugParameters.self, from: JSONEncoder().encode(variant))
            XCTAssertEqual(decoded, variant)
            XCTAssertEqual(GlassDebugParameters(combination: variant.combination), variant)
            XCTAssertEqual(decoded.combination, variant.combination)
            XCTAssertEqual(variant.combination == original.combination, variant == original)
            XCTAssertEqual(variant.combination.split(separator: ";").count, 11)
        }
        XCTAssertNil(GlassDebugParameters(combination: original.combination.replacingOccurrences(of: "tintLayer=0", with: "tintLayer=7")))
        XCTAssertEqual(Set(GlassDebugParameters.Preset.allCases.map { $0.parameters.combination }).count, 3)
        XCTAssertEqual(GlassDebugParameters.Preset.production.parameters, original)
        XCTAssertEqual(GlassDebugParameters.Tint.allCases.map(\.scale), [0, 1.0 / 3, 2.0 / 3, 1])
    }

    func testLiveShadowSwitchCoversExistingAndNewPanelsWithoutChangingCollectionBehavior() {
        _ = NSApplication.shared
        let state = GlassDebugState(environment: ["DOTIST_GLASS_DEBUG": "1"])
        let first = NSPanel(), second = NSPanel()
        first.collectionBehavior = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        let collection = first.collectionBehavior
        state.register(first)
        XCTAssertTrue(first.hasShadow)
        state.parameters.hasShadow = false
        XCTAssertFalse(first.hasShadow)
        state.register(second)
        XCTAssertFalse(second.hasShadow)
        state.parameters = GlassDebugParameters.Preset.production.parameters
        XCTAssertTrue(first.hasShadow)
        XCTAssertTrue(second.hasShadow)
        XCTAssertEqual(first.collectionBehavior, collection)
        state.unregister(first)
        state.parameters.hasShadow = false
        XCTAssertTrue(first.hasShadow)
        XCTAssertFalse(second.hasShadow)
        let disabled = GlassDebugState(environment: [:])
        disabled.register(first)
        disabled.parameters.hasShadow = false
        XCTAssertTrue(first.hasShadow)
    }

    private func bitmap<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    func testCompactDebugOverridesRespectBothAccessibilityFallbacksAndExpandedSurface() throws {
        // Exercise every override together, including the diagnostic tint layer.
        var parameters = GlassDebugParameters.Preset.clear.parameters
        parameters.tintLayer = .heavy
        parameters.radius = .small
        parameters.hasShadow = false
        for scheme in [ColorScheme.light, .dark] {
            for protection in 0...2 {
                for compact in [false, true] where protection > 0 || !compact {
                    let surface = FloatingSurface(opacity: 60, frost: 40, compact: compact,
                        transitioning: false, onRight: true, size: CGSize(width: 160, height: 48),
                        reveal: 0.4, color: .orange)
                        .frame(width: 160, height: 48)
                        .environment(\.colorScheme, scheme)
                        .environment(\._accessibilityReduceTransparency, protection == 1)
                        .environment(\._colorSchemeContrast, protection == 2 ? .increased : .standard)
                    let baseline = try bitmap(surface)
                    let debug = try bitmap(surface.environment(\.glassDebugParameters, parameters))
                    XCTAssertEqual(baseline.pixelsWide, debug.pixelsWide)
                    for y in 0..<baseline.pixelsHigh {
                        for x in 0..<baseline.pixelsWide {
                            let a = try XCTUnwrap(baseline.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                            let b = try XCTUnwrap(debug.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                            XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 0.001)
                            for (left, right) in [(a.redComponent, b.redComponent), (a.greenComponent, b.greenComponent), (a.blueComponent, b.blueComponent)] {
                                XCTAssertEqual(left * a.alphaComponent, right * b.alphaComponent, accuracy: 0.001)
                            }
                        }
                    }
                }
            }
        }
    }

    func testTintLayerReachesCompactSurfaceAndRequiresGroupColor() throws {
        var parameters = GlassDebugParameters()
        parameters.tint = .none
        func render(_ color: DotistGroupColor, _ layer: GlassDebugParameters.TintLayer) throws -> NSBitmapImageRep {
            var options = parameters
            options.tintLayer = layer
            return try bitmap(FloatingPanelSurface(opacity: 8, frost: 4, compact: true,
                color: color, solid: false, scheme: .light)
                .frame(width: 160, height: 48).environment(\.glassDebugParameters, options))
        }
        func center(_ image: NSBitmapImageRep) throws -> NSColor {
            try XCTUnwrap(image.colorAt(x: 160, y: 48)?.usingColorSpace(.sRGB))
        }
        let production = try center(bitmap(FloatingPanelSurface(opacity: 8, frost: 4, compact: true,
            color: .orange, solid: false, scheme: .light).frame(width: 160, height: 48)))
        var defaultOptions = GlassDebugParameters()
        defaultOptions.tintLayer = .none
        let zero = try center(bitmap(FloatingPanelSurface(opacity: 8, frost: 4, compact: true,
            color: .orange, solid: false, scheme: .light).frame(width: 160, height: 48)
            .environment(\.glassDebugParameters, defaultOptions)))
        XCTAssertEqual(production.alphaComponent, zero.alphaComponent, accuracy: 0.001)
        for (a, b) in [(production.redComponent, zero.redComponent),
                       (production.greenComponent, zero.greenComponent),
                       (production.blueComponent, zero.blueComponent)] {
            XCTAssertEqual(a * production.alphaComponent, b * zero.alphaComponent, accuracy: 0.001)
        }
        let baseline = try center(render(.orange, .none))
        let tinted = try center(render(.orange, .heavy))
        let differences = [(tinted.redComponent, baseline.redComponent),
                           (tinted.greenComponent, baseline.greenComponent),
                           (tinted.blueComponent, baseline.blueComponent)].map { tintedChannel, baselineChannel in
            abs(tintedChannel * tinted.alphaComponent - baselineChannel * baseline.alphaComponent)
        }
        XCTAssertGreaterThan(try XCTUnwrap(differences.max()), 0.05)
        let noColor = try center(render(.none, .none))
        for layer in GlassDebugParameters.TintLayer.allCases {
            let noColorTinted = try center(render(.none, layer))
            XCTAssertEqual(noColor.alphaComponent, noColorTinted.alphaComponent, accuracy: 0.001)
            for (a, b) in [(noColor.redComponent, noColorTinted.redComponent),
                           (noColor.greenComponent, noColorTinted.greenComponent),
                           (noColor.blueComponent, noColorTinted.blueComponent)] {
                XCTAssertEqual(a * noColor.alphaComponent, b * noColorTinted.alphaComponent, accuracy: 0.001)
            }
        }
    }
}
