import AppKit
import SwiftUI
import DotistCore
import XCTest
@testable import DotistApp

@MainActor
final class UnifiedFilterTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        addTeardownBlock { await MainActor.run { NSApp.accessibilitySetValue(previous, forAttribute: attribute) } }
    }
    func testClearPreservesGroupAndOtherPanelAndCountsRangeOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let state = TaskPanelState(groupID: "work", scope: "today")
        let other = TaskPanelState(groupID: "life", scope: "overdue")
        state.customStart = "2026-11-15"; state.customEnd = "2026-11-20"
        state.activeTag = "planning"; state.hideCompleted = true
        let view = MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {})
        XCTAssertEqual(view.additionalFilterCount, 2)
        view.clearAdditionalFilters()
        XCTAssertEqual(view.additionalFilterCount, 0)
        XCTAssertEqual(state.groupID, "work")
        XCTAssertEqual(state.scope, "today")
        XCTAssertEqual(state.customStart, "2026-11-15"); XCTAssertEqual(state.customEnd, "2026-11-20")
        XCTAssertNil(state.activeTag); XCTAssertFalse(state.hideCompleted)
        XCTAssertEqual(other.scope, "overdue")
        XCTAssertEqual(other.groupID, "life")
    }
    func testPanelAndNarrowHeaderRenderAndStrictDoneFilterHasClearAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let task = try store.addTask(title: "Finished #archive", category: "work")
        _ = try store.patchTask(id: task.id, completed: true)
        let model = try AppModel(store: store)
        let state = TaskPanelState(groupID: "work", scope: "done")
        state.hideCompleted = true; state.activeTag = "archive"
        let view = MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {})
        XCTAssertTrue(view.showsEmptyState)
        func element(_ root: NSObject, _ id: String) -> NSObject? {
            if (root as? any NSAccessibilityElementProtocol)?.accessibilityIdentifier?() == id { return root }
            let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
            guard root.responds(to: selector), let children = root.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return nil }
            return children.lazy.compactMap { element($0, id) }.first
        }
        let panel = NativeRenderingFixture(view.unifiedFilterPanel, size: CGSize(width: 300, height: 230))
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(element(panel.host, "tag-filter"))
        XCTAssertNotNil(element(panel.host, "completion-filter"))
        let panelImage = try await panel.capture(scale: 2)
        if let path = ProcessInfo.processInfo.environment["DOTIST_FILTER_EVIDENCE_DIR"] {
            try panelImage.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("附加筛选面板.png"))
        }
        let previous = ToolbarConfig.shared.visibility(of: .filters)
        ToolbarConfig.shared.setVisibility(.always, for: .filters)
        defer { ToolbarConfig.shared.setVisibility(previous, for: .filters) }
        for width in [320.0, 364.0] {
            let fixture = NativeRenderingFixture(view, size: CGSize(width: width, height: 620))
            defer { fixture.close() }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(fixture.window.isVisible)
            for id in ["unified-filter", "empty-open-filters"] {
                let node = try XCTUnwrap(element(fixture.host, id), id)
                let frame = (node as? any NSAccessibilityElementProtocol)?.accessibilityFrame() ?? .zero
                let bounds = fixture.window.convertToScreen(fixture.host.convert(fixture.host.bounds, to: nil))
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - 1)
                XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 1)
            }
            let image = try await fixture.capture(scale: 2)
            if let path = ProcessInfo.processInfo.environment["DOTIST_FILTER_EVIDENCE_DIR"] {
                try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("窄窗-\(Int(width)).png"))
            }
        }
    }
}
