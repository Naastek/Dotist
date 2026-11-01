import DotistCore
import Foundation
import MCP
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class GroupTagThemeModelTests: XCTestCase {
    private func store() throws -> TaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wG1-model-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
    }

    private func idle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
    }

    func testImplicitBucketAndThemeFallbacks() async throws {
        let store = try store()
        let root = try store.addTask(title: "ungrouped")
        _ = try store.addTask(title: "child", category: DotistGroup.inboxID, parentId: root.id)
        _ = try store.addTask(title: "grouped", category: "work")
        var patch = DotistSettingsPatch(); patch.allColor = "blue"; patch.language = "zh-CN"
        _ = try store.updateSettings(patch)
        let model = try AppModel(store: store)
        XCTAssertEqual(model.visibleGroups.map(\.id), ["work", "life", "study"])
        XCTAssertEqual(model.ungroupedTasks.map(\.id), [root.id])
        XCTAssertNil(model.group(for: root))
        XCTAssertEqual(model.groupDisplayName(nil), "无分组")
        XCTAssertEqual(model.groupDisplayName(DotistGroup.inboxID), "无分组")
        XCTAssertEqual(model.groupDisplayName("work"), "工作")
        XCTAssertEqual(model.nextTask?.id, root.id)
        XCTAssertEqual(model.themeColor(forGroup: nil), .blue)
        XCTAssertEqual(model.themeColor(forGroup: "work"), .blue)
        XCTAssertEqual(model.themeColor(forGroup: DotistGroup.inboxID), .blue)
        model.setGroupColor("work", .pink)
        try await idle(model)
        XCTAssertEqual(model.themeColor(forGroup: "work"), .pink)
        model.undoLast()
        try await idle(model)
        XCTAssertEqual(model.themeColor(forGroup: "work"), .blue)
        model.setGroupColor("work", .none)
        try await idle(model)
        XCTAssertEqual(model.themeColor(forGroup: "work"), .blue)
        XCTAssertEqual(DotistTheme.tint(.none, .light), .clear)
        XCTAssertEqual(DotistTheme.tint(.none, .dark), .clear)
        XCTAssertEqual(DotistTheme.swatch(.none), .clear)
        XCTAssertNotEqual(DotistTheme.tint(.blue, .light), DotistTheme.tint(.blue, .dark))
    }

    func testGroupDeletionBannerAndKeyboardUndoShareTheMigration() async throws {
        let store = try store()
        let parent = try store.addTask(title: "parent", category: "work")
        _ = try store.addTask(title: "child", category: "work", parentId: parent.id)
        let model = try AppModel(store: store)
        model.deleteGroup(try XCTUnwrap(model.visibleGroups.first { $0.id == "work" }))
        try await idle(model)
        XCTAssertEqual(model.tasks.count, 2)
        XCTAssertTrue(model.tasks.allSatisfy { $0.category == DotistGroup.inboxID })
        XCTAssertEqual(model.undo?.title, "工作")
        XCTAssertEqual(model.undo?.group, true)
        model.restore()
        try await idle(model)
        XCTAssertTrue(model.tasks.allSatisfy { $0.category == "work" })
        XCTAssertNil(model.undo)
        XCTAssertTrue(model.canRedoAction)
        model.redoLast()
        try await idle(model)
        XCTAssertTrue(model.tasks.allSatisfy { $0.category == DotistGroup.inboxID })
        model.undoLast()
        try await idle(model)
        XCTAssertTrue(model.tasks.allSatisfy { $0.category == "work" })
    }

    func testGroupBannerRestoresMigrationAfterInterveningAction() async throws {
        let store = try store()
        let task = try store.addTask(title: "parent", category: "work")
        let unrelated = try store.addTask(title: "unrelated", category: "life")
        let model = try AppModel(store: store)
        model.deleteGroup(try XCTUnwrap(model.visibleGroups.first { $0.id == "work" }))
        try await idle(model)
        model.complete(unrelated)
        try await idle(model)
        model.restore()
        try await idle(model)
        XCTAssertEqual(model.tasks.first { $0.id == task.id }?.category, "work")
        XCTAssertEqual(model.tasks.first { $0.id == unrelated.id }?.completed, true)
        model.undoLast()
        try await idle(model)
        XCTAssertEqual(model.tasks.count, 2)
        XCTAssertEqual(model.tasks.first { $0.id == task.id }?.category, DotistGroup.inboxID)
        XCTAssertFalse(model.visibleGroups.contains { $0.id == "work" })
        model.redoLast()
        try await idle(model)
        XCTAssertEqual(model.tasks.first { $0.id == task.id }?.category, "work")
        XCTAssertEqual(model.tasks.first { $0.id == unrelated.id }?.completed, true)
    }

    func testOrderingAndTagMutationsPublishAndUndo() async throws {
        let store = try store()
        _ = try store.addTasks([.init(title: "one #a #b"), .init(title: "two #a #c")])
        let model = try AppModel(store: store)
        model.moveGroup("study", toIndex: 0)
        try await idle(model)
        XCTAssertEqual(model.visibleGroups.map(\.id), ["study", "work", "life"])
        model.undoLast()
        try await idle(model)
        XCTAssertEqual(model.visibleGroups.map(\.id), ["work", "life", "study"])
        let historyCount = model.undoHistory.count
        model.moveTag("c", toIndex: 0)
        try await idle(model)
        XCTAssertEqual(model.orderedTagCounts.map(\.tag), ["c", "a", "b"])
        XCTAssertEqual(model.undoHistory.count, historyCount)
        model.selectTag("c")
        model.renameTag("c", to: " ")
        XCTAssertEqual(model.activeTag, "c")
        model.renameTag("c", to: "renamed")
        try await idle(model)
        XCTAssertEqual(model.activeTag, "renamed")
        XCTAssertEqual(model.settings.tagOrder, ["renamed", "a", "b"])
        model.deleteTag("a")
        try await idle(model)
        XCTAssertEqual(model.tasks.count, 2)
        XCTAssertFalse(model.tagCounts.contains { $0.tag == "a" })
        XCTAssertEqual(model.settings.tagOrder, ["renamed", "b"])
        model.undoLast()
        try await idle(model)
        XCTAssertEqual(model.tagCounts.first { $0.tag == "a" }?.all, 2)
        XCTAssertEqual(model.tasks.count, 2)
    }

    func testMCPGroupDeleteKeepsTasksAndInboxRemainsAddressable() async throws {
        let store = try store()
        let parent = try store.addTask(title: "parent", category: "work")
        _ = try store.addTask(title: "child", category: "work", parentId: parent.id)
        let tools = DotistMCPTools(store: store, focus: { _ in })
        let result = await tools.call("delete_group", ["id": "work"])
        XCTAssertNotEqual(result.isError, true)
        XCTAssertEqual(try store.listTasks().count, 2)
        XCTAssertTrue(try store.listTasks().allSatisfy { $0.category == DotistGroup.inboxID })
        let listed = await tools.call("list_tasks", ["category": "inbox"])
        XCTAssertNotEqual(listed.isError, true)
        let create = await tools.call("add_tasks", ["category": "inbox", "tasks": [["title": "new"]]])
        XCTAssertNotEqual(create.isError, true)
        XCTAssertEqual(try store.listTasks().count, 3)
        let forbidden = await tools.call("delete_group", ["id": "inbox"])
        XCTAssertEqual(forbidden.isError, true)
    }
}
