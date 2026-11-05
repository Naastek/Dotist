import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class GroupHeaderDeviceScaleTests: XCTestCase {
    private var evidence: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".cache/font-pixel-fix/evidence")
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        DotistDesign.registerFonts(in: evidence.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("native-migration/fonts"))
    }

    // Observe the actual cached image without adding diagnostic API to production.
    private func raster(_ view: NSView, property: String = "titleImage") throws -> GroupHeaderInkView.InkRaster {
        let storage = try XCTUnwrap(Mirror(reflecting: view).children.first { $0.label == property })
        return try XCTUnwrap(Mirror(reflecting: storage.value).children.first?.value as? GroupHeaderInkView.InkRaster)
    }

    private func draw(_ view: NSView, x: CGFloat, y: CGFloat) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(view.bounds.width * x)), pixelsHigh: Int(ceil(view.bounds.height * y)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        if view.isFlipped {
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: view.isFlipped)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        NSColor.white.setFill(); view.bounds.fill()
        view.draw(view.bounds)
        return bitmap
    }

    private func save(_ image: NSBitmapImageRep, _ name: String) throws {
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
            .write(to: evidence.appendingPathComponent(name + ".png"))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    // The old x-only CTM estimate loses vertical resolution in a real 1x/2y
    // destination. This is a reproducible boundary case, not a Retina desktop repro.
    func testHeaderUsesDestinationDeviceResolutionOnBothAxes() throws {
        let header = GroupHeaderInkView(frame: CGRect(x: 0, y: 0, width: 200, height: 30))
        header.configure(title: "work", font: DotistDesign.nativeFont(15, weight: .semibold, serif: true, language: "en"),
                         symbol: "chevron.down", showsChevron: true, titleColor: .black)
        let image = try draw(header, x: 1, y: 2)
        let ink = try raster(header)
        try save(image, "header-device-1x-2y")
        try save(NSBitmapImageRep(cgImage: ink.image), "header-device-1x-2y-source")
        XCTAssertEqual(CGFloat(ink.image.width) / ink.size.width, 2,
                       "The source glyph raster must retain the destination's vertical device resolution")
        XCTAssertEqual(CGFloat(ink.image.height) / ink.size.height, 2)
    }

    func testSearchGlyphUsesDestinationDeviceResolutionOnBothAxes() async throws {
        let fixture = NativeRenderingFixture(
            SearchRow(text: .constant(""), placeholder: "Search", language: "en"),
            size: CGSize(width: 240, height: 24))
        defer { fixture.close() }
        await Task.yield()
        fixture.host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let icon = try XCTUnwrap(descendants(fixture.host).first { String(describing: type(of: $0)) == "NativeSearchIconView" })
        let image = try draw(icon, x: 1, y: 2)
        let ink = try raster(icon, property: "raster")
        try save(image, "search-device-1x-2y")
        XCTAssertEqual(CGFloat(ink.image.width) / ink.size.width, 2,
                       "Search shares the header's device-resolution raster contract")
        XCTAssertEqual(CGFloat(ink.image.height) / ink.size.height, 2)
    }

    func testRepeatedFontChangesRetainExplicitOneAndTwoTimesResolution() async throws {
        let saved = DotistDesign.fontPreferences
        defer { DotistDesign.fontPreferences = saved }
        var records = ["title,step,font,simulatedWindowBacking,destinationScale,rasterScale,pixelsWide,pixelsHigh,titleCenter,arrowCenter"]
        for title in ["work", "life", "工作 Work"] {
            let fixture = NativeRenderingFixture(
                GroupHeaderInkLabel(title: title, language: "zh-CN", collapsed: false, showsChevron: true, empty: false),
                // Simulate Retina layout metadata while explicitly drawing at
                // both scales. This must not force 1x exports to become 2x.
                size: CGSize(width: 220, height: 30), simulatedBackingScale: 2)
            defer { fixture.close() }
            let original = try XCTUnwrap(fixture.descendants(GroupHeaderInkView.self).first)
            for (step, choice) in ["newsreader", "source-serif-4", "pt-serif", "system", "source-serif-4", "newsreader"].enumerated() {
                DotistDesign.fontPreferences = .init(serifLatin: choice)
                await Task.yield()
                fixture.host.layoutSubtreeIfNeeded()
                fixture.host.displayIfNeeded()
                let header = try XCTUnwrap(fixture.descendants(GroupHeaderInkView.self).first)
                XCTAssertTrue(header === original, "Font publication must refresh the existing native view")
                let actualFont = try XCTUnwrap(Mirror(reflecting: header).children.first { $0.label == "titleFont" }?.value as? NSFont)
                XCTAssertEqual(actualFont, DotistDesign.nativeFont(15, weight: .semibold, serif: true, language: "zh-CN"))
                // Start at the previous destination scale too: otherwise a
                // scale change alone could hide missing font invalidation.
                for scale: CGFloat in [2, 2, 1, 2] {
                    let image = try draw(header, x: scale, y: scale)
                    let ink = try raster(header)
                    let fresh = GroupHeaderInkView(frame: header.bounds)
                    fresh.configure(title: title, font: actualFont, symbol: "chevron.down", showsChevron: true,
                                    titleColor: NSColor(DotistDesign.ink))
                    _ = try draw(fresh, x: scale, y: scale)
                    let expected = try raster(fresh)
                    XCTAssertEqual(ink.image.width, expected.image.width)
                    XCTAssertEqual(ink.image.height, expected.image.height)
                    XCTAssertEqual(try pixels(ink.image), try pixels(expected.image), "Reused title must match a fresh render after font change: \(choice)")
                    let density = CGFloat(ink.image.width) / ink.size.width
                    records.append("\(title),\(step),\(actualFont.familyName ?? "?"),\(fixture.window.backingScaleFactor),\(scale),\(density),\(ink.image.width),\(ink.image.height),\(header.titleInkFrame.midY),\(header.symbolInkFrame.midY)")
                    XCTAssertEqual(density, scale, "\(title), font=\(choice), destination=\(scale)")
                    XCTAssertEqual(CGFloat(ink.image.height) / ink.size.height, scale)
                    XCTAssertEqual(header.titleInkFrame.midY, 15, accuracy: 0.5 / scale)
                    XCTAssertEqual(header.symbolInkFrame.midY, header.titleInkFrame.midY, accuracy: 0.5 / scale)
                    if title == "work" {
                        try save(image, "font-step-\(step)-destination-\(Int(scale))")
                    }
                }
            }
        }
        try records.joined(separator: "\n").write(to: evidence.appendingPathComponent("font-switch-scales.csv"), atomically: true, encoding: .utf8)
    }

    func testNativeRetinaWindowKeepsTitleDeviceResolutionAcrossFontChanges() async throws {
        let description = "screens=\(NSScreen.screens.count), scales=\(NSScreen.screens.map(\.backingScaleFactor))"
        try description.write(to: evidence.appendingPathComponent("native-window-environment.txt"), atomically: true, encoding: .utf8)
        guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor == 2 }) else {
            throw XCTSkip("No real Retina screen is available; explicit bitmap tests are not desktop evidence. " + description)
        }
        let saved = DotistDesign.fontPreferences
        defer { DotistDesign.fontPreferences = saved }
        let panel = NSPanel(contentRect: CGRect(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 24, width: 240, height: 30),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: GroupHeaderInkLabel(title: "work", language: "en", collapsed: false, showsChevron: true, empty: false))
        host.frame = CGRect(x: 0, y: 0, width: 240, height: 30)
        panel.contentView = host
        defer { panel.close() }
        panel.orderFrontRegardless()
        for choice in ["newsreader", "source-serif-4", "newsreader"] {
            DotistDesign.fontPreferences = .init(serifLatin: choice)
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            func find(_ view: NSView) -> GroupHeaderInkView? {
                (view as? GroupHeaderInkView) ?? view.subviews.lazy.compactMap(find).first
            }
            let header = try XCTUnwrap(find(host))
            header.needsDisplay = true
            host.displayIfNeeded()
            let ink = try raster(header)
            XCTAssertEqual(CGFloat(ink.image.width) / ink.size.width, 2, "Native window: \(choice), \(description)")
        }
    }
}
