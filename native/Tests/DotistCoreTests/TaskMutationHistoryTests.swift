import Foundation
import GRDB
import XCTest
@testable import DotistCore

final class TaskMutationHistoryTests: XCTestCase {
    private func store() throws -> TaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-history-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
    }

    func testCompletingParentPreservesPreviouslyCompletedChildHistory() throws {
        let store = try store()
        let parent = try store.addTask(title: "父任务", category: "work")
        let child = try store.addTask(title: "已完成子任务", category: "work", parentId: parent.id, dueDate: "2026-10-01")
        let open = try store.addTask(title: "未完成子任务", category: "work", parentId: parent.id)
        _ = try store.patchTask(id: child.id, completed: true)
        try store.database.write {
            try $0.execute(sql: "UPDATE tasks SET updated_at='2026-10-01T08:00:00Z' WHERE id=?", arguments: [child.id])
        }
        let completed = try XCTUnwrap(store.listTasks().first { $0.id == child.id })
        let outbox = try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }

        _ = try store.patchTask(id: parent.id, completed: true)

        XCTAssertEqual(try store.listTasks().first { $0.id == child.id }, completed)
        XCTAssertEqual(try store.listTasks().first { $0.id == open.id }?.status, .done)
        XCTAssertEqual(try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }, try XCTUnwrap(outbox) + 2)
    }

    func testRetagRecordsEachChangedTaskWithMatchingHistory() throws {
        let store = try store()
        let tasks = try store.addTasks([.init(title: "工作 #旧标签", category: "work"), .init(title: "生活 #旧标签", category: "life")])
        try store.database.write { try $0.execute(sql: "UPDATE tasks SET updated_at='2000-01-01T00:00:00Z'") }

        try store.retag("旧标签", replacement: "新标签")

        for original in tasks {
            let changed = try XCTUnwrap(store.listTasks().first { $0.id == original.id })
            XCTAssertTrue(changed.title.hasSuffix("#新标签"))
            XCTAssertEqual(changed.revision, original.revision + 1)
            XCTAssertNotEqual(changed.updatedAt, "2000-01-01T00:00:00Z")
            let row = try XCTUnwrap(store.database.read {
                try Row.fetchOne($0, sql: "SELECT base_revision,payload FROM sync_outbox WHERE task_id=? AND kind='update'", arguments: [original.id])
            })
            XCTAssertEqual(row["base_revision"] as Int64, original.revision)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((row["payload"] as String).utf8)) as? [String: Any])
            XCTAssertEqual(payload["title"] as? String, changed.title)
            XCTAssertEqual(payload["updated_at"] as? String, changed.updatedAt)
            XCTAssertEqual(payload["revision"] as? Int64, changed.revision)
        }
    }

    func testRetagRollsBackTheWholeBatchWhenATitleWouldExceedItsLimit() throws {
        let store = try store()
        _ = try store.addTasks([
            .init(title: "可以修改 #x", category: "work"),
            .init(title: String(repeating: "a", count: 497) + " #x", category: "life"),
        ])
        let before = try store.snapshot()
        let outbox = try store.database.read { try Row.fetchAll($0, sql: "SELECT * FROM sync_outbox ORDER BY operation_id").map(\.description) }

        XCTAssertThrowsError(try store.retag("x", replacement: "更长的标签"))

        XCTAssertEqual(try store.snapshot(), before)
        XCTAssertEqual(try store.database.read { try Row.fetchAll($0, sql: "SELECT * FROM sync_outbox ORDER BY operation_id").map(\.description) }, outbox)
    }

    func testCustomInboxGroupRestoresWithoutReclaimingMigratedTasks() throws {
        let store = try store()
        try store.database.write { try $0.execute(sql: "DELETE FROM task_groups WHERE id=?", arguments: [DotistGroup.inboxID]) }
        let group = try store.addGroup(name: "Inbox")
        let parent = try store.addTask(title: "旧收件箱任务", category: group.id, dueDate: "2026-11-10")
        let child = try store.addTask(title: "旧收件箱子任务", category: group.id, parentId: parent.id)
        _ = try store.patchTask(id: child.id, completed: true)
        let reopened = try TaskStore(databasePath: store.databasePath())

        try reopened.deleteGroup(group.id)
        XCTAssertEqual(try reopened.restoreGroup(group.id).id, group.id)

        XCTAssertEqual(Set(try reopened.listGroups().filter { $0.name == "Inbox" }.map(\.id)), Set([group.id, DotistGroup.inboxID]))
        let restoredParent = try XCTUnwrap(reopened.listTasks().first { $0.id == parent.id })
        let restoredChild = try XCTUnwrap(reopened.listTasks().first { $0.id == child.id })
        XCTAssertEqual(restoredParent.category, DotistGroup.inboxID)
        XCTAssertEqual(restoredParent.dueDate, parent.dueDate)
        XCTAssertEqual(restoredChild.category, DotistGroup.inboxID)
        XCTAssertEqual(restoredChild.parentId, parent.id)
        XCTAssertTrue(restoredChild.completed)
        XCTAssertEqual(try reopened.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox WHERE kind='restore'") }, 0)
        XCTAssertThrowsError(try reopened.addGroup(name: "Inbox"))
    }

    func testCustomInboxCanKeepItsNameWithoutAllowingNewNameConflicts() throws {
        let store = try store()
        try store.database.write { try $0.execute(sql: "DELETE FROM task_groups WHERE id=?", arguments: [DotistGroup.inboxID]) }
        let group = try store.addGroup(name: "Inbox")
        let reopened = try TaskStore(databasePath: store.databasePath())

        XCTAssertEqual(try reopened.updateGroup(group.id, color: "study").name, "Inbox")
        XCTAssertThrowsError(try reopened.updateGroup("work", name: "Inbox"))
        XCTAssertThrowsError(try reopened.addGroup(name: "Inbox"))

        let ordinary = try reopened.addGroup(name: "项目")
        try reopened.deleteGroup(ordinary.id)
        _ = try reopened.addGroup(name: "项目")
        XCTAssertThrowsError(try reopened.restoreGroup(ordinary.id))
    }
}
