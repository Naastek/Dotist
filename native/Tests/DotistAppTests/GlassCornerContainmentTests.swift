import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class GlassCornerContainmentTests: XCTestCase {
    func testEffectiveScalePreservesFractionalAndIntegerMonitorScales() {
        XCTAssertEqual(LiquidGlassOpticsRenderer.effectiveScale(for: 0.5), 1.0)
        XCTAssertEqual(LiquidGlassOpticsRenderer.effectiveScale(for: 1.0), 1.0)
        XCTAssertEqual(LiquidGlassOpticsRenderer.effectiveScale(for: 1.25), 1.25)
        XCTAssertEqual(LiquidGlassOpticsRenderer.effectiveScale(for: 1.5), 1.5)
        XCTAssertEqual(LiquidGlassOpticsRenderer.effectiveScale(for: 2.0), 2.0)
        XCTAssertEqual(LiquidGlassOpticsRenderer.effectiveScale(for: 2.5), 2.5)
        XCTAssertEqual(LiquidGlassOpticsRenderer.effectiveScale(for: 3.0), 3.0)
        XCTAssertEqual(LiquidGlassOpticsRenderer.effectiveScale(for: 4.0), 3.0)
        XCTAssertEqual(LiquidGlassOpticsRenderer.effectiveScale(for: .nan), 1.0)
    }

    func testPhysicalRimHasZeroPixelsOutsideContinuousCornerAcrossAllScales() throws {
        let specs: [(LiquidGlassOpticsRenderer.FormKind, CGSize, CGFloat)] = [
            (.bubble, CGSize(width: 44, height: 44), 22),
            (.strip, CGSize(width: 236, height: 44), 22),
            (.expanded, CGSize(width: 360, height: 616), 18),
            (.expanded, CGSize(width: 556, height: 108), 18), // QuickAddWindow inner glass
            (.expanded, CGSize(width: 636, height: 436), 18), // CommandPalette inner glass
        ]
        let scales: [CGFloat] = [1.0, 1.25, 1.5, 2.0, 3.0]

        for scale in scales {
            for dark in [false, true] {
                for (form, size, radius) in specs {
                    let cg = try XCTUnwrap(LiquidGlassOpticsRenderer.rimImage(
                        size: size, cornerRadius: radius, form: form, dark: dark, scale: scale
                    ))
                    let expectedW = Int((size.width * scale).rounded())
                    let expectedH = Int((size.height * scale).rounded())
                    XCTAssertEqual(cg.width, expectedW, "Width mismatch for scale=\(scale) form=\(form)")
                    XCTAssertEqual(cg.height, expectedH, "Height mismatch for scale=\(scale) form=\(form)")

                    let rep = NSBitmapImageRep(cgImage: cg)
                    let rect = CGRect(origin: .zero, size: size)
                    let path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
                    let invScale = 1.0 / scale
                    let cornerZone = Int(ceil((radius * 1.6 + 2) * scale))

                    var exteriorLeakCount = 0
                    var maxLeakAlpha: CGFloat = 0
                    for py in 0..<rep.pixelsHigh {
                        if py >= cornerZone && py < rep.pixelsHigh - cornerZone { continue }
                        let yPt = (CGFloat(py) + 0.5) * invScale
                        for px in 0..<rep.pixelsWide {
                            if px >= cornerZone && px < rep.pixelsWide - cornerZone { continue }
                            let xPt = (CGFloat(px) + 0.5) * invScale
                            if !path.contains(CGPoint(x: xPt, y: yPt)) {
                                let alpha = try XCTUnwrap(rep.colorAt(x: px, y: py)).alphaComponent
                                if alpha > 0 {
                                    exteriorLeakCount += 1
                                    maxLeakAlpha = max(maxLeakAlpha, alpha)
                                }
                            }
                        }
                    }
                    XCTAssertEqual(exteriorLeakCount, 0,
                        "Rim leaked \(exteriorLeakCount) pixels (max alpha \(maxLeakAlpha)) outside continuous corner: form=\(form), dark=\(dark), scale=\(scale), size=\(size)")
                }
            }
        }
    }

    func testFeatheredInteriorMaskScalesDynamicallyAndStaysInsideContinuousCorner() throws {
        let size = CGSize(width: 360, height: 616)
        let radius: CGFloat = 18
        let rect = CGRect(origin: .zero, size: size)
        let path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath

        for scale: CGFloat in [1.0, 1.5, 2.0, 3.0] {
            let cg = try XCTUnwrap(LiquidGlassOpticsRenderer.featheredInteriorMask(
                size: size, cornerRadius: radius, insetPt: 1.75, featherPt: 10.0, scale: scale
            ))
            XCTAssertEqual(cg.width, Int((size.width * scale).rounded()), "Mask must scale with display scale \(scale)")
            XCTAssertEqual(cg.height, Int((size.height * scale).rounded()))

            let rep = NSBitmapImageRep(cgImage: cg)
            let invScale = 1.0 / scale
            let cornerZone = Int(ceil((radius * 1.6 + 2) * scale))
            for py in 0..<rep.pixelsHigh {
                if py >= cornerZone && py < rep.pixelsHigh - cornerZone { continue }
                let yPt = (CGFloat(py) + 0.5) * invScale
                for px in 0..<rep.pixelsWide {
                    if px >= cornerZone && px < rep.pixelsWide - cornerZone { continue }
                    let xPt = (CGFloat(px) + 0.5) * invScale
                    if !path.contains(CGPoint(x: xPt, y: yPt)) {
                        let alpha = try XCTUnwrap(rep.colorAt(x: px, y: py)).alphaComponent
                        XCTAssertEqual(alpha, 0, accuracy: 0.001,
                            "Interior mask leaked outside continuous corner at (\(px), \(py)) scale=\(scale)")
                    }
                }
            }
        }
    }

    func testGlassCornerRadiusIsConcentricAndNeverExceedsInnerHalfSide() {
        XCTAssertEqual(FloatingSurface.glassCornerRadius(
            for: CGSize(width: 48, height: 48), compact: true, transitioning: false, solid: false), 22)
        XCTAssertEqual(FloatingSurface.glassCornerRadius(
            for: CGSize(width: 240, height: 48), compact: true, transitioning: false, solid: false), 22)
        XCTAssertEqual(FloatingSurface.glassCornerRadius(
            for: CGSize(width: 48, height: 48), compact: true, transitioning: false, solid: true), 24)
        XCTAssertEqual(FloatingSurface.glassCornerRadius(
            for: CGSize(width: 364, height: 620), compact: false, transitioning: false, solid: false), 18)
        XCTAssertEqual(FloatingSurface.glassCornerRadius(
            for: CGSize(width: 364, height: 620), compact: false, transitioning: false, solid: true), 20)

        // Transition sizes must stay strictly concentric and <= innerMinSide / 2.
        for side: CGFloat in [48, 64, 96, 128, 240, 364] {
            let r = FloatingSurface.glassCornerRadius(
                for: CGSize(width: side, height: side), compact: false, transitioning: true, solid: false)
            XCTAssertLessThanOrEqual(r, (side - 4) * 0.5)
            XCTAssertGreaterThanOrEqual(r, 18)
            XCTAssertLessThanOrEqual(r, 22)
        }
    }

    func testNativeGlassHostPreservesRefractiveRimAndSyncsMaterialAcrossForms() async throws {
        let size = CGSize(width: 364, height: 440)
        func surface(_ size: CGSize, material: DotistPanelMaterial, compact: Bool, reveal: CGFloat) -> some View {
            FloatingSurface(material: material, compact: compact, transitioning: false,
                onRight: true, size: size, reveal: reveal, color: .orange)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light)
            .environment(\._accessibilityReduceTransparency, false)
            .environment(\._colorSchemeContrast, .standard)
        }
        let fixture = NativeRenderingFixture(surface(size, material: .regular, compact: false, reveal: 0), size: size)
        defer { fixture.close() }

        let cases: [(CGSize, Bool, CGFloat, CGFloat)] = [
            (CGSize(width: 364, height: 440), false, 0, 18),
            (CGSize(width: 48, height: 48), true, 0, 22),
            (CGSize(width: 240, height: 48), true, 1, 22),
        ]
        for material in DotistPanelMaterial.allCases {
            let expectedProfile = ExpandedGlassProfile.resolve(material: material, dark: false, hasGroupColor: true)
            for (bounds, compact, reveal, expectedRadius) in cases {
                fixture.host.rootView = surface(bounds, material: material, compact: compact, reveal: reveal)
                _ = try await fixture.capture(scale: 1)
                let glass = try XCTUnwrap(fixture.descendants(NSGlassEffectView.self).first)
                let hostView = try XCTUnwrap(glass.superview)
                let hostLayer = try XCTUnwrap(hostView.layer)
                let pigmentView = try XCTUnwrap(hostView.subviews.last)
                let pigmentLayer = try XCTUnwrap(pigmentView.layer)
                let sublayers = try XCTUnwrap(pigmentLayer.sublayers)
                let washLayer = try XCTUnwrap(sublayers.first { $0.name == "dotist.wash" })
                let tintLayer = try XCTUnwrap(sublayers.first { $0.name == "dotist.tint" })

                XCTAssertEqual(glass.cornerRadius, expectedRadius, accuracy: 0.01,
                    "NSGlassEffectView cornerRadius mismatch for compact=\(compact) bounds=\(bounds)")
                XCTAssertEqual(glass.style, expectedProfile.glassStyle,
                    "Compact bubble/strip and expanded panel must share native glass style for material=\(material)")
                XCTAssertFalse(hostLayer.masksToBounds,
                    "Host layer must stay unclipped so WindowServer renders 3D refractive edges in the 2pt optical clearance")
                XCTAssertEqual(pigmentLayer.cornerRadius, expectedRadius, accuracy: 0.01)
                XCTAssertEqual(pigmentLayer.cornerCurve, .continuous)
                XCTAssertTrue(pigmentLayer.masksToBounds, "Pigment layer must remain clipped to the inner continuous corner")
                XCTAssertEqual(Double(try XCTUnwrap(washLayer.backgroundColor).alpha), 0.0, accuracy: 0.001,
                    "Hover strip and other forms must not paint a flat wash veil")
                XCTAssertEqual(Double(try XCTUnwrap(tintLayer.backgroundColor).alpha), expectedProfile.tintAlpha, accuracy: 0.001,
                    "All three forms must use unified group tint alpha for material=\(material)")
            }
        }
    }

    func testPhysicalRimRetainsOuterLipHighlightPeakAcrossScales() throws {
        let specs: [(LiquidGlassOpticsRenderer.FormKind, CGSize, CGFloat)] = [
            (.bubble, CGSize(width: 44, height: 44), 22),
            (.strip, CGSize(width: 236, height: 44), 22),
            (.expanded, CGSize(width: 360, height: 616), 18),
        ]
        for scale: CGFloat in [1.0, 2.0] {
            for (form, size, radius) in specs {
                let cg = try XCTUnwrap(LiquidGlassOpticsRenderer.rimImage(
                    size: size, cornerRadius: radius, form: form, dark: false, scale: scale
                ))
                let rep = NSBitmapImageRep(cgImage: cg)
                var topEdgePeak: CGFloat = 0
                let midX = rep.pixelsWide / 2
                let sampleRows = max(1, Int(ceil(1.5 * scale)))
                for py in 0..<sampleRows {
                    let alpha = try XCTUnwrap(rep.colorAt(x: midX, y: py)).alphaComponent
                    topEdgePeak = max(topEdgePeak, alpha)
                }
                XCTAssertGreaterThan(topEdgePeak, 0.72,
                    "Outer lip highlight peak must remain strong at scale=\(scale) form=\(form)")
            }
        }
    }

    func testViewsWindowShadowProfileMatchesVisibleGlassSilhouette() {
        let frameSize = CGSize(width: 1096, height: 816) // 1000x720 + 48pt margin on each side
        let glassProfile = ViewsWindowShadow.shadowProfile(
            frameSize: frameSize, reduceTransparency: false, increasedContrast: false)
        XCTAssertEqual(glassProfile.cornerRadius, 18)
        XCTAssertEqual(glassProfile.rect, CGRect(x: 50, y: 50, width: 996, height: 716))

        let solidProfile = ViewsWindowShadow.shadowProfile(
            frameSize: frameSize, reduceTransparency: true, increasedContrast: false)
        XCTAssertEqual(solidProfile.cornerRadius, 20)
        XCTAssertEqual(solidProfile.rect, CGRect(x: 48, y: 48, width: 1000, height: 720))
    }

    func testSecondaryGlassWindowsClipCleanlyToContinuousCornerAt1xAnd2x() throws {
        _ = NSApplication.shared
        let model = try AppModel(store: TaskStore(databasePath: ":memory:"))
        let windows: [(String, CGSize, AnyView)] = [
            ("quick-add", CGSize(width: 560, height: 112), AnyView(QuickAddWindow(model: model, close: {}))),
            ("command-palette", CGSize(width: 640, height: 220), AnyView(CommandPalette(model: model, close: {}, reveal: { _ in }, revealGroup: { _ in }, showViews: {}))),
            ("views", CGSize(width: 720, height: 500), AnyView(ViewsWindow(model: model))),
        ]

        for scale: CGFloat in [1.0, 2.0] {
            for (name, size, view) in windows {
                let renderer = ImageRenderer(content: view
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, scale)
                    .environment(\._accessibilityReduceTransparency, true))
                renderer.scale = scale
                let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))

                let maskRenderer = ImageRenderer(content: RoundedRectangle(cornerRadius: DotistDesign.windowCornerRadius, style: .continuous)
                    .fill(.white)
                    .frame(width: size.width, height: size.height)
                    .environment(\.displayScale, scale))
                maskRenderer.scale = scale
                let mask = NSBitmapImageRep(cgImage: try XCTUnwrap(maskRenderer.cgImage))

                let cornerZone = Int(ceil(28 * scale))
                var maxExteriorAlpha: CGFloat = 0
                for py in 0..<rep.pixelsHigh {
                    if py >= cornerZone && py < rep.pixelsHigh - cornerZone { continue }
                    for px in 0..<rep.pixelsWide {
                        if px >= cornerZone && px < rep.pixelsWide - cornerZone { continue }
                        let hasMaskNeighbor = (-1...1).contains { dy in
                            (-1...1).contains { dx in
                                let mx = px + dx, my = py + dy
                                return mx >= 0 && my >= 0 && mx < mask.pixelsWide && my < mask.pixelsHigh
                                    && (mask.colorAt(x: mx, y: my)?.alphaComponent ?? 0) > 0
                            }
                        }
                        if !hasMaskNeighbor {
                            maxExteriorAlpha = max(maxExteriorAlpha, try XCTUnwrap(rep.colorAt(x: px, y: py)).alphaComponent)
                        }
                    }
                }
                XCTAssertEqual(maxExteriorAlpha, 0,
                    "\(name) leaked exterior corner pixels at scale=\(scale)")
            }
        }
    }
}
