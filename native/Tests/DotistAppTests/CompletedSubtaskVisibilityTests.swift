import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class CompletedSubtaskVisibilityTests: XCTestCase {
    /// Keep toolbar/group fixture state entirely in memory.
    private final class Defaults: UserDefaults {
        override func data(forKey defaultName: String) -> Data? { nil }
        override func stringArray(forKey defaultName: String) -> [String]? { nil }
        override func set(_ value: Any?, forKey defaultName: String) {}
    }

    private func elements(_ node: NSObject) -> [NSObject] {
        let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        let children = node.responds(to: selector)
            ? node.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
        return [node] + children.flatMap(elements)
    }

    func testHidingCompletedChildrenPreservesParentProgressAndRestoresRows() async throws {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let saved = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(saved, forAttribute: enhanced) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-completed-child-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let parent = try store.addTask(title: "Open parent")
        let done = try store.addTask(title: "Completed child", parentId: parent.id)
        let open = try store.addTask(title: "Open child", parentId: parent.id)
        _ = try store.patchTask(id: done.id, completed: true)
        var settings = DotistSettingsPatch(); settings.language = "en"
        _ = try store.updateSettings(settings)
        let model = try AppModel(store: store)
        let defaults = Defaults()
        let toolbar = ToolbarConfig(defaults: defaults)
        toolbar.setVisibility(.always, for: .completion)
        let state = TaskPanelState(scope: "all", collapseStore: TaskGroupCollapseStore(defaults: defaults))
        var rows: [TaskListRowFrame] = []
        let view = MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {},
                              showGroupPanel: { _ in }, collapse: {}, toolbarConfig: toolbar)
            .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
        let fixture = NativeRenderingFixture(view, size: CGSize(width: 364, height: 620))
        defer { fixture.close() }
        for (index, hidden) in [false, true, false].enumerated() {
            if index > 0 {
                let toggle = try XCTUnwrap(elements(fixture.host).first {
                    ($0 as? any NSAccessibilityElementProtocol)?.accessibilityIdentifier?() == "completion-filter"
                })
                let selector = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
                let method = try XCTUnwrap(toggle.method(for: selector))
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                XCTAssertTrue(unsafeBitCast(method, to: Press.self)(toggle, selector))
            }
            try await Task.sleep(for: .milliseconds(250))
            _ = try await fixture.capture(scale: 2)
            let ids = Set(rows.map(\.task.id))
            XCTAssertEqual(ids, hidden ? [parent.id, open.id] : [parent.id, done.id, open.id])
            let progress = try XCTUnwrap(elements(fixture.host).first {
                ($0 as? any NSAccessibilityElementProtocol)?.accessibilityIdentifier?() == "task-progress:\(parent.id)"
            })
            let value = #selector(NSAccessibilityProtocol.accessibilityValue)
            let expected = model.text("子任务 {done}/{total}")
                .replacingOccurrences(of: "{done}", with: "1").replacingOccurrences(of: "{total}", with: "2")
            XCTAssertEqual(progress.perform(value)?.takeUnretainedValue() as? String, expected,
                "The real parent badge must stay 1/2, including while its completed child is hidden")
            XCTAssertFalse(fixture.window.isVisible)
        }
    }
}
