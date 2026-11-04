import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

/// Existing native settings/optical tests also route their artifacts here.
func settingsTestArtifact(_ name: String) -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOTIST_SETTINGS_ARTIFACTS"] ?? FileManager.default.temporaryDirectory.path).appendingPathComponent(name)
}

@MainActor
final class SettingsPolishRenderingTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
    }
    func testNativeSettingsWindowMatrix() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOTIST_SETTINGS_ARTIFACTS"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("settings-polish").path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtures = output.appendingPathComponent("fixtures-" + UUID().uuidString)
        let store = try TaskStore(databasePath: fixtures.appendingPathComponent("tasks.sqlite").path)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        _ = try store.addGroup(name: "Préparation 工作")
        var records = ["language,theme,module,width,height,controls"]
        for language in ["zh-CN", "zh-TW", "en", "fr", "de"] {
            for theme in ["light", "dark"] {
                var patch = DotistSettingsPatch(); patch.language = language; patch.theme = theme
                _ = try store.updateSettings(patch)
                let model = try AppModel(store: store)
                for module in [SettingsModule.appearance, .general, .shortcuts, .toolbar] {
                    for size in [CGSize(width: 880, height: 660), CGSize(width: 800, height: 660), CGSize(width: 880, height: 540), CGSize(width: 800, height: 540)] {
                        let view = SettingsWindow(model: model, updater: NativeUpdater(model: model), beginShortcutCapture: {}, endShortcutCapture: { _, _ in }, resetWindowSize: {}, initialModule: module)
                        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
                        host.frame = CGRect(origin: .zero, size: size)
                        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false; window.contentView = host
                        window.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(35))
                        host.layoutSubtreeIfNeeded()
                        XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 0.5)
                        XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 0.5)
                        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
                        let controls = descendants(host).filter { $0 is NSSegmentedControl || $0 is NSPopUpButton }
                        for control in controls {
                            let rect = host.convert(control.bounds, from: control)
                            XCTAssertGreaterThanOrEqual(rect.minX, 240, "\(language) \(module)")
                            XCTAssertLessThanOrEqual(rect.maxX, size.width - 25, "\(language) \(module)")
                        }
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let name = "\(language)-\(theme)-\(module.rawValue)-\(Int(size.width))x\(Int(size.height))"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
                        records.append("\(language),\(theme),\(module.rawValue),\(size.width),\(size.height),\(controls.count)")
                        window.close()
                    }
                }
            }
        }
        try records.joined(separator: "\n").write(to: output.appendingPathComponent("matrix.csv"), atomically: true, encoding: .utf8)
    }
    func testFullAppearanceAndProductionPreviewFrames() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOTIST_SETTINGS_ARTIFACTS"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("settings-polish").path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtures = output.appendingPathComponent("detail-fixture-" + UUID().uuidString)
        let store = try TaskStore(databasePath: fixtures.appendingPathComponent("tasks.sqlite").path)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        _ = try store.addGroup(name: "Projektvorbereitung")
        for language in ["zh-CN", "fr", "de"] {
            for theme in ["light", "dark"] {
                var patch = DotistSettingsPatch(); patch.language = language; patch.theme = theme
                _ = try store.updateSettings(patch)
                let model = try AppModel(store: store)
                let settings = SettingsWindow(model: model, updater: NativeUpdater(model: model), beginShortcutCapture: {}, endShortcutCapture: { _, _ in }, resetWindowSize: {})
                let root = settings.frame(width: 800, height: 1900)
                let host = NSHostingView(rootView: root)
                host.frame.size = host.fittingSize
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                window.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
                func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
                let fonts = descendants(host).compactMap { $0 as? NSPopUpButton }
                XCTAssertEqual(fonts.count, DotistFontRole.allCases.count)
                let columns = fonts.map { host.convert($0.bounds, from: $0) }
                for rect in columns {
                    XCTAssertEqual(rect.width, SettingsFontPicker.columnWidth, accuracy: 0.5)
                    XCTAssertEqual(rect.minX, columns.first!.minX, accuracy: 0.5)
                }
                for popup in fonts {
                    let widest = popup.itemTitles.map { ($0 as NSString).size(withAttributes: [.font: popup.font!]).width }.max() ?? 0
                    XCTAssertLessThan(widest + 32, popup.bounds.width, "Font names must fit")
                }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("full-appearance-\(language)-\(theme).png"))
                window.close()
            }
        }
        var now = 10.0
        let playback = SettingsPreviewPlayback(time: { now })
        playback.play(reduceMotion: false)
        for (label, elapsed) in [("start", 0.0), ("middle-1", 0.045), ("middle-2", 0.1), ("final", 0.46)] {
            now = 10 + elapsed; playback.sample()
            let host = NSHostingView(rootView: SettingsSideTabSample(values: playback.values, language: "zh-CN").padding(12).background(.white).environment(\.colorScheme, .light))
            host.frame.size = host.fittingSize; host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("preview-" + label + ".png"))
            let production = try XCTUnwrap(SideTabsSnapshot.render(names: ["", "", ""], language: "zh-CN", scheme: .light,
                inward: false, expanded: false, showLabels: false, entrance: playback.values, color: { _ in .none }))
            let geometry = SideTabGeometry.snapshot(panel: CGRect(x: 24, y: 0, width: 84, height: 164),
                fullWidths: [84, 84, 84], progress: 0, inward: false, selectedIndex: 0, entrance: playback.values)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            // Very early, nearly transparent antialiased pixels are covered by
            // the track regression; measure silhouettes once clearly visible.
            for index in playback.values.indices where playback.values[index] > 0.25 {
                let rect = geometry.tabs[index]
                let y = Int((12 + 164 - rect.midY) * scale)
                let painted = (0..<Int(36 * scale)).filter { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return min(color.redComponent, color.greenComponent, color.blueComponent) < 1 - 1.0 / 255
                }
                let first = try XCTUnwrap(painted.first)
                let last = try XCTUnwrap(painted.last)
                XCTAssertEqual(CGFloat(last - first + 1) / scale, production.tabs[index].width, accuracy: 1.5,
                    "Native preview silhouette must follow the actual production entrance geometry")
                XCTAssertEqual(CGFloat(first) / scale, 12 + rect.minX, accuracy: 1.5)
            }

        }
    }

}

