import Foundation
import GRDB
import XCTest
@testable import DotistCore

final class TaskUndoPatchTests: XCTestCase {
    private func store() throws -> TaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-undo-core-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
    }

    // Every persisted task field must round-trip, except the sync revision:
    // undo/redo are new mutations and must advance that counter.
    private func rows(_ store: TaskStore) throws -> [String] {
        try store.listTasks().map { task in
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
            value.removeValue(forKey: "revision")
            return String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
        }.sorted()
    }

    @discardableResult private func roundTrip(_ store: TaskStore, file: StaticString = #filePath, line: UInt = #line, _ operation: (TaskStore) throws -> Void) throws -> TaskMutationPatch {
        let before = try rows(store)
        let patch = try store.captureChanges(operation)
        let after = try rows(store)
        XCTAssertFalse(patch.isEmpty, file: file, line: line)
        try store.apply(patch: patch.before)
        XCTAssertEqual(try rows(store), before, file: file, line: line)
        XCTAssertEqual(try store.listTasks().count, before.count, file: file, line: line)
        try store.apply(patch: patch.after)
        XCTAssertEqual(try rows(store), after, file: file, line: line)
        XCTAssertEqual(try store.listTasks().count, after.count, file: file, line: line)
        return patch
    }

    func testCompleteAndUncompletePreserveEntireSubtree() throws {
        let store = try store()
        let root = try store.addTask(title: "parent", category: "work")
        let child = try store.addTask(title: "child", category: "work", parentId: root.id)
        let done = try store.addTask(title: "already done", category: "work", parentId: root.id)
        _ = try store.patchTask(id: done.id, completed: true)
        let patch = try roundTrip(store) { _ = try $0.patchTask(id: root.id, completed: true) }
        XCTAssertEqual(Set(patch.before.tasks.map(\.id)), Set([root.id, child.id]))
        try roundTrip(store) { _ = try $0.patchTask(id: root.id, completed: false) }
    }

    func testTitleDatesAndCategoryRoundTripWithoutUnrelatedSnapshots() throws {
        let store = try store()
        let root = try store.addTask(title: "parent", category: "work")
        let child = try store.addTask(title: "child", category: "work", parentId: root.id)
        let unrelated = try store.addTask(title: "unrelated", category: "study")
        let title = try roundTrip(store) { _ = try $0.patchTask(id: root.id, title: "renamed #tag") }
        XCTAssertEqual(title.before.tasks.map(\.id), [root.id])
        try roundTrip(store) { _ = try $0.setDueDate(root.id, date: "2026-11-12") }
        try roundTrip(store) { _ = try $0.setDateRange(root.id, start: "2026-11-01", due: "2026-11-20") }
        let category = try roundTrip(store) { _ = try $0.patchTask(id: root.id, category: "life") }
        XCTAssertEqual(Set(category.before.tasks.map(\.id)), Set([root.id, child.id]))
        XCTAssertEqual(try store.listTasks().first { $0.id == unrelated.id }, unrelated)
    }

    func testIndentOutdentAndMultipleSelection() throws {
        let store = try store()
        _ = try store.addTask(title: "parent", category: "work")
        let first = try store.addTask(title: "first", category: "work")
        let child = try store.addTask(title: "child", category: "work", parentId: first.id)
        let second = try store.addTask(title: "second", category: "work")
        try roundTrip(store) { _ = try $0.indent(ids: [first.id]) }
        try roundTrip(store) { _ = try $0.outdent(ids: [first.id]) }
        try roundTrip(store) { _ = try $0.indent(ids: [first.id, child.id, second.id]) }
        try roundTrip(store) { _ = try $0.outdent(ids: [first.id, second.id]) }
    }

    func testCrossGroupCommitAndReorderCaptureAllRepositionedRows() throws {
        let store = try store()
        let source = try store.addTask(title: "source", category: "work")
        let child = try store.addTask(title: "child", category: "work", parentId: source.id)
        let first = try store.addTask(title: "first", category: "life")
        let last = try store.addTask(title: "last", category: "life")
        let patch = try roundTrip(store) { try $0.commitReorder(source.id, groupID: "life", parentID: nil, beforeID: first.id) }
        XCTAssertTrue(Set(patch.before.tasks.map(\.id)).isSuperset(of: [source.id, child.id]))
        try roundTrip(store) { try $0.reorder(source.id, relativeTo: last.id, after: true, allTasks: false) }
    }

    func testAddAndBatchAddUndoUseTombstonesAndRedoSameIdentities() throws {
        let store = try store()
        _ = try store.addTask(title: "existing", category: "work")
        let patch = try roundTrip(store) { _ = try $0.addTask(title: "new", category: "life", dueDate: "2026-11-12") }
        XCTAssertEqual(patch.before.missingTaskIDs, Set(patch.after.tasks.map(\.id)))
        try roundTrip(store) { _ = try $0.addTasks([.init(title: "one", category: "work"), .init(title: "two", category: "study")]) }
        XCTAssertGreaterThan(try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox WHERE kind='delete'") ?? 0 }, 0)
    }

    func testDeleteRestoresFiveLevelSubtreeIncludingCompletionHistory() throws {
        let store = try store()
        let root = try store.addTask(title: "root", category: "work")
        var parent = root
        for index in 1...4 { parent = try store.addTask(title: "level \(index)", category: "work", parentId: parent.id) }
        _ = try store.patchTask(id: parent.id, completed: true)
        let patch = try roundTrip(store) { try $0.deleteTask(root.id) }
        XCTAssertEqual(patch.before.tasks.count, 5)
        XCTAssertEqual(try store.listTasks().count, 0)
    }

    func testGroupDeleteRestoreAndCreationAreOneActionWithTheirTasks() throws {
        let store = try store()
        let group = try store.addGroup(name: "project")
        let root = try store.addTask(title: "root", category: group.id)
        _ = try store.addTask(title: "child", category: group.id, parentId: root.id)
        let groups = try store.listGroups()
        let patch = try store.captureChanges { try $0.deleteGroup(group.id) }
        XCTAssertEqual(patch.before.groups.count, 1)
        XCTAssertEqual(patch.before.tasks.count, 2)
        try store.apply(patch: patch.before)
        XCTAssertEqual(try store.listGroups(), groups)
        XCTAssertEqual(try store.listTasks().count, 2)
        try store.apply(patch: patch.after)
        XCTAssertEqual(try store.listTasks().count, 2)
        XCTAssertTrue(try store.listTasks().allSatisfy { $0.category == DotistGroup.inboxID })
        let created = try store.captureChanges { store in
            let group = try store.addGroup(name: "new group")
            _ = try store.addTask(title: "new task", category: group.id)
        }
        try store.apply(patch: created.before)
        XCTAssertEqual(try store.listTasks().count, 2)
        try store.apply(patch: created.after)
        XCTAssertEqual(try store.listTasks().count, 3)
    }

    func testNoOpAndFailedActionsDoNotCreateHistoryOrPartialChanges() throws {
        let store = try store()
        let task = try store.addTask(title: "same", category: "work")
        XCTAssertTrue(try store.captureChanges { _ = try $0.patchTask(id: task.id, title: task.title) }.isEmpty)
        let before = try store.snapshot()
        let outbox = try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }
        XCTAssertThrowsError(try store.captureChanges {
            _ = try $0.patchTask(id: task.id, title: "must roll back")
            _ = try $0.addTask(title: "", category: "work")
        })
        XCTAssertEqual(try store.snapshot(), before)
        XCTAssertEqual(try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }, outbox)
        // A rolled-back capture does not leave the connection in capture mode.
        try roundTrip(store) { _ = try $0.patchTask(id: task.id, title: "works") }
    }

    private func modified(_ task: DotistTask, values: [String: Any]) throws -> DotistTask {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        object.merge(values) { _, new in new }
        return try JSONDecoder().decode(DotistTask.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testRestoreRejectsCyclesOrphansWrongCategoriesAndDepthAndRollsBackOutbox() throws {
        let store = try store()
        let root = try store.addTask(title: "root", category: "work")
        var leaf = root
        for index in 1...4 { leaf = try store.addTask(title: "level \(index)", category: "work", parentId: leaf.id) }
        let other = try store.addTask(title: "other", category: "work")
        let before = try store.snapshot()
        let outbox = try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }
        for invalid in [
            try modified(root, values: ["parentId": leaf.id]),
            try modified(other, values: ["parentId": "missing"]),
            try modified(leaf, values: ["category": "life"]),
            try modified(other, values: ["parentId": leaf.id]),
        ] {
            XCTAssertThrowsError(try store.restore(snapshots: [invalid]))
            XCTAssertEqual(try store.snapshot(), before)
            XCTAssertEqual(try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }, outbox)
        }
    }

    func testUndoRedoAdvanceSyncRevisionsWithAccurateBaseAndPayload() throws {
        let store = try store()
        let task = try store.addTask(title: "before", category: "work")
        let patch = try store.captureChanges { _ = try $0.patchTask(id: task.id, title: "after") }
        for point in [patch.before, patch.after] {
            let old = try XCTUnwrap(store.listTasks().first)
            try store.apply(patch: point)
            let restored = try XCTUnwrap(store.listTasks().first)
            XCTAssertEqual(restored.revision, old.revision + 1)
            let row = try XCTUnwrap(store.database.read { try Row.fetchOne($0, sql: "SELECT * FROM sync_outbox WHERE task_id=? ORDER BY rowid DESC LIMIT 1", arguments: [task.id]) })
            XCTAssertEqual(row["base_revision"] as Int64, old.revision)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((row["payload"] as String).utf8)) as? [String: Any])
            XCTAssertEqual(json["revision"] as? Int64, restored.revision)
            XCTAssertEqual(json["title"] as? String, restored.title)
        }
    }

    func testPatchMergeCoalescesSequentialEditsAndCancelsRoundTripNoOp() throws {
        let store = try store()
        let task = try store.addTask(title: "A", category: "work")
        let first = try store.captureChanges { _ = try $0.patchTask(id: task.id, title: "AB") }
        let second = try store.captureChanges { _ = try $0.patchTask(id: task.id, title: "ABC") }
        let merged = first.merged(with: second)
        XCTAssertFalse(merged.isEmpty)
        XCTAssertEqual(merged.before.tasks.first?.title, "A")
        XCTAssertEqual(merged.after.tasks.first?.title, "ABC")

        try store.apply(mutation: merged, redo: false)
        XCTAssertEqual(try store.listTasks().first?.title, "A")
        try store.apply(mutation: merged, redo: true)
        XCTAssertEqual(try store.listTasks().first?.title, "ABC")

        let backToStart = try store.captureChanges { _ = try $0.patchTask(id: task.id, title: "A") }
        let cancelled = merged.merged(with: backToStart)
        XCTAssertTrue(cancelled.isEmpty)
    }

    func testSelectiveAgentUndoPreservesLaterUserEditsAndUserSubtasks() throws {
        let store = try store()
        let taskA = try store.addTask(title: "Original A", category: "work")

        // Agent batch: creates B, C, D and sets due date on A.
        var taskB: DotistTask!
        var taskC: DotistTask!
        var taskD: DotistTask!
        let agentPatch = try store.captureChanges { s in
            let created = try s.addTasks([
                .init(title: "AI B", category: "work"),
                .init(title: "AI C", category: "work"),
                .init(title: "AI D", category: "work"),
            ])
            taskB = created[0]
            taskC = created[1]
            taskD = created[2]
            _ = try s.setDueDate(taskA.id, date: "2026-12-01")
        }

        // Later user edits:
        // - Renames A (different field than agent's dueDate)
        // - Edits B's title (modified an agent-created task)
        // - Adds a user subtask under C (depends on agent-created parent C)
        // - Leaves D untouched
        _ = try store.patchTask(id: taskA.id, title: "User Edited A")
        _ = try store.patchTask(id: taskB.id, title: "User Refined B")
        let userSubtask = try store.addTask(title: "User Subtask", category: "work", parentId: taskC.id)

        try store.applySelectiveUndo(of: agentPatch)

        let remaining = try store.listTasks()
        let byID = Dictionary(uniqueKeysWithValues: remaining.map { ($0.id, $0) })
        // A keeps user title while agent dueDate is reverted.
        XCTAssertEqual(byID[taskA.id]?.title, "User Edited A")
        XCTAssertNil(byID[taskA.id]?.dueDate)
        // B was edited by user -> preserved.
        XCTAssertEqual(byID[taskB.id]?.title, "User Refined B")
        // C is ancestor of user subtask -> preserved along with user subtask.
        XCTAssertNotNil(byID[taskC.id])
        XCTAssertEqual(byID[userSubtask.id]?.parentId, taskC.id)
        // D was untouched by user -> removed.
        XCTAssertNil(byID[taskD.id])
    }

    func testSelectiveAgentUndoOfDeleteGroupMigratesUserAddedSubtreeTogether() throws {
        let store = try store()
        let group = try store.addGroup(name: "Project X")
        let parent = try store.addTask(title: "Parent", category: group.id)

        // Agent deletes the group; parent migrates to inbox.
        let deleteGroupPatch = try store.captureChanges { try $0.deleteGroup(group.id) }
        XCTAssertEqual(try store.listTasks().first { $0.id == parent.id }?.category, DotistGroup.inboxID)

        // User adds a subtask under the migrated parent while in inbox.
        let child = try store.addTask(title: "User Child", category: DotistGroup.inboxID, parentId: parent.id)

        // Selective undo restores group and moves both parent and user-added child back together.
        try store.applySelectiveUndo(of: deleteGroupPatch)

        XCTAssertTrue(try store.listGroups().contains { $0.id == group.id })
        let tasks = try store.listTasks()
        let restoredParent = try XCTUnwrap(tasks.first { $0.id == parent.id })
        let restoredChild = try XCTUnwrap(tasks.first { $0.id == child.id })
        XCTAssertEqual(restoredParent.category, group.id)
        XCTAssertEqual(restoredChild.parentId, parent.id)
        XCTAssertEqual(restoredChild.category, group.id)
    }

    func testSelectiveAgentUndoPreservesEarlierCompletionDateOnCompletedTask() throws {
        let store = try store()
        let task = try store.addTask(title: "Finished Yesterday", category: "work")
        _ = try store.patchTask(id: task.id, completed: true)
        let yesterdayStamp = "2026-11-26T09:00:00.000Z"
        try store.database.write { db in
            try db.execute(sql: "UPDATE tasks SET updated_at=? WHERE id=?", arguments: [yesterdayStamp, task.id])
        }

        // Agent edits only the title of the completed task.
        let agentPatch = try store.captureChanges {
            _ = try $0.patchTask(id: task.id, title: "AI Retitled")
        }
        // Restore yesterday's completion date on the DB row as if the task remained completed yesterday.
        try store.database.write { db in
            try db.execute(sql: "UPDATE tasks SET updated_at=? WHERE id=?", arguments: [yesterdayStamp, task.id])
        }

        try store.applySelectiveUndo(of: agentPatch)

        let restored = try XCTUnwrap(try store.listTasks().first { $0.id == task.id })
        XCTAssertEqual(restored.title, "Finished Yesterday")
        XCTAssertTrue(restored.completed)
        XCTAssertEqual(restored.updatedAt, yesterdayStamp)
    }
}
