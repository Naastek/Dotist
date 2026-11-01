import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class SettingsLayoutTests: XCTestCase {
    func testSettingsRenderAtMinimumSizeInFourLanguagesAndBothAppearances() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wIC-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addGroup(name: "工作 Projects")
        for language in ["zh-CN", "en", "ja", "zh-TW"] {
            for theme in ["light", "dark"] {
                var patch = DotistSettingsPatch(); patch.language = language; patch.theme = theme
                _ = try store.updateSettings(patch)
                let model = try AppModel(store: store)
                let root = SettingsWindow(model: model, updater: NativeUpdater(model: model), beginShortcutCapture: {}, endShortcutCapture: { _, _ in }, resetWindowSize: {})
                    .frame(width: 800, height: 540)
                let host = NSHostingView(rootView: root)
                host.frame = NSRect(x: 0, y: 0, width: 800, height: 540)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, 800.5, "\(language) \(theme)")
                XCTAssertLessThanOrEqual(host.fittingSize.height, 540.5, "\(language) \(theme)")
                func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
                for control in descendants(host).compactMap({ $0 as? NSSegmentedControl }) {
                    let frame = host.convert(control.bounds, from: control)
                    XCTAssertLessThanOrEqual(frame.maxX, host.bounds.maxX - 26, "Segmented control overflow: \(language) \(theme)")
                    XCTAssertGreaterThanOrEqual(frame.minX, 240)
                    XCTAssertLessThanOrEqual(frame.width, 244.5)
                }
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 1000)
                try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wIC-settings-\(language)-\(theme).png"))
                window.close()
            }
        }
    }
    func testGroupedRowKeepsColorPaletteAndSwitchInsideMinimumContentWidth() {
        _ = NSApplication.shared
        let content = SettingsGroup("Color theme", language: "en") {
            SettingsFormRow(title: "All (default color)", language: "en") { Text("Control").frame(width: 231) }
            SettingsFormRow(title: "Switch", language: "en") { Toggle("Switch", isOn: .constant(true)).labelsHidden().toggleStyle(.switch).controlSize(.small) }
        }.font(DotistDesign.font(13, language: "en")).frame(width: 533)
        let host = NSHostingView(rootView: content)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 533.5)
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, 88)
    }
}
