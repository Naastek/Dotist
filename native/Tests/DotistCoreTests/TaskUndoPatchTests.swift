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
}
