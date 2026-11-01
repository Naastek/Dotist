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
                for opacity: UInt8 in [10, 47, 85, 100] {
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

    private func bitmap(scheme: ColorScheme, inward: Bool, opacity: UInt8, labels: Bool) throws -> NSBitmapImageRep {
        let sample = try XCTUnwrap(SideTabsSnapshot.render(names: ["Work projects"], language: "en", scheme: scheme,
            inward: inward, expanded: true, showLabels: labels, opacity: opacity))
        return NSBitmapImageRep(cgImage: sample.image)
    }
}
