import Foundation
import GRDB
import XCTest
@testable import DotistCore

final class TaskHierarchyTests: XCTestCase {
    private func store() throws -> TaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-depth-\(UUID().uuidString)")
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return store
    }

    private func chain(_ store: TaskStore, count: Int, parent: DotistTask? = nil, category: String = "work") throws -> [DotistTask] {
        var tasks: [DotistTask] = []
        for level in 0..<count {
            tasks.append(try store.addTask(title: "level \(level)", category: category, parentId: tasks.last?.id ?? parent?.id))
        }
        return tasks
    }

    private func outbox(_ store: TaskStore) throws -> [String] {
        try store.database.read { try Row.fetchAll($0, sql: "SELECT * FROM sync_outbox ORDER BY operation_id").map(\.description) }
    }

    func testFifthLevelAllowedSixthRejectedAndBatchRolledBack() throws {
        let store = try store()
        let tasks = try chain(store, count: 5)
        XCTAssertEqual(DotistTask.maxDepth, 4)
        for (level, task) in tasks.enumerated() {
            XCTAssertEqual(try store.depth(of: task.id), level)
            XCTAssertEqual(try store.subtreeHeight(of: task.id), 4 - level)
        }
        XCTAssertEqual(try store.children(of: tasks[0].id).map(\.id), [tasks[1].id])
        XCTAssertEqual(try store.descendants(of: tasks[0].id).map(\.id), tasks.dropFirst().map(\.id))
        let before = try store.snapshot(), history = try outbox(store)
        XCTAssertThrowsError(try store.addTasks([
            .init(title: "rolled back", category: "life"),
            .init(title: "sixth", category: "work", parentId: tasks[4].id)
        ])) { XCTAssertEqual($0.localizedDescription, "最多支持 5 层任务") }
        XCTAssertEqual(try store.snapshot(), before)
        XCTAssertEqual(try outbox(store), history)
    }

    func testRejectsSelfDescendantAndTooTallSubtreeWithoutWriting() throws {
        let store = try store()
        let tasks = try chain(store, count: 5)
        let other = try chain(store, count: 2, category: "life")
        let before = try store.snapshot(), history = try outbox(store)
        for parent in [tasks[0], tasks[1], tasks[4]] {
            XCTAssertThrowsError(try store.reparent(tasks[0].id, parentId: parent.id)) {
                XCTAssertEqual($0.localizedDescription, "不能将任务移到自己或自己的后代下面")
            }
        }
        XCTAssertThrowsError(try store.commitReorder(tasks[0].id, groupID: "work", parentID: tasks[3].id, beforeID: nil))
        XCTAssertThrowsError(try store.reparent(other[0].id, parentId: tasks[3].id)) {
            XCTAssertEqual($0.localizedDescription, "最多支持 5 层任务")
        }
        XCTAssertEqual(try store.snapshot(), before)
        XCTAssertEqual(try outbox(store), history)
        try store.reparent(other[0].id, parentId: tasks[2].id)
        XCTAssertEqual(try store.depth(of: other[1].id), 4)
        XCTAssertEqual(try store.listTasks().count, 7)
    }

    func testEveryCrossGroupPathMovesWholeSubtreeAndKeepsPositions() throws {
        let store = try store()
        let tasks = try chain(store, count: 4)
        let positions = tasks.dropFirst().map(\.position)
        _ = try store.patchTask(id: tasks[0].id, category: "life")
        XCTAssertTrue(try store.listTasks().allSatisfy { $0.category == "life" })
        let destination = try store.addTask(title: "parent", category: "study")
        try store.reparent(tasks[0].id, parentId: destination.id)
        XCTAssertTrue(try store.listTasks().allSatisfy { $0.category == "study" })
        try store.commitReorder(tasks[0].id, groupID: "work", parentID: nil, beforeID: nil)
        let moved = try store.listTasks()
        XCTAssertEqual(moved.filter { $0.category == "work" }.count, 4)
        XCTAssertEqual(tasks.dropFirst().map { original in moved.first { $0.id == original.id }!.position }, positions)
        XCTAssertEqual(try store.descendants(of: tasks[0].id).map(\.id), tasks.dropFirst().map(\.id))
        XCTAssertEqual(moved.count, 5)
    }

    func testDeepCompletionPreservesHistoryAndDoesNotAutoCompleteAncestors() throws {
        let store = try store()
        let tasks = try chain(store, count: 5)
        _ = try store.patchTask(id: tasks[4].id, completed: true)
        XCTAssertFalse(try store.listTasks().first { $0.id == tasks[3].id }!.completed)
        try store.database.write { try $0.execute(sql: "UPDATE tasks SET updated_at='2000-01-01T00:00:00Z' WHERE id=?", arguments: [tasks[4].id]) }
        let leaf = try XCTUnwrap(store.listTasks().first { $0.id == tasks[4].id })
        _ = try store.patchTask(id: tasks[0].id, completed: true)
        XCTAssertTrue(try store.listTasks().allSatisfy(\.completed))
        XCTAssertEqual(try store.listTasks().first { $0.id == leaf.id }, leaf)
        _ = try store.patchTask(id: tasks[0].id, completed: false)
        XCTAssertTrue(try store.descendants(of: tasks[0].id).allSatisfy(\.completed))
    }

    func testCascadeDeleteRestoreOnlySameBatchAtEveryDepth() throws {
        let store = try store()
        let tasks = try chain(store, count: 5)
        let sibling = try store.addTask(title: "sibling", category: "work", parentId: tasks[1].id)
        try store.deleteTask(tasks[3].id)
        try store.deleteTask(tasks[0].id)
        XCTAssertTrue(try store.listTasks().isEmpty)
        _ = try store.restoreTask(tasks[0].id)
        XCTAssertEqual(Set(try store.listTasks().map(\.id)), Set([tasks[0].id, tasks[1].id, tasks[2].id, sibling.id]))
        _ = try store.restoreTask(tasks[3].id)
        XCTAssertEqual(try store.descendants(of: tasks[0].id).count, 5)
        XCTAssertEqual(try store.depth(of: tasks[4].id), 4)
    }

    func testRestoreFollowsMovedParentAndRejectsDepthOverflow() throws {
        let store = try store()
        let tasks = try chain(store, count: 3)
        try store.deleteTask(tasks[1].id)
        _ = try store.patchTask(id: tasks[0].id, category: "life")
        _ = try store.restoreTask(tasks[1].id)
        XCTAssertTrue(try store.listTasks().allSatisfy { $0.category == "life" })
        try store.deleteTask(tasks[1].id)
        let deep = try chain(store, count: 3, category: "study")
        try store.reparent(tasks[0].id, parentId: deep[2].id)
        let before = try store.snapshot()
        XCTAssertThrowsError(try store.restoreTask(tasks[1].id))
        XCTAssertEqual(try store.snapshot(), before)
    }

    func testMultiIndentMixedParentsGroupsAndSelectedDescendants() throws {
        let store = try store()
        let parent = try store.addTask(title: "new parent", category: "work")
        let existing = try store.addTask(title: "existing", category: "work", parentId: parent.id)
        let first = try chain(store, count: 2)
        let laterParent = try store.addTask(title: "later parent", category: "life")
        let later = try store.addTask(title: "later", category: "life", parentId: laterParent.id)
        let result = try store.indent(ids: [later.id, first[1].id, first[0].id])
        XCTAssertEqual(result.map(\.id), [first[0].id, later.id])
        XCTAssertEqual(try store.children(of: parent.id).map(\.id), [existing.id, first[0].id, later.id])
        XCTAssertEqual(try store.children(of: first[0].id).map(\.id), [first[1].id])
        XCTAssertEqual(try store.listTasks().first { $0.id == later.id }?.category, "work")
        XCTAssertEqual(try store.listTasks().count, 6)
    }

    func testIndentUsesPreviousSiblingAtSameDepthAndPreservesOrder() throws {
        let store = try store()
        let root = try store.addTask(title: "root", category: "work")
        let previous = try store.addTask(title: "previous", category: "work", parentId: root.id)
        _ = try store.addTask(title: "previous's child", category: "work", parentId: previous.id)
        let a = try store.addTask(title: "a", category: "work", parentId: root.id)
        let b = try store.addTask(title: "b", category: "work", parentId: root.id)
        try store.indent(ids: [b.id, a.id])
        XCTAssertEqual(try store.children(of: previous.id).map(\.title), ["previous's child", "a", "b"])
        XCTAssertEqual(try store.depth(of: b.id), 2)
    }

    func testIndentMissingSiblingAndAnyOverflowAreAtomic() throws {
        let store = try store()
        let deep = try chain(store, count: 4)
        let a = try store.addTask(title: "a", category: "work", parentId: deep[1].id)
        let b = try chain(store, count: 3, category: "life")
        let before = try store.snapshot(), history = try outbox(store)
        XCTAssertThrowsError(try store.indent(ids: [deep[0].id, b[0].id])) {
            XCTAssertEqual($0.localizedDescription, "前面没有可以作为父任务的任务")
        }
        // a could move under deep[2], but b's two-edge subtree would overflow.
        XCTAssertThrowsError(try store.indent(ids: [b[0].id, a.id])) {
            XCTAssertEqual($0.localizedDescription, "最多支持 5 层任务")
        }
        XCTAssertEqual(try store.snapshot(), before)
        XCTAssertEqual(try outbox(store), history)
    }

    func testOutdentMixedParentsOneLevelAfterEachOriginalParent() throws {
        let store = try store()
        let root = try store.addTask(title: "root", category: "work")
        let p = try store.addTask(title: "p", category: "work", parentId: root.id)
        let a = try chain(store, count: 2, parent: p)
        let b = try store.addTask(title: "b", category: "work", parentId: p.id)
        let q = try store.addTask(title: "q", category: "work", parentId: root.id)
        let c = try store.addTask(title: "c", category: "work", parentId: q.id)
        let ignored = try store.addTask(title: "ignored root", category: "life")
        try store.outdent(ids: [c.id, b.id, a[1].id, ignored.id, a[0].id])
        XCTAssertEqual(try store.children(of: root.id).map(\.id), [p.id, a[0].id, b.id, q.id, c.id])
        XCTAssertEqual(try store.children(of: a[0].id).map(\.id), [a[1].id])
        XCTAssertEqual(try store.depth(of: a[1].id), 2)
        XCTAssertEqual(try store.listTasks().first { $0.id == ignored.id }?.parentId, nil)
        XCTAssertEqual(try store.listTasks().count, 8)
    }

    func testTwoLevelDatabaseReopensWithoutSchemaOrDataChangesAndDeepTagContextSurvives() throws {
        let store = try store()
        let old = try chain(store, count: 2)
        let before = try store.snapshot()
        let reopened = try TaskStore(databasePath: store.databasePath())
        XCTAssertEqual(try reopened.snapshot(), before)
        XCTAssertEqual(try reopened.database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, 5)
        let deep = try chain(reopened, count: 2, parent: old[1])
        _ = try reopened.patchTask(id: deep[1].id, title: "deep #tag")
        XCTAssertEqual(Set(try reopened.filterByTag("tag").map(\.id)), Set((old + deep).map(\.id)))
    }
}
