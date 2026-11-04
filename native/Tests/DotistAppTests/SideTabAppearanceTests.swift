import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class SideTabAppearanceTests: XCTestCase {
    func testOpacityControlsBackgroundAndLeavesExpandedTextOpaque() throws {
        for scheme in [ColorScheme.light, .dark] {
            for inward in [false, true] {
                for opacity: UInt8 in [0, 4, 10, 47, 85, 100] {
                    let background = try bitmap(scheme: scheme, inward: inward, opacity: opacity, labels: false)
                    let labeled = try bitmap(scheme: scheme, inward: inward, opacity: opacity, labels: true)
                    let center = try XCTUnwrap(background.colorAt(x: background.pixelsWide / 2, y: 3))
                    XCTAssertEqual(center.alphaComponent, CGFloat(opacity) / 100, accuracy: 0.015)
                    var opaqueTextPixels = 0
                    for y in 8..<26 {
                        for x in 10..<(labeled.pixelsWide - 10) {
                            if (labeled.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.98,
                               (background.colorAt(x: x, y: y)?.alphaComponent ?? 0) < 0.9 {
                                opaqueTextPixels += 1
                            }
                        }
                    }
                    if opacity < 85 { XCTAssertGreaterThan(opaqueTextPixels, 10, "Opacity must apply to the background alone") }
                }
            }
        }
    }

    func testReducedTransparencyAndIncreasedContrastOverrideLowBackgroundOpacity() throws {
        for scheme in [ColorScheme.light, .dark] {
            for inward in [false, true] {
                for reduceTransparency in [false, true] {
                    for contrast in [ColorSchemeContrast.standard, .increased] {
                        let sample = try XCTUnwrap(SideTabsSnapshot.render(names: ["Work projects"], language: "en", scheme: scheme,
                            inward: inward, expanded: true, showLabels: false, opacity: 10,
                            reduceTransparency: reduceTransparency, contrast: contrast))
                        let pixels = NSBitmapImageRep(cgImage: sample.image)
                        let center = try XCTUnwrap(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2))
                        XCTAssertEqual(center.alphaComponent, reduceTransparency || contrast == .increased ? 1 : 0.1, accuracy: 0.015)
                    }
                }
            }
        }
    }

    func testThemeColorIsResolvedAgainForEveryRenderIncludingAllFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-side-tab-colors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let neutral = try store.addGroup(name: "Neutral")
        let model = try AppModel(store: store)
        func surface(_ id: String?) throws -> NSColor {
            let sample = try XCTUnwrap(SideTabsSnapshot.render(names: ["Work projects"], language: "en", scheme: .light,
                inward: true, expanded: true, showLabels: false, color: { _ in model.themeColor(forGroup: id) }))
            let pixels = NSBitmapImageRep(cgImage: sample.image)
            return try XCTUnwrap(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        }
        func setAllColor(_ value: String) async throws {
            var patch = DotistSettingsPatch()
            patch.allColor = value
            let succeeded = await withCheckedContinuation { continuation in
                model.updateSettings(patch) { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(succeeded)
            XCTAssertNil(model.error)
        }
        try await setAllColor("red")
        let red = try surface(nil)
        let neutralRed = try surface(neutral.id)
        XCTAssertEqual(red.redComponent, neutralRed.redComponent, accuracy: 0.005)
        try await setAllColor("blue")
        let blue = try surface(nil)
        let neutralBlue = try surface(neutral.id)
        XCTAssertGreaterThan(red.redComponent - blue.redComponent, 0.015)
        XCTAssertGreaterThan(blue.blueComponent - red.blueComponent, 0.015)
        XCTAssertEqual(blue.blueComponent, neutralBlue.blueComponent, accuracy: 0.005)

        model.setGroupColor(neutral.id, .green)
        let deadline = Date().addingTimeInterval(5)
        while model.themeColor(forGroup: neutral.id) != .green && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.themeColor(forGroup: neutral.id), .green)
        let green = try surface(neutral.id)
        XCTAssertGreaterThan(blue.blueComponent - green.blueComponent, 0.015)
        XCTAssertEqual(try surface(nil).blueComponent, blue.blueComponent, accuracy: 0.005)
    }

    /// Independent paper shape rendered with the same rasterizer and appearance
    /// as the full canvas. It intentionally has no production background view.
    private func paperReference(size: CGSize, inward: Bool, scheme: ColorScheme, selected: Bool,
                                opacity: UInt8, protection: Int, legacyStroke: Bool = false) throws -> NSBitmapImageRep {
        let radius = min(8, size.width / 2, size.height / 2)
        let shape = UnevenRoundedRectangle(topLeadingRadius: inward ? 0 : radius,
            bottomLeadingRadius: inward ? 0 : radius, bottomTrailingRadius: inward ? radius : 0,
            topTrailingRadius: inward ? radius : 0, style: .continuous)
        let fill = DotistDesign.paper.mix(with: DotistDesign.ink,
            by: selected ? (protection == 2 ? 0.42 : 0.30) : 0.06, in: .device)
        let alpha = protection == 0 ? Double(opacity) / 100 : 1
        let view = shape.fill(fill)
            .overlay { if legacyStroke { shape.stroke(DotistDesign.faint.opacity(0.45), lineWidth: 0.75) } }
            .compositingGroup().opacity(alpha).frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view); renderer.scale = 1
        var image: CGImage?
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image))
    }

    /// Independent literal shapes in a canvas matching the snapshot's extent
    /// and absolute origins. A cropped tile can rasterize a corner differently.
    private func canvasReference(size: CGSize, tabs: [CGRect], inward: Bool, scheme: ColorScheme,
                                 opacity: UInt8, protection: Int, legacyStroke: Bool = false) throws -> NSBitmapImageRep {
        let alpha = protection == 0 ? Double(opacity) / 100 : 1
        let view = ZStack(alignment: .topLeading) {
            Color.clear.frame(width: size.width, height: size.height)
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, rect in
                let radius = min(8, rect.width / 2, rect.height / 2)
                let shape = UnevenRoundedRectangle(topLeadingRadius: inward ? 0 : radius,
                    bottomLeadingRadius: inward ? 0 : radius, bottomTrailingRadius: inward ? radius : 0,
                    topTrailingRadius: inward ? radius : 0, style: .continuous)
                let fill = DotistDesign.paper.mix(with: DotistDesign.ink,
                    by: index == 0 ? (protection == 2 ? 0.42 : 0.30) : 0.06, in: .device)
                shape.fill(fill)
                    .overlay { if legacyStroke { shape.stroke(DotistDesign.faint.opacity(0.45), lineWidth: 0.75) } }
                    .compositingGroup().opacity(alpha)
                    .frame(width: rect.width, height: rect.height).clipped()
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, scheme)
        .transaction { $0.disablesAnimations = true }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1; renderer.proposedSize = ProposedViewSize(size)
        var image: CGImage?
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image))
    }

    /// Capture the actual live paper tree. Interior coverage must have exactly
    /// the same color at the perimeter; a stroked outline adds differing pixels.
    func testNoOutlinePixelsAndFlushCornersAcrossTransparencyAndAccessibility() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/integration-install/pixel-evidence/side-tabs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var measurements = ["scheme,inward,expanded,opacity,protection,tab,backgroundAlpha,outlinePixels"]
        var pixelEvidence = ["name,tab,x,y,rectMinX,rectMinY,rectMaxX,rectMaxY,expectedAlpha,red,green,blue,alpha,referenceRed,referenceGreen,referenceBlue,referenceAlpha,visibleDifference"]
        for scheme in [ColorScheme.light, .dark] {
            for inward in [false, true] {
                for expanded in [false, true] {
                    for opacity: UInt8 in [0, 4, 85, 100] {
                        for protection in 0...2 {
                            let snapshot = try XCTUnwrap(SideTabsSnapshot.render(names: ["All", "Long project name 工作"], language: "zh-CN",
                                scheme: scheme, inward: inward, expanded: expanded, showLabels: false, opacity: opacity,
                                reduceTransparency: protection == 1, contrast: protection == 2 ? .increased : .standard,
                                color: { _ in .none }))
                            let bitmap = NSBitmapImageRep(cgImage: snapshot.image)
                            let name = "\(scheme)-inward\(inward)-expanded\(expanded)-opacity\(opacity)-protection\(protection)"
                            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
                            let expected = protection == 0 ? CGFloat(opacity) / 100 : 1
                            let reference = try canvasReference(size: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh),
                                tabs: snapshot.tabs, inward: inward, scheme: scheme, opacity: opacity, protection: protection)
                            XCTAssertEqual(reference.pixelsWide, bitmap.pixelsWide)
                            XCTAssertEqual(reference.pixelsHigh, bitmap.pixelsHigh)
                            for (index, rect) in snapshot.tabs.enumerated() {
                                let connectionX = Int(inward ? rect.minX : rect.maxX - 1)
                                let outerX = Int(inward ? rect.maxX - 1 : rect.minX)
                                let center = try XCTUnwrap(bitmap.colorAt(x: Int(rect.midX), y: Int(rect.midY))?.usingColorSpace(.deviceRGB))
                                XCTAssertEqual(center.alphaComponent, expected, accuracy: 0.005, name)
                                for y in Int(rect.minY)..<Int(rect.maxY) {
                                    XCTAssertEqual(bitmap.colorAt(x: connectionX, y: y)?.alphaComponent ?? 0, expected,
                                                   accuracy: 0.005, "\(name): connection edge must stay square")
                                }
                                for y in [Int(rect.minY), Int(rect.maxY - 1)] {
                                    XCTAssertEqual(bitmap.colorAt(x: outerX, y: y)?.alphaComponent ?? 0, 0, name)
                                }
                                var outlinePixels = 0
                                for y in Int(rect.minY)..<Int(rect.maxY) {
                                    for x in Int(rect.minX)..<Int(rect.maxX) {
                                        let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                                        if expected == 0 { XCTAssertEqual(pixel.alphaComponent, 0, name); continue }
                                        // Exclude the outer corner's antialias coverage, but
                                        // retain every fully covered boundary pixel.
                                        guard abs(pixel.alphaComponent - expected) < 0.001 else { continue }
                                        let referencePixel = try XCTUnwrap(reference.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                                        let difference = visibleDifference(pixel, referencePixel)
                                        if difference > 1.0 / 255 {
                                            outlinePixels += 1
                                            pixelEvidence.append("\(name),\(index),\(x),\(y),\(rect.minX),\(rect.minY),\(rect.maxX),\(rect.maxY),\(expected),\(pixel.redComponent),\(pixel.greenComponent),\(pixel.blueComponent),\(pixel.alphaComponent),\(referencePixel.redComponent),\(referencePixel.greenComponent),\(referencePixel.blueComponent),\(referencePixel.alphaComponent),\(difference)")
                                        }
                                    }
                                }
                                XCTAssertEqual(outlinePixels, 0, "\(name): no colored outline in selected or unselected tabs")
                                measurements.append("\(scheme),\(inward),\(expanded),\(opacity),\(protection),\(index),\(center.alphaComponent),\(outlinePixels)")
                            }
                        }
                    }
                }
            }
        }
        try measurements.joined(separator: "\n").write(to: directory.appendingPathComponent("pixels.csv"), atomically: true, encoding: .utf8)
        try pixelEvidence.joined(separator: "\n").write(to: directory.appendingPathComponent("outline-pixels.csv"), atomically: true, encoding: .utf8)
        // A panel backdrop makes the two attachment directions inspectable.
        // The tab image is the same full live tree used by the pixel matrix;
        // the rectangle is an illustration, not an activated desktop window.
        for scheme in [ColorScheme.light, .dark] {
            for inward in [false, true] {
                let tabs = try XCTUnwrap(SideTabsSnapshot.render(names: ["全部", "Work projects 工作计划"], language: "zh-CN",
                    scheme: scheme, inward: inward, expanded: true, opacity: 100, color: { _ in .teal }))
                let canvas = ZStack(alignment: .topLeading) {
                    (scheme == .dark ? Color(white: 0.08) : Color(white: 0.78)).zIndex(-2)
                    RoundedRectangle(cornerRadius: 20).fill(scheme == .dark ? Color(white: 0.2) : Color(white: 0.97))
                        .frame(width: 364, height: 180).offset(x: 220).zIndex(0)
                    Image(decorative: tabs.image, scale: 1)
                        .offset(x: inward ? 210 : 220 - CGFloat(tabs.image.width), y: SideTabGeometry.topInset)
                        .zIndex(inward ? 1 : -1)
                }.frame(width: 604, height: 180)
                let renderer = ImageRenderer(content: canvas)
                renderer.scale = 1
                let image = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("connection-\(scheme)-inward\(inward).png"))
            }
        }
        print("SIDE TAB FIVE evidence=\(directory.path), screens=\(NSScreen.screens.count); ImageRenderer paper snapshots, no desktop window ordering")
    }

    /// Compare final color over black AND white. Unassociated RGB magnifies
    /// one low-alpha quantization step by 1/alpha; that is not visible contrast.
    /// The existing 1/255 threshold and zero-outline assertion stay unchanged.
    private func visibleDifference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let lhs = [a.redComponent, a.greenComponent, a.blueComponent]
        let rhs = [b.redComponent, b.greenComponent, b.blueComponent]
        var maximum: CGFloat = 0
        for backdrop: CGFloat in [0, 1] {
            for index in lhs.indices {
                let left: CGFloat = lhs[index] * a.alphaComponent + backdrop * (1 - a.alphaComponent)
                let right: CGFloat = rhs[index] * b.alphaComponent + backdrop * (1 - b.alphaComponent)
                let difference: CGFloat = abs(left - right)
                maximum = max(maximum, difference)
            }
        }
        return maximum
    }

    func testVisibleColorComparisonRetainsLegacyStrokeCounterexample() throws {
        for scheme in [ColorScheme.light, .dark] {
            for opacity in [0.85, 1.0] {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                let legacy = shape.fill(DotistDesign.paper)
                    .overlay(shape.stroke(DotistDesign.faint.opacity(0.45), lineWidth: 0.75))
                    .compositingGroup().opacity(opacity).frame(width: 120, height: 34)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: legacy)
                renderer.scale = 1
                let image = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                let center = try XCTUnwrap(image.colorAt(x: 60, y: 17)?.usingColorSpace(.deviceRGB))
                var count = 0
                for x in 12..<108 {
                    let pixel = try XCTUnwrap(image.colorAt(x: x, y: 0)?.usingColorSpace(.deviceRGB))
                    if visibleDifference(pixel, center) > 1.0 / 255 { count += 1 }
                }
                XCTAssertGreaterThan(count, 0, "The original 0.75pt stroke must still be rejected at the original threshold")
                print("LEGACY STROKE \(scheme), opacity=\(opacity), visible outline pixels=\(count)")
            }
        }
        // The same reference comparison must reject the old stroke; it cannot
        // merely compare every corner against a center-colored pixel.
        for scheme in [ColorScheme.light, .dark] {
            let reference = try paperReference(size: CGSize(width: 120, height: 34), inward: false,
                scheme: scheme, selected: false, opacity: 100, protection: 0)
            let legacy = try paperReference(size: CGSize(width: 120, height: 34), inward: false,
                scheme: scheme, selected: false, opacity: 100, protection: 0, legacyStroke: true)
            var differences = 0
            for y in 0..<34 { for x in 0..<120 {
                let a = try XCTUnwrap(reference.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let b = try XCTUnwrap(legacy.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if a.alphaComponent == 1 && b.alphaComponent == 1 && visibleDifference(a, b) > 1.0 / 255 { differences += 1 }
            } }
            XCTAssertGreaterThan(differences, 0, "Same-path reference must detect a legacy stroke")
        }
        // Exercise the full-canvas comparator at nonzero tab origins as well.
        let controlTabs = [CGRect(x: 72, y: 0, width: 48, height: 34), CGRect(x: 0, y: 40, width: 120, height: 34)]
        for scheme in [ColorScheme.light, .dark] {
            let reference = try canvasReference(size: CGSize(width: 120, height: 74), tabs: controlTabs,
                inward: false, scheme: scheme, opacity: 100, protection: 0)
            let legacy = try canvasReference(size: CGSize(width: 120, height: 74), tabs: controlTabs,
                inward: false, scheme: scheme, opacity: 100, protection: 0, legacyStroke: true)
            var differences = 0
            for rect in controlTabs { for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) {
                let a = try XCTUnwrap(reference.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let b = try XCTUnwrap(legacy.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if b.alphaComponent == 1 && visibleDifference(a, b) > 1.0 / 255 { differences += 1 }
            } } }
            XCTAssertGreaterThan(differences, 0, "Full-canvas reference must detect the legacy stroke")
        }
        // Exact host outlier replay: unassociated RGB differs by 0.0785653,
        // while composited RGB differs by 0.003081, below 1/255.
        let a = NSColor(deviceRed: 0.9214347, green: 0.9214347, blue: 0.9214347, alpha: 10.0 / 255)
        let b = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 10.0 / 255)
        XCTAssertGreaterThan(abs(a.redComponent - b.redComponent), 1.0 / 255)
        XCTAssertLessThan(visibleDifference(a, b), 1.0 / 255)
    }

    private func bitmap(scheme: ColorScheme, inward: Bool, opacity: UInt8, labels: Bool) throws -> NSBitmapImageRep {
        let sample = try XCTUnwrap(SideTabsSnapshot.render(names: ["Work projects"], language: "en", scheme: scheme,
            inward: inward, expanded: true, showLabels: labels, opacity: opacity))
        return NSBitmapImageRep(cgImage: sample.image)
    }
}