@MainActor
final class SettingsReviewRegressionTests: XCTestCase {
    private struct FrameProbe: NSViewRepresentable {
        let key: String
        func makeNSView(context: Context) -> NSView {
            let view = NSView(); view.identifier = NSUserInterfaceItemIdentifier(key); return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }
    private struct AXElement {
        let object: NSObject
        let element: any NSAccessibilityElementProtocol
        var label: String? { string(#selector(NSAccessibilityProtocol.accessibilityLabel)) }
        var value: String? { string(#selector(NSAccessibilityProtocol.accessibilityValue)) }
        private func string(_ selector: Selector) -> String? {
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue() as? String
        }
        func press() -> Bool {
            let selector = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
            guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(implementation, to: Press.self)(object, selector)
        }
    }
    private func elements(_ node: Any) -> [AXElement] {
        guard let object = node as? NSObject else { return [] }
        var result: [AXElement] = []
        if let element = object as? any NSAccessibilityElementProtocol { result.append(AXElement(object: object, element: element)) }
        let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [Any] {
            result += children.flatMap(elements)
        }
        return result
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private var output: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOTIST_SETTINGS_ARTIFACTS"] ?? FileManager.default.temporaryDirectory.path)
    }
    private func capture(_ host: NSView, _ name: String) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        return bitmap
    }
    override func setUp() async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
    }
    func testLongDatabasePathAndFinderButtonStayInsideMinimumForm() async throws {
        let path = "/Users/example/Library/Application Support/Dotist/backups/2026-11-04/project-workspace/tasks.sqlite"
        for (language, title, button) in [("en", "Database path", "Show in Finder"), ("fr", "Chemin de la base de données", "Afficher dans le Finder"), ("de", "Datenbankpfad", "Im Finder anzeigen"), ("zh-CN", "数据库路径", "在 Finder 中显示")] {
            for width in [533.0, 613.0] {
                let row = SettingsFormRow(title: title, language: language) {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(path).font(DotistDesign.font(12, language: language)).lineLimit(3).textSelection(.enabled)
                            .background(FrameProbe(key: "path"))
                        Button(button) {}.background(FrameProbe(key: "finder"))
                    }.padding(.vertical, 6)
                }
                let host = NSHostingView(rootView: SettingsGroup("Data", language: language) { row }.frame(width: width).background(.white))
                host.frame.size = host.fittingSize
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
                let probes = descendants(host).filter { ["path", "finder"].contains($0.identifier?.rawValue ?? "") }
                XCTAssertEqual(probes.count, 2)
                for probe in probes {
                    let frame = host.convert(probe.bounds, from: probe)
                    print("F1 \(language) width=\(width) \(probe.identifier!.rawValue)=\(frame)")
                    XCTAssertGreaterThanOrEqual(frame.minX, 13.5, "\(language) \(probe.identifier!.rawValue)")
                    XCTAssertLessThanOrEqual(frame.maxX, width - 13.5, "\(language) \(probe.identifier!.rawValue)")
                    if probe.identifier?.rawValue == "path" && width == 533 {
                        XCTAssertGreaterThan(frame.height, 20, "The long path must receive a wrapping width")
                    }
                }
                _ = try capture(host, "F1-form-\(language)-\(Int(width))")
            }
        }
    }
    func testDataPageAtMinimumWidthWithAnIsolatedLongDatabasePath() async throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let directory = output.appendingPathComponent("F1-data-" + UUID().uuidString)
            .appendingPathComponent("Application Support/Dotist/backups/2026-11-04/project-workspace")
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        for language in ["zh-CN", "en", "fr", "de"] {
            for theme in ["light", "dark"] {
                var patch = DotistSettingsPatch(); patch.language = language; patch.theme = theme
                _ = try store.updateSettings(patch)
                let model = try AppModel(store: store)
                for width in [800.0, 880.0] {
                    let root = SettingsWindow(model: model, updater: NativeUpdater(model: model), beginShortcutCapture: {}, endShortcutCapture: { _, _ in }, resetWindowSize: {}, initialModule: .data)
                        .frame(width: width, height: 540)
                    let host = NSHostingView(rootView: root); host.frame.size = host.fittingSize
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = host
                    window.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                    try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
                    let finder = try XCTUnwrap(elements(host).first { $0.label == model.text("在 Finder 中显示") })
                    let frame = host.convert(window.convertFromScreen(finder.element.accessibilityFrame()), from: nil)
                    print("F1 data \(language) \(theme) width=\(width) finder=\(frame)")
                    XCTAssertGreaterThanOrEqual(frame.minX, 254)
                    XCTAssertLessThanOrEqual(frame.maxX, width - 39.5, "Finder action must remain within the form")
                    _ = try capture(host, "F1-data-\(language)-\(theme)-\(Int(width))x540")
                    XCTAssertFalse(window.isVisible)
                    window.close()
                }
            }
        }
    }
    func testPreviewSearchChangesBodyForNormalAndReducedMotionWithoutPlaying() async throws {
        // Enable AX only for this unordered test process; no global setting or desktop input.
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let directory = output.appendingPathComponent("F2-fixture-" + UUID().uuidString)
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = DotistSettingsPatch(); patch.language = "zh-CN"; patch.theme = "light"
        _ = try store.updateSettings(patch)
        let model = try AppModel(store: store)
        for reduceMotion in [false, true] {
            // The SDK's writable backing environment key simulates the read-only
            // accessibilityReduceMotion input locally, without changing macOS.
            let root = SettingsWindow(model: model, updater: NativeUpdater(model: model), beginShortcutCapture: {}, endShortcutCapture: { _, _ in }, resetWindowSize: {})
                .environment(\._accessibilityReduceMotion, reduceMotion).frame(width: 800, height: 660)
            let host = NSHostingView(rootView: root)
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
            let field = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "settings-search" })
            field.stringValue = "便签入场预览"
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
            let result = try XCTUnwrap(elements(host).first { $0.element.accessibilityIdentifier?() == "settings-result-appearance.便签入场预览" })
            XCTAssertTrue(result.press(), "Invoke only this host's public AX action")
            try await Task.sleep(for: .milliseconds(320)); host.layoutSubtreeIfNeeded()
            let play = try XCTUnwrap(elements(host).first { $0.element.accessibilityIdentifier?() == "settings-preview-play" })
            let playRect = host.convert(window.convertFromScreen(play.element.accessibilityFrame()), from: nil)
            // SwiftUI omits passive title nodes from this AX tree. Crop the body
            // text column above the real play button, excluding sidebar feedback.
            let titleRect = CGRect(x: playRect.minX, y: max(0, playRect.minY - 90),
                                   width: host.bounds.maxX - 40 - playRect.minX, height: 80)
            XCTAssertEqual(play.value, "预览就绪", "Search must not start playback")
            let active = try capture(host, "F2-search-active-reduced-\(reduceMotion)")
            try await Task.sleep(for: .milliseconds(1400))
            let idle = try capture(host, "F2-search-idle-reduced-\(reduceMotion)")
            XCTAssertEqual(play.value, "预览就绪")
            let scale = CGFloat(active.pixelsWide) / host.bounds.width
            var changed = 0
            for y in max(0, Int(titleRect.minY * scale))..<min(active.pixelsHigh, Int(titleRect.maxY * scale)) {
                for x in max(0, Int(titleRect.minX * scale))..<min(active.pixelsWide, Int(titleRect.maxX * scale)) {
                    let a = try XCTUnwrap(active.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let b = try XCTUnwrap(idle.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.05 { changed += 1 }
                }
            }
            print("F2 reduced=\(reduceMotion) title=\(titleRect) changedPixels=\(changed)")
            XCTAssertGreaterThan(changed, 30, "The located preview title must visibly emphasize and then clear")
            XCTAssertFalse(window.isVisible)
        }
    }
}
