import Foundation
import GRDB
import XCTest
@testable import DotistCore

final class GroupTagThemeTests: XCTestCase {
    private func store() throws -> TaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wG1-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
    }

    func testDeletingGroupMigratesFamilyAndUndoRestoresIt() throws {
        let store = try store()
        let parent = try store.addTask(title: "parent", category: "work", dueDate: "2026-11-10")
        let child = try store.addTask(title: "done child", category: "work", parentId: parent.id)
        _ = try store.patchTask(id: child.id, completed: true)
        let before = try store.snapshot()
        let patch = try store.captureChanges { try $0.deleteGroup("work") }
        let moved = try store.listTasks()
        XCTAssertEqual(moved.count, 2)
        XCTAssertTrue(moved.allSatisfy { $0.category == DotistGroup.inboxID && $0.deletedAt == nil })
        XCTAssertEqual(moved.first { $0.id == child.id }?.updatedAt, before.tasks.first { $0.id == child.id }?.updatedAt)
        XCTAssertEqual(moved.first { $0.id == child.id }?.parentId, parent.id)
        XCTAssertEqual(moved.first { $0.id == parent.id }?.dueDate, parent.dueDate)
        try store.apply(patch: patch.before)
        XCTAssertEqual(try store.listGroups(), before.groups)
        XCTAssertTrue(try store.listTasks().allSatisfy { $0.category == "work" })
        try store.apply(patch: patch.after)
        XCTAssertTrue(try store.listTasks().allSatisfy { $0.category == DotistGroup.inboxID })
        let row = try XCTUnwrap(store.database.read { try Row.fetchOne($0, sql: "SELECT kind,payload FROM sync_outbox WHERE task_id=? ORDER BY rowid DESC LIMIT 1", arguments: [parent.id]) })
        XCTAssertEqual(row["kind"] as String, "update")
        XCTAssertTrue((row["payload"] as String).contains("\"category\":\"inbox\""))
    }

    func testDeletingTagOnlyTitleRemovesTagWithoutDeletingTask() throws {
        let store = try store()
        let task = try store.addTask(title: "#项目", category: "work")
        let patch = try store.captureChanges { try $0.retag("项目", replacement: nil) }
        XCTAssertEqual(try store.listTasks().map(\.id), [task.id])
        XCTAssertEqual(try store.listTasks().first?.title, "项目")
        XCTAssertTrue(try store.describeTags().counts.isEmpty)
        try store.apply(patch: patch.before)
        XCTAssertEqual(try store.listTasks().first?.title, "#项目")
    }

    func testGroupOrderPersistsHandlesTiesAndExcludesInbox() throws {
        let store = try store()
        let inbox = try XCTUnwrap(store.listGroups().first { $0.id == DotistGroup.inboxID })
        try store.database.write { try $0.execute(sql: "UPDATE task_groups SET position=7 WHERE id<>'inbox'") }
        let before = try store.listGroups()
        let patch = try store.captureChanges { try $0.moveGroup("study", toIndex: 0) }
        XCTAssertEqual(try store.listGroups().filter { $0.id != DotistGroup.inboxID }.map(\.id), ["study", "life", "work"])
        XCTAssertEqual(try TaskStore(databasePath: store.databasePath()).listGroups(), try store.listGroups())
        try store.moveGroup(DotistGroup.inboxID, toIndex: 2)
        XCTAssertEqual(try store.listGroups().first { $0.id == DotistGroup.inboxID }, inbox)
        try store.apply(patch: patch.before)
        XCTAssertEqual(try store.listGroups(), before)
        try store.apply(patch: patch.after)
        try store.moveGroup("study", direction: 1)
        XCTAssertEqual(try store.listGroups().filter { $0.id != DotistGroup.inboxID }.map(\.id), ["life", "study", "work"])
    }

    func testTagOrderPersistsAndRetagMaintainsIt() throws {
        let store = try store()
        _ = try store.addTasks([.init(title: "one #a #b", category: "work"), .init(title: "two #a #c", category: "life")])
        try store.moveTag("c", toIndex: 0)
        XCTAssertEqual(try store.settings().tagOrder, ["c", "a", "b"])
        XCTAssertEqual(try TaskStore(databasePath: store.databasePath()).settings().tagOrder, ["c", "a", "b"])
        try store.retag("c", replacement: "b")
        XCTAssertEqual(try store.settings().tagOrder, ["b", "a"])
        try store.retag("a", replacement: nil)
        XCTAssertEqual(try store.settings().tagOrder, ["b"])
        _ = try store.addTask(title: "new #z")
        XCTAssertEqual(TaskTags.orderedCounts(try store.describeTags().counts, order: try store.settings().tagOrder).map(\.tag), ["b", "z"])
    }

    func testTagDeletionIsExactPreservesCompletedAndDeletedTasksAndIsUndoable() throws {
        let store = try store()
        let parent = try store.addTask(title: "first  #tag   last #tag #tagged")
        let child = try store.addTask(title: "child #tag", category: DotistGroup.inboxID, parentId: parent.id)
        _ = try store.patchTask(id: child.id, completed: true)
        let deleted = try store.addTask(title: "deleted #tag")
        try store.deleteTask(deleted.id)
        let before = try store.listTasks()
        let patch = try store.captureChanges { try $0.retag("tag", replacement: nil) }
        XCTAssertEqual(try store.listTasks().count, 2)
        XCTAssertEqual(try store.listTasks().first { $0.id == parent.id }?.title, "first last #tagged")
        XCTAssertEqual(try store.listTasks().first { $0.id == child.id }?.updatedAt, before.first { $0.id == child.id }?.updatedAt)
        XCTAssertEqual(try store.describeTags().counts.map(\.tag), ["tagged"])
        _ = try store.restoreTask(deleted.id)
        XCTAssertEqual(try store.listTasks().first { $0.id == deleted.id }?.title, "deleted")
        try store.apply(patch: patch.before)
        XCTAssertEqual(try store.listTasks().count, 2)
        XCTAssertEqual(try store.listTasks().first { $0.id == parent.id }?.title, parent.title)
    }

    func testDeletedTasksRemainDeletedButCanRestoreAfterGroupDeletion() throws {
        let store = try store()
        let task = try store.addTask(title: "deleted", category: "work")
        try store.deleteTask(task.id)
        try store.deleteGroup("work")
        XCTAssertTrue(try store.listTasks().isEmpty)
        XCTAssertEqual(try store.restoreTask(task.id).category, DotistGroup.inboxID)
        for id in ["life", "study"] { try store.deleteGroup(id) }
        XCTAssertEqual(try store.listGroups().map(\.id), [DotistGroup.inboxID])
        XCTAssertThrowsError(try store.deleteGroup(DotistGroup.inboxID))
    }

    func testColorsPersistAreUndoableAndUnknownValuesAreNeutral() throws {
        let store = try store()
        XCTAssertEqual(DotistGroupColor.allCases.map(\.rawValue), ["none", "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"])
        XCTAssertEqual(DotistGroupColor(rawValue: "work"), .none)
        XCTAssertEqual(try JSONDecoder().decode(DotistGroupColor.self, from: Data("\"future-color\"".utf8)), .none)
        let patch = try store.captureChanges { try $0.setGroupColor("work", .purple) }
        XCTAssertEqual(try TaskStore(databasePath: store.databasePath()).listGroups().first { $0.id == "work" }?.color, "purple")
        try store.apply(patch: patch.before)
        XCTAssertEqual(try store.listGroups().first { $0.id == "work" }?.color, "work")
        XCTAssertThrowsError(try store.setGroupColor(DotistGroup.inboxID, .red))
        XCTAssertEqual(try store.addGroup(name: "neutral").color, "none")
    }

    func testOldSettingsUseDefaultsWithoutRewritingFileOrSchema() throws {
        let store = try store()
        let path = try store.databasePath()
        let settingsURL = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("settings.json")
        let data = Data(#"{"language":"fr","group_colors":"dots"}"#.utf8)
        try data.write(to: settingsURL)
        let reopened = try TaskStore(databasePath: path)
        XCTAssertEqual(try reopened.settings().tagOrder, [])
        XCTAssertEqual(try reopened.settings().allColor, "none")
        XCTAssertEqual(try reopened.settings().groupColors, "dots")
        XCTAssertEqual(try Data(contentsOf: settingsURL), data)
        XCTAssertEqual(try reopened.database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, 5)
        var patch = DotistSettingsPatch(); patch.tagOrder = ["a", "a", "", "b"]; patch.allColor = "invalid"
        _ = try reopened.updateSettings(patch)
        XCTAssertEqual(try reopened.settings().tagOrder, ["a", "b"])
        XCTAssertEqual(try reopened.settings().allColor, "none")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        XCTAssertEqual(object["tag_order"] as? [String], ["a", "b"])
        XCTAssertEqual(object["all_color"] as? String, "none")
    }

    func testLegacyGroupDeletionStillRestoresItsDeletedFamily() throws {
        let store = try store()
        let parent = try store.addTask(title: "legacy parent", category: "work")
        let child = try store.addTask(title: "legacy child", category: "work", parentId: parent.id)
        try store.database.write {
            try $0.execute(sql: "UPDATE task_groups SET deleted_at='legacy-stamp' WHERE id='work'")
            try $0.execute(sql: "UPDATE tasks SET deleted_at='legacy-stamp' WHERE category='work'")
        }
        _ = try store.restoreGroup("work")
        XCTAssertEqual(Set(try store.listTasks().map(\.id)), Set([parent.id, child.id]))
        XCTAssertTrue(try store.listTasks().allSatisfy { $0.category == "work" })
    }

    func testFailedRetagPreservesTagOrderTasksAndOutbox() throws {
        let store = try store()
        _ = try store.addTasks([.init(title: "short #x"), .init(title: String(repeating: "a", count: 497) + " #x")])
        var patch = DotistSettingsPatch(); patch.tagOrder = ["x"]
        _ = try store.updateSettings(patch)
        let before = try store.snapshot()
        let outbox = try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }
        XCTAssertThrowsError(try store.retag("x", replacement: "too-long"))
        XCTAssertEqual(try store.snapshot(), before)
        XCTAssertEqual(try store.settings().tagOrder, ["x"])
        XCTAssertEqual(try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }, outbox)
    }

    func testGroupMigrationAppendsSafelyAtMaximumInboxPositionAndUndoRestoresOrder() throws {
        let store = try store()
        let existing = try store.addTask(title: "existing")
        let moved = try store.addTask(title: "moved", category: "work")
        try store.database.write { try $0.execute(sql: "UPDATE tasks SET position=? WHERE id=?", arguments: [Int64.max, existing.id]) }
        let patch = try store.captureChanges { try $0.deleteGroup("work") }
        XCTAssertEqual(try store.listTasks().sorted { $0.position < $1.position }.map(\.id), [existing.id, moved.id])
        try store.apply(patch: patch.before)
        XCTAssertEqual(try store.listTasks().first { $0.id == existing.id }?.position, Int64.max)
        XCTAssertEqual(try store.listTasks().first { $0.id == moved.id }?.category, "work")
    }
}
