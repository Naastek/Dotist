import AppKit
import DotistCore
import XCTest
@testable import DotistApp

@MainActor
final class TaskPanelTests: XCTestCase {
    func testDragStaysActiveUntilItsSessionEndsAndThenAppliesQueuedChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-drag-test-\(UUID().uuidString)")
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = try store.addTask(title: "拖动中的任务", category: DotistGroup.inboxID)
        let model = try AppModel(store: store)
        model.beginDrag(task.id, scope: "group:inbox:false")
        _ = try store.patchTask(id: task.id, title: "另一个面板的修改")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.dragId, task.id, "A drag ends with its session, not a global mouse-button poll")
        XCTAssertEqual(model.tasks.first?.title, "拖动中的任务")
        model.endDrag()
        XCTAssertNil(model.dragId)
        XCTAssertNil(model.dragScope)
        XCTAssertEqual(model.tasks.first?.title, "另一个面板的修改")
    }

    func testGroupPanelsKeepNavigationAndCompactGeometryIndependent() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-panel-test-\(UUID().uuidString)")
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        var closed = 0
        let work = GroupPanelController(model: model, groupID: "work", near: NSRect(x: 700, y: 100, width: 364, height: 620),
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, didClose: { _ in closed += 1 })
        let life = GroupPanelController(model: model, groupID: "life", near: NSRect(x: 1100, y: 100, width: 364, height: 620),
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, didClose: { _ in closed += 1 })
        defer {
            if work.window?.contentView != nil { work.close() }
            if life.window?.contentView != nil { life.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        work.state.scope = "today"
        work.state.groupID = "study"
        XCTAssertEqual(life.state.groupID, "life")
        XCTAssertEqual(life.state.scope, "all")
        XCTAssertEqual(model.scope, "all")
        let expanded = try XCTUnwrap(work.window).frame.size
        work.toggleCompact()
        life.toggleCompact()
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !work.motion.animationInProgress && !life.motion.animationInProgress }, object: nil)
        await fulfillment(of: [collapsed], timeout: 3)
        XCTAssertEqual(work.window?.frame.size, NSSize(width: 48, height: 48))
        XCTAssertEqual(life.window?.frame.size, NSSize(width: 48, height: 48))
        work.toggleCompact()
        let expandedAgain = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !work.motion.animationInProgress }, object: nil)
        await fulfillment(of: [expandedAgain], timeout: 3)
        XCTAssertEqual(work.window?.frame.size, expanded)
        XCTAssertFalse(work.compact)
        XCTAssertTrue(life.compact)
        work.close()
        life.close()
        XCTAssertEqual(closed, 2)
        XCTAssertNil(work.window?.contentView)
        XCTAssertNil(life.window?.contentView)
    }
}
