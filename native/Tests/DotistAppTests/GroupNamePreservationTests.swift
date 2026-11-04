import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class GroupNamePreservationTests: XCTestCase {
    private final class FixtureDefaults: UserDefaults, @unchecked Sendable {
        override func set(_ value: Any?, forKey key: String) {}
        override func stringArray(forKey key: String) -> [String]? { nil }
    }

    private func field(_ name: String, in value: Any) throws -> Any {
        try XCTUnwrap(Mirror(reflecting: value).children.first { $0.label == name }?.value)
    }

    /// Inspect the controller's actual published layout without making its child
    /// window visible. This covers both displayed content and measured widths;
    /// snapshot APIs that accept names directly cannot catch controller translation.
    func testSidebarUsesStoredNamesForLabelsAndWidthsWhenLanguageChanges() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-group-names-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let names = ["全部", "工作", "无分组", "今天", "All", "Projects 工作", "日本語", "  My  spacing  "]
        let existing = try store.listGroups()
        let groups = try names.map { name in
            try existing.first { $0.name == name } ?? store.addGroup(name: name)
        }.filter { $0.id != DotistGroup.inboxID }
        let before = try store.listGroups()
        let model = try AppModel(store: store)
        let panel = DotistPanel(contentRect: CGRect(x: 500, y: 100, width: 364, height: 620),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let environment = PanelMotionTestEnvironment()
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" }, environment: environment.environment)
        let state = TaskPanelState(collapseStore: TaskGroupCollapseStore(defaults: FixtureDefaults()))
        let controller = SideTabsController(parent: panel, model: model, state: state, motion: motion)
        defer { controller.stop(); motion.stop(); panel.close() }
        for language in ["en", "fr", "de", "ja", "zh-TW", "zh-CN", "en"] {
            var patch = DotistSettingsPatch(); patch.language = language
            let saved = await withCheckedContinuation { continuation in
                model.updateSettings(patch) { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(saved)
            controller.synchronize(mouse: CGPoint(x: -10_000, y: -10_000))
            let presentation = try field("presentation", in: controller)
            let publishedRows = try field("_rows", in: presentation)
            // Published's public projected storage is not type-erased. Mirror the
            // controller's backing value, then ask its subject for the current value.
            let storage = try field("storage", in: publishedRows)
            let storageValue = try XCTUnwrap(Mirror(reflecting: storage).children.first?.value)
            let subject = try field("subject", in: storageValue)
            let current = try field("currentValue", in: subject)
            let rows = Mirror(reflecting: current).children.map(\.value)
            XCTAssertEqual(rows.count, model.visibleGroups.count + 1)
            for group in groups {
                let row = try XCTUnwrap(rows.first { (try? field("id", in: $0) as? String) == group.id })
                XCTAssertEqual(try field("name", in: row) as? String, group.name)
                let font = DotistDesign.nativeFont(13, weight: .semibold, serif: true, language: model.language)
                let regular = DotistDesign.nativeFont(13, serif: true, language: model.language)
                let expectedWidth = max(48, ceil(max((group.name as NSString).size(withAttributes: [.font: font]).width, (group.name as NSString).size(withAttributes: [.font: regular]).width)) + 28)
                XCTAssertEqual(try XCTUnwrap(try field("fullWidth", in: row) as? CGFloat), expectedWidth, accuracy: 0.01)
                XCTAssertEqual(model.groupDisplayName(group.id), group.name)
                XCTAssertEqual(model.composerGroupDisplayName(group.id), group.name)
            }
            let all = try XCTUnwrap(rows.first)
            XCTAssertEqual(try field("name", in: all) as? String, model.text("全部"))
            XCTAssertEqual(model.groupDisplayName(nil), model.text("无分组"))
            XCTAssertFalse(panel.isVisible)
            XCTAssertTrue(panel.childWindows?.allSatisfy { !$0.isVisible } ?? false)
            XCTAssertEqual(try store.listGroups(), before)
        }
    }

    private func descendants(_ node: NSObject) -> [NSObject] {
        let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        guard node.responds(to: selector) else { return [] }
        let children = node.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? []
        return children + children.flatMap(descendants)
    }

    func testSettingsSearchResultKeepsAGroupNamedLikeASystemLabel() async throws {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let saved = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(saved, forAttribute: enhanced) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-settings-group-name-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let group = try store.addGroup(name: "全部")
        var patch = DotistSettingsPatch(); patch.language = "en"
        _ = try store.updateSettings(patch)
        let model = try AppModel(store: store)
        let fixture = NativeRenderingFixture(SettingsWindow(model: model, updater: NativeUpdater(model: model),
            beginShortcutCapture: {}, endShortcutCapture: { _, _ in }, resetWindowSize: {}), size: CGSize(width: 800, height: 540))
        defer { fixture.close() }
        _ = try await fixture.capture(scale: 1)
        let search = try XCTUnwrap(fixture.descendants(NSTextField.self).first { $0.accessibilityIdentifier() == "settings-search" })
        search.stringValue = "全部"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        for _ in 0..<3 { _ = try await fixture.capture(scale: 1) }
        let result = try XCTUnwrap(descendants(fixture.host).first {
            ($0 as? any NSAccessibilityElementProtocol)?.accessibilityIdentifier?() == "settings-result-appearance.color-" + group.id
        })
        let labels = ([result] + descendants(result)).flatMap { node -> [String] in
            let selector = #selector(NSAccessibilityProtocol.accessibilityLabel)
            let label = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? String : nil
            return [label, node.accessibilityAttributeValue(.value) as? String].compactMap { $0 }
        }
        XCTAssertTrue(labels.contains { $0.contains("全部") }, "Stored group names must survive Settings search: \(labels)")
        XCTAssertFalse(labels.contains { $0.contains("All") }, "Only the separate synthetic system label is translated")
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertEqual(try store.listGroups().first { $0.id == group.id }?.name, "全部")
    }
}
