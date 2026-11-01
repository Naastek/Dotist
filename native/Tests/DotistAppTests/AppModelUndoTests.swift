import DotistCore
import Foundation
import XCTest
@testable import DotistApp

@MainActor
final class AppModelUndoTests: XCTestCase {
    private func fixture() throws -> (TaskStore, AppModel) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-undo-model-\(UUID().uuidString)")
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return (store, try AppModel(store: store))
    }

    private func waitForIdle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
    }

    private func change(_ model: AppModel, _ operation: @escaping (TaskStore) throws -> Void) async throws {
        model.change(operation)
        try await waitForIdle(model)
    }

    func testEveryEntryPointRecordsOneActionAndUndoRedoPublishesSnapshot() async throws {
        let (store, model) = try fixture()
        try await change(model) { _ = try $0.addTask(title: "first", category: "work") }
        let first = try XCTUnwrap(model.tasks.first)
        XCTAssertTrue(model.canUndoAction)
        XCTAssertFalse(model.canRedoAction)
        model.undoLast()
        XCTAssertFalse(model.canUndoAction)
        try await waitForIdle(model)
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertEqual(try store.listTasks().count, 0)
        XCTAssertTrue(model.canRedoAction)
        model.redoLast()
        try await waitForIdle(model)
        XCTAssertEqual(model.tasks.map(\.id), [first.id])
        model.complete(try XCTUnwrap(model.tasks.first))
        try await waitForIdle(model)
        XCTAssertTrue(try XCTUnwrap(model.tasks.first).completed)
        model.undoLast()
        try await waitForIdle(model)
        XCTAssertFalse(try XCTUnwrap(model.tasks.first).completed)
        model.redoLast()
        try await waitForIdle(model)
        XCTAssertTrue(try XCTUnwrap(model.tasks.first).completed)
        XCTAssertEqual(model.tasks, try store.listTasks())
    }

    func testNewChangeClearsRedoButNoOpAndFailurePreserveIt() async throws {
        let (_, model) = try fixture()
        try await change(model) { _ = try $0.addTask(title: "original", category: "work") }
        let id = try XCTUnwrap(model.tasks.first?.id)
        try await change(model) { _ = try $0.patchTask(id: id, title: "changed") }
        model.undoLast()
        try await waitForIdle(model)
        XCTAssertTrue(model.canRedoAction)
        try await change(model) { _ = try $0.patchTask(id: id, title: "original") }
        XCTAssertTrue(model.canRedoAction)
        let result: Bool = await withCheckedContinuation { continuation in
            model.change(completed: { continuation.resume(returning: true) }, failed: { continuation.resume(returning: false) }) {
                _ = try $0.patchTask(id: id, title: "")
            }
        }
        XCTAssertFalse(result)
        XCTAssertTrue(model.canRedoAction)
        try await change(model) { _ = try $0.setDueDate(id, date: "2026-11-12") }
        XCTAssertFalse(model.canRedoAction)
        XCTAssertTrue(model.redoHistory.isEmpty)
    }

    func testHistoryLimitKeepsLatestHundredActions() async throws {
        let (_, model) = try fixture()
        try await change(model) { _ = try $0.addTask(title: "0", category: "work") }
        let id = try XCTUnwrap(model.tasks.first?.id)
        for index in 1...104 {
            try await change(model) { _ = try $0.patchTask(id: id, title: String(index)) }
        }
        XCTAssertEqual(model.undoHistory.count, 100)
        for _ in 0..<100 { model.undoLast(); try await waitForIdle(model) }
        XCTAssertFalse(model.canUndoAction)
        XCTAssertEqual(model.tasks.first?.title, "4")
        XCTAssertEqual(model.tasks.count, 1)
        XCTAssertEqual(model.redoHistory.count, 100)
        for _ in 0..<100 { model.redoLast(); try await waitForIdle(model) }
        XCTAssertEqual(model.tasks.first?.title, "104")
        XCTAssertEqual(model.tasks.count, 1)
        XCTAssertFalse(model.canRedoAction)
    }

    func testDragFreezesSnapshotAndDisablesUndoRedoUntilEnd() async throws {
        let (store, model) = try fixture()
        try await change(model) {
            _ = try $0.addTask(title: "parent", category: "work")
            _ = try $0.addTask(title: "source", category: "life")
        }
        let source = try XCTUnwrap(model.tasks.first { $0.title == "source" })
        model.beginDrag(source.id, scope: "list:all")
        XCTAssertFalse(model.canUndoAction)
        XCTAssertFalse(model.canRedoAction)
        model.undoLast()
        XCTAssertEqual(try store.listTasks().count, 2)
        let target = TaskReorderEngine.Target(groupID: "work", slot: 0, level: 0, parentID: nil, beforeID: nil)
        model.commitReorder(taskID: source.id, to: target)
        try await waitForIdle(model)
        XCTAssertEqual(model.tasks.first { $0.id == source.id }?.category, "life")
        XCTAssertFalse(model.canUndoAction)
        model.endDrag()
        XCTAssertEqual(model.tasks.first { $0.id == source.id }?.category, "work")
        XCTAssertTrue(model.canUndoAction)
        model.undoLast()
        try await waitForIdle(model)
        XCTAssertEqual(model.tasks.first { $0.id == source.id }?.category, "life")
        model.beginDrag(source.id, scope: "list:all")
        XCTAssertFalse(model.canRedoAction)
        model.redoLast()
        XCTAssertEqual(try store.listTasks().first { $0.id == source.id }?.category, "life")
        model.endDrag()
        model.redoLast()
        try await waitForIdle(model)
        XCTAssertEqual(model.tasks.first { $0.id == source.id }?.category, "work")
    }

    func testMultiIndentDeleteAndBannerRestoreUseSameHistory() async throws {
        let (_, model) = try fixture()
        try await change(model) {
            _ = try $0.addTasks([.init(title: "parent", category: "work"), .init(title: "first", category: "work"), .init(title: "second", category: "work")])
        }
        let parent = try XCTUnwrap(model.tasks.first { $0.title == "parent" })
        let selected = model.tasks.filter { $0.id != parent.id }.map(\.id)
        model.indent(ids: selected)
        try await waitForIdle(model)
        XCTAssertEqual(model.undoHistory.count, 2)
        XCTAssertTrue(model.tasks.filter { selected.contains($0.id) }.allSatisfy { $0.parentId == parent.id })
        model.undoLast()
        try await waitForIdle(model)
        XCTAssertTrue(model.tasks.allSatisfy { $0.parentId == nil })
        model.redoLast()
        try await waitForIdle(model)
        model.delete(parent)
        try await waitForIdle(model)
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertNotNil(model.undo)
        model.restore()
        try await waitForIdle(model)
        XCTAssertEqual(model.tasks.count, 3)
        XCTAssertNil(model.undo)
        XCTAssertTrue(model.canRedoAction)
        XCTAssertEqual(model.undoHistory.count, 2)
        model.redoLast()
        try await waitForIdle(model)
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertNil(model.undo)
        model.undoLast()
        try await waitForIdle(model)
        XCTAssertEqual(model.tasks.count, 3)
        XCTAssertNil(model.undo)
    }

    func testFailedHistoryApplyKeepsEntryAndRestoresAvailability() async throws {
        let (store, model) = try fixture()
        try await change(model) { _ = try $0.addTask(title: "parent", category: "work") }
        let parent = try XCTUnwrap(model.tasks.first)
        // An external writer has attached a child since the action. Undoing the
        // parent's creation would orphan it, so the transaction must fail.
        _ = try store.addTask(title: "external child", category: "work", parentId: parent.id)
        model.undoLast()
        let deadline = Date().addingTimeInterval(10)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(model.busy)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.undoHistory.count, 1)
        XCTAssertTrue(model.canUndoAction)
        XCTAssertFalse(model.canRedoAction)
        XCTAssertEqual(try store.listTasks().count, 2)
    }
}
