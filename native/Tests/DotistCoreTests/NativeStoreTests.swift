import Foundation
import GRDB
import XCTest
@testable import DotistCore

final class NativeStoreTests: XCTestCase {
    private func store() throws -> TaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-native-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
    }

    func testInboxIsAddedWithoutMergingNamesOrRewritingExistingRecords() throws {
        let store = try store()
        try store.database.write { try $0.execute(sql: "DELETE FROM task_groups WHERE id='inbox'") }
        let namedInbox = try store.addGroup(name: "Inbox")
        let parent = try store.addTask(title: "原有任务", category: namedInbox.id, dueDate: "2026-11-10")
        _ = try store.addTask(title: "原有子任务", category: namedInbox.id, parentId: parent.id)
        _ = try store.patchTask(id: parent.id, status: .doing)
        let existing = try store.database.read { db in
            try ["tasks", "task_groups", "sync_outbox"].map { try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY 1").map(\.description) }
        }
        let path = try store.databasePath()
        var patch = DotistSettingsPatch(); patch.language = "ja"
        _ = try store.updateSettings(patch)
        let settingsURL = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("settings.json")
        let settings = try Data(contentsOf: settingsURL)
        let reopened = try TaskStore(databasePath: path)
        XCTAssertEqual(try reopened.listGroups().first?.id, DotistGroup.inboxID)
        XCTAssertEqual(try reopened.listGroups().filter { $0.name == "Inbox" }.count, 2)
        XCTAssertEqual(try reopened.listTasks().first { $0.id == parent.id }?.category, namedInbox.id)
        let preserved = try reopened.database.read { db in
            try ["tasks", "task_groups", "sync_outbox"].map { table in
                try Row.fetchAll(db, sql: "SELECT * FROM \(table)" + (table == "task_groups" ? " WHERE id<>'inbox'" : "") + " ORDER BY 1").map(\.description)
            }
        }
        XCTAssertEqual(preserved, existing)
        XCTAssertEqual(try Data(contentsOf: settingsURL), settings)
        XCTAssertEqual(try TaskStore(databasePath: path).listGroups(), try reopened.listGroups())
    }

    func testInboxClassificationMovesTheFamilyAndKeepsDatesAndHistory() throws {
        let store = try store()
        let parent = try store.addTask(title: "待整理", category: DotistGroup.inboxID, dueDate: "2026-11-10")
        let child = try store.addTask(title: "子任务", category: DotistGroup.inboxID, parentId: parent.id)
        _ = try store.patchTask(id: child.id, completed: true)
        let moved = try store.patchTask(id: parent.id, category: "work")
        let movedChild = try XCTUnwrap(store.listTasks().first { $0.id == child.id })
        XCTAssertEqual(moved.id, parent.id)
        XCTAssertEqual(moved.dueDate, parent.dueDate)
        XCTAssertEqual(movedChild.category, "work")
        XCTAssertEqual(movedChild.parentId, parent.id)
        XCTAssertTrue(movedChild.completed)
        XCTAssertGreaterThan(moved.revision, parent.revision)
        XCTAssertThrowsError(try store.deleteGroup(DotistGroup.inboxID))
        XCTAssertThrowsError(try store.updateGroup(DotistGroup.inboxID, name: "其他"))
        try store.moveGroup("work", direction: -1)
        XCTAssertEqual(try store.listGroups().first?.id, DotistGroup.inboxID)
        _ = try store.patchTask(id: parent.id, category: DotistGroup.inboxID)
        XCTAssertEqual(try store.listTasks().first { $0.id == child.id }?.category, DotistGroup.inboxID)
    }

    func testCurrentBaselineReopensWithoutChangingExistingRecordsOrPreferences() throws {
        let store = try store()
        let parent = try store.addTask(title: "已有任务 #项目", category: "work", dueDate: "2026-11-10")
        let child = try store.addTask(title: "已有子项", category: "work", parentId: parent.id)
        _ = try store.patchTask(id: parent.id, status: .doing)
        try store.deleteTask(child.id)
        try store.database.write {
            try $0.execute(sql: "UPDATE tasks SET remote_revision='preserved-remote' WHERE id=?", arguments: [parent.id])
        }
        var patch = DotistSettingsPatch(); patch.language = "ja"; patch.mcpEnabled = true
        _ = try store.updateSettings(patch)
        let path = try store.databasePath()
        let settingsURL = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("settings.json")
        let settings = try Data(contentsOf: settingsURL)
        let before = try store.database.read { db in
            try ["tasks", "task_groups", "sync_outbox"].map { try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY 1").map(\.description) }
        }
        let reopened = try TaskStore(databasePath: path)
        XCTAssertEqual(try reopened.database.read { db in
            try ["tasks", "task_groups", "sync_outbox"].map { try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY 1").map(\.description) }
        }, before)
        XCTAssertEqual(try Data(contentsOf: settingsURL), settings)
        XCTAssertEqual(try reopened.listTasks().first?.id, parent.id)
        XCTAssertEqual(try reopened.listTasks().first?.status, .doing)
        XCTAssertEqual(try reopened.database.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }, "ok")
    }

    func testAtomicBatchRejectsInvalidDateAndPreservesUnicodeLimit() throws {
        let store = try store()
        XCTAssertThrowsError(try store.addTasks([
            .init(title: "有效", category: "work"),
            .init(title: "无效", category: "work", dueDate: "2026-02-30"),
        ]))
        XCTAssertTrue(try store.listTasks().isEmpty)
        XCTAssertEqual(try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }, 0)
        XCTAssertThrowsError(try store.addTask(title: "日期", category: "work", dueDate: "2026-1-01"))
        XCTAssertThrowsError(try store.addTask(title: String(repeating: "e\u{301}", count: 251), category: "work"))
        XCTAssertEqual(try store.addTasks([.init(title: "第一项", category: "工作"), .init(title: "第二项", category: "life")]).count, 2)
    }

    func testStateAndFamilyRulesSurvivePartialUpdates() throws {
        let store = try store()
        let parent = try store.addTask(title: "父任务", category: "work")
        let child = try store.addTask(title: "子任务", category: "work", parentId: parent.id)
        _ = try store.patchTask(id: child.id, completed: true)
        XCTAssertFalse(try XCTUnwrap(store.listTasks().first { $0.id == parent.id }).completed)
        _ = try store.patchTask(id: parent.id, status: .doing)
        _ = try store.patchTask(id: parent.id, title: "修改内容")
        XCTAssertEqual(try XCTUnwrap(store.listTasks().first { $0.id == parent.id }).status, .doing)
        XCTAssertThrowsError(try store.patchTask(id: parent.id, completed: false, status: .done))
        _ = try store.patchTask(id: parent.id, completed: true)
        _ = try store.patchTask(id: parent.id, completed: false)
        XCTAssertTrue(try XCTUnwrap(store.listTasks().first { $0.id == child.id }).completed)
        _ = try store.patchTask(id: parent.id, category: "life")
        XCTAssertEqual(try XCTUnwrap(store.listTasks().first { $0.id == child.id }).category, "life")
        XCTAssertThrowsError(try store.patchTask(id: child.id, category: "study"))
        XCTAssertThrowsError(try store.reparent(parent.id, parentId: child.id))
        let grandchild = try store.addTask(title: "第三级", category: "work", parentId: child.id)
        XCTAssertEqual(grandchild.category, "life")
        XCTAssertEqual(try store.depth(of: grandchild.id), 2)
    }

    func testRestoreOnlyRestoresTheSameDeletionBatch() throws {
        let store = try store()
        let parent = try store.addTask(title: "父任务", category: "work")
        let oldDeleted = try store.addTask(title: "之前单独删除", category: "work", parentId: parent.id)
        let child = try store.addTask(title: "随父项删除", category: "work", parentId: parent.id)
        try store.deleteTask(oldDeleted.id)
        try store.deleteTask(parent.id)
        _ = try store.restoreTask(parent.id)
        XCTAssertEqual(Set(try store.listTasks().map(\.id)), Set([parent.id, child.id]))
        try store.deleteGroup("work")
        _ = try store.restoreGroup("work")
        XCTAssertEqual(Set(try store.listTasks().map(\.id)), Set([parent.id, child.id]))
    }

    func testRestoreRequiresTheOriginalGroupIdentity() throws {
        let store = try store()
        let task = try store.addTask(title: "原分组任务", category: "work")
        try store.deleteGroup("work")
        _ = try store.addGroup(name: "work")
        XCTAssertThrowsError(try store.restoreTask(task.id))
        XCTAssertTrue(try store.listTasks().isEmpty)
    }

    func testReorderPreservesFamilyDatesAndCompletedTimestampWithTiedPositions() throws {
        let store = try store()
        let a = try store.addTask(title: "A", category: "work", dueDate: "2026-11-10")
        let b = try store.addTask(title: "B", category: "life")
        let c = try store.addTask(title: "C", category: "study")
        let done = try store.patchTask(id: b.id, completed: true)
        try store.database.write { try $0.execute(sql: "UPDATE tasks SET position=0") }
        try store.reorder(a.id, relativeTo: c.id, after: true, allTasks: true)
        let ordered = try store.listTasks().sorted { $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position }
        XCTAssertEqual(ordered.firstIndex { $0.id == a.id }, try XCTUnwrap(ordered.firstIndex { $0.id == c.id }) + 1)
        XCTAssertEqual(ordered.first { $0.id == a.id }?.category, "work")
        XCTAssertEqual(ordered.first { $0.id == a.id }?.dueDate, "2026-11-10")
        XCTAssertEqual(ordered.first { $0.id == b.id }?.updatedAt, done.updatedAt)
        XCTAssertThrowsError(try store.reorder(a.id, relativeTo: b.id, after: true, allTasks: false))
        XCTAssertThrowsError(try store.setDateRange(a.id, start: "2026-11-11", due: "2026-11-10"))
    }

    @MainActor func testObservationPublishesAtomicChangesWithoutPolling() async throws {
        let store = try store()
        let changed = expectation(description: "Database observation delivered the whole batch")
        var partial = false
        let observation = store.observe(onError: { XCTFail($0.localizedDescription) }, onChange: { snapshot in
            if snapshot.tasks.count == 1 { partial = true }
            if snapshot.tasks.count == 2 { changed.fulfill() }
        })
        _ = try store.addTasks([.init(title: "A", category: "work"), .init(title: "B", category: "work")])
        await fulfillment(of: [changed], timeout: 2)
        observation.cancel()
        XCTAssertFalse(partial)
    }

    func testThousandTaskBatchAndSnapshotPerformance() throws {
        let store = try store()
        let start = ContinuousClock.now
        _ = try store.addTasks((0..<1000).map { .init(title: "任务 \($0) #规模验证", category: $0.isMultiple(of: 2) ? "work" : "life") })
        let creation = start.duration(to: .now)
        let read = ContinuousClock.now
        for _ in 0..<10 {
            let snapshot = try store.snapshot()
            XCTAssertEqual(snapshot.tasks.count, 1000)
            XCTAssertEqual(snapshot.tags.counts.first?.open, 1000)
        }
        print("DOTIST_PERFORMANCE 1000-task atomic batch=\(creation); 10 full snapshots including tags=\(read.duration(to: .now))")
    }
}
