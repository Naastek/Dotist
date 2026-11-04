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
        XCTAssertEqual(original.combination, "glass-v1;style=regular;interactive=true;tint=original;container=false;spacing=24;shape=continuous;radius=24;removeOverlay=true;hasShadow=true;effectID=false")
        var variants = GlassDebugParameters.Preset.allCases.map(\.parameters)
        for option in GlassDebugParameters.Style.allCases { var p = original; p.style = option; variants.append(p) }
        for option in GlassDebugParameters.Tint.allCases { var p = original; p.tint = option; variants.append(p) }
        for option in GlassDebugParameters.Shape.allCases { var p = original; p.shape = option; variants.append(p) }
        for option in GlassDebugParameters.Spacing.allCases { var p = original; p.spacing = option; variants.append(p) }
        for option in GlassDebugParameters.Radius.allCases { var p = original; p.radius = option; variants.append(p) }
        for key in [\GlassDebugParameters.interactive, \.container, \.removeOverlay, \.hasShadow, \.effectID] {
            var p = original; p[keyPath: key].toggle(); variants.append(p)
        }
        for variant in variants {
            let decoded = try JSONDecoder().decode(GlassDebugParameters.self, from: JSONEncoder().encode(variant))
            XCTAssertEqual(decoded, variant)
            XCTAssertEqual(decoded.combination, variant.combination)
            XCTAssertEqual(variant.combination == original.combination, variant == original)
            XCTAssertEqual(variant.combination.split(separator: ";").count, 11)
        }
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
        // Exercise every override together, including the diagnostic paper layer.
        var parameters = GlassDebugParameters.Preset.clear.parameters
        parameters.removeOverlay = false
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

    func testDebugOverlayActuallyReachesCompactSurface() throws {
        var parameters = GlassDebugParameters()
        parameters.removeOverlay = false
        parameters.tint = .none
        let debug = try bitmap(FloatingPanelSurface(opacity: 8, frost: 4, compact: true,
            color: .none, solid: false, scheme: .light)
            .frame(width: 160, height: 48).environment(\.glassDebugParameters, parameters))
        XCTAssertGreaterThan(try XCTUnwrap(debug.colorAt(x: 160, y: 48)).alphaComponent, 0.1)
    }
}
