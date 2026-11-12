import AppKit
import DotistCore
import GRDB
import XCTest
import SwiftUI
@testable import DotistApp

@MainActor
final class BubbleContentTests: XCTestCase {
    private func store() throws -> TaskStore {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-bubble-wJ3-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
    }

    func testCacheIgnoresSurfaceInsets() throws {
        let model = try AppModel(store: store())
        let state = TaskPanelState()
        let cache = BubbleContentCache()
        let surface = PanelSurfaceInsets()
        _ = cache.content(model: model, state: state, title: "Panel")
        surface.value = EdgeInsets(top: 2, leading: 1, bottom: 2, trailing: 1)
        _ = cache.content(model: model, state: state, title: "Panel")
        XCTAssertEqual(cache.buildCount, 1)
        state.groupID = "other"
        _ = cache.content(model: model, state: state, title: "Panel")
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testMainBubbleSelectsAndCountsOnlyOpenRoots() throws {
        let store = try store()
        let parent = try store.addTask(title: "Parent", category: DotistGroup.inboxID)
        _ = try store.addTask(title: "Child", category: DotistGroup.inboxID, parentId: parent.id, dueDate: "2026-11-01")
        let other = try store.addTask(title: "Completed parent", category: "work")
        let child = try store.addTask(title: "Open child of completed parent", category: "work", parentId: other.id)
        _ = try store.patchTask(id: other.id, completed: true)
        _ = try store.patchTask(id: child.id, completed: false)
        let model = try AppModel(store: store)
        XCTAssertEqual(model.nextTask?.id, parent.id)
        XCTAssertEqual(model.bubbleTitle, parent.title)
        XCTAssertEqual(model.remainingCount, 1)
        let strip = BubbleContent(model: model)
        XCTAssertEqual(strip.task?.id, parent.id)
        XCTAssertEqual(strip.title, parent.title)
        XCTAssertEqual(strip.remaining, 1)
        XCTAssertNil(strip.due, "A child's due date must never leak into the parent's strip")
    }

    func testGroupBubbleTitleIsTheParentTitleAndCountExcludesChildren() throws {
        let store = try store()
        let parent = try store.addTask(title: "Group parent", category: "work")
        _ = try store.addTask(title: "Child", category: "work", parentId: parent.id)
        _ = try store.addTask(title: "Other group", category: "life")
        let model = try AppModel(store: store)
        let panel = GroupPanelController(model: model, groupID: "work", near: .zero,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, didClose: { _ in })
        defer { panel.close() }
        XCTAssertEqual(panel.bubbleTitle, parent.title)
        XCTAssertEqual(panel.remaining, 1)
    }

    func testMainStripUsesTheSameInboxPriorityAsItsMeasuredTitle() throws {
        let store = try store()
        let finished = try store.addTask(title: "Completed", category: DotistGroup.inboxID)
        _ = try store.patchTask(id: finished.id, completed: true)
        _ = try store.addTask(title: "Work position zero", category: "work")
        let inbox = try store.addTask(title: "Inbox position one", category: DotistGroup.inboxID)
        let model = try AppModel(store: store)
        let strip = BubbleContent(model: model)
        XCTAssertEqual(strip.task?.id, inbox.id)
        XCTAssertEqual(strip.title, model.bubbleTitle)
        XCTAssertEqual(strip.remaining, 2)
    }

    func testGroupIdentityDoesNotDependOnDuplicateDisplayNames() throws {
        let store = try store()
        let work = try store.addTask(title: "Work parent", category: "work")
        let life = try store.addTask(title: "Life parent", category: "life")
        let db = try DatabaseQueue(path: store.databasePath())
        try db.write { db in try db.execute(sql: "UPDATE task_groups SET name='Same name' WHERE id IN ('work','life')") }
        let model = try AppModel(store: store)
        XCTAssertEqual(BubbleContent(model: model, groupID: "work").task?.id, work.id)
        XCTAssertEqual(BubbleContent(model: model, groupID: "life").task?.id, life.id)
        XCTAssertEqual(BubbleContent(model: model, groupID: "life").remaining, 1)
    }

    func testMetadataOmitsSeparatorsForMissingAndBlankFields() throws {
        let store = try store()
        _ = try store.addTask(title: "No metadata", category: DotistGroup.inboxID)
        _ = try store.addTask(title: "Group only", category: "work")
        let due = "2026-11-12"
        _ = try store.addTask(title: "Due only", category: "life", dueDate: due)
        _ = try store.addTask(title: "Both fields", category: "study", dueDate: due)
        let db = try DatabaseQueue(path: store.databasePath())
        try db.write { db in try db.execute(sql: "UPDATE task_groups SET name='  ' WHERE id='life'") }
        let model = try AppModel(store: store)
        XCTAssertEqual(BubbleContent(model: model).subtitle, "")
        XCTAssertEqual(BubbleContent(model: model, groupID: "work").subtitle, model.groupDisplayName("work"))
        XCTAssertEqual(BubbleContent(model: model, groupID: "life").subtitle, model.dueLabel(due))
        XCTAssertEqual(BubbleContent(model: model, groupID: "study").subtitle, model.groupDisplayName("study") + " · " + model.dueLabel(due))
        for blank in ["", "  ", "\n\t"] { XCTAssertNil(BubbleContent.clean(blank)) }
    }

    func testLegacyBlankTitleHasALocalizedFallbackWithoutEllipses() throws {
        let store = try store()
        let task = try store.addTask(title: "Legacy title", category: DotistGroup.inboxID)
        let db = try DatabaseQueue(path: store.databasePath())
        try db.write { db in try db.execute(sql: "UPDATE tasks SET title='  ' WHERE id=?", arguments: [task.id]) }
        let model = try AppModel(store: store)
        XCTAssertEqual(model.bubbleTitle, model.text("未命名任务"))
        XCTAssertEqual(BubbleContent(model: model).title, model.bubbleTitle)
        XCTAssertEqual(BubbleContent(model: model).subtitle, "")
    }
}
