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

    func testGroupedEditsCoalesceWithinGroupDelayAndSplitAfterSealOrTimeout() async throws {
        let (_, model) = try fixture()
        var now: TimeInterval = 100.0
        model.historyGroupDelay = 0.8
        model.historyClock = { now }

        try await change(model) { _ = try $0.addTask(title: "Draft", category: "work") }
        let id = try XCTUnwrap(model.tasks.first?.id)
        XCTAssertEqual(model.undoEntries.count, 1)

        // Two rapid title edits on the same task coalesce into one entry.
        model.patchTaskTitleOptimistically(id: id, title: "Draft 1")
        try await waitForIdle(model)
        now += 0.3
        model.patchTaskTitleOptimistically(id: id, title: "Draft 12")
        try await waitForIdle(model)
        XCTAssertEqual(model.undoEntries.count, 2)
        XCTAssertEqual(model.tasks.first?.title, "Draft 12")

        // Sealing splits the next edit even within groupDelay.
        model.sealUndoHistory()
        now += 0.1
        model.patchTaskTitleOptimistically(id: id, title: "Draft 123")
        try await waitForIdle(model)
        XCTAssertEqual(model.undoEntries.count, 3)

        // Advancing past groupDelay also starts a new undo entry.
        now += 1.5
        model.patchTaskTitleOptimistically(id: id, title: "Draft 1234")
        try await waitForIdle(model)
        XCTAssertEqual(model.undoEntries.count, 4)

        // Undoing steps back cleanly through each sealed boundary.
        model.undoLast(); try await waitForIdle(model)
        XCTAssertEqual(model.tasks.first?.title, "Draft 123")
        model.undoLast(); try await waitForIdle(model)
        XCTAssertEqual(model.tasks.first?.title, "Draft 12")
        model.undoLast(); try await waitForIdle(model)
        XCTAssertEqual(model.tasks.first?.title, "Draft")
        model.redoLast(); try await waitForIdle(model)
        XCTAssertEqual(model.tasks.first?.title, "Draft 12")
    }

    func testBackgroundSettingsAndNonHistoryUpdatesPreserveUndoRedoStack() async throws {
        let (_, model) = try fixture()
        try await change(model) { _ = try $0.addTask(title: "Keep #a #b", category: "work") }
        let id = try XCTUnwrap(model.tasks.first?.id)
        try await change(model) { _ = try $0.patchTask(id: id, title: "Edited #a #b") }
        model.undoLast()
        try await waitForIdle(model)
        XCTAssertEqual(model.undoEntries.count, 1)
        XCTAssertEqual(model.redoEntries.count, 1)

        // Non-history tag reorder and settings update must not disturb undo/redo stacks.
        model.moveTag("b", toIndex: 0)
        try await waitForIdle(model)
        let settingsSaved: Bool = await withCheckedContinuation { continuation in
            var patch = DotistSettingsPatch()
            patch.autoCollapse = !model.settings.autoCollapse
            model.updateSettings(patch) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(settingsSaved)
        XCTAssertEqual(model.undoEntries.count, 1)
        XCTAssertEqual(model.redoEntries.count, 1)
        XCTAssertTrue(model.canUndoAction)
        XCTAssertTrue(model.canRedoAction)
    }

    func testMCPAgentMutationsRecordAgentSourceAndUndoSourcePreservesUserEdits() async throws {
        let (store, model) = try fixture()
        let tools = DotistMCPTools(store: store, focus: { _ in }, onMutation: { [weak model] patch, name in
            model?.recordAgentHistory(patch, label: name)
        })

        // 1. User creates Task A.
        try await change(model) { _ = try $0.addTask(title: "User Task A", category: "work") }
        let taskA = try XCTUnwrap(model.tasks.first)
        XCTAssertFalse(model.canUndoAgentAction)

        // 2. Agent adds Task B & Task C in one batch, then sets due date on Task A.
        let added = await tools.call("add_tasks", [
            "category": "work",
            "tasks": [["title": "AI Task B"], ["title": "AI Task C"]]
        ])
        XCTAssertNotEqual(added.isError, true)
        let dated = await tools.call("set_due_date", ["id": .string(taskA.id), "due_date": "2026-12-05"])
        XCTAssertNotEqual(dated.isError, true)
        model.refresh()
        for _ in 0..<50 where model.tasks.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.canUndoAgentAction)
        XCTAssertEqual(model.undoEntries.filter { $0.source == .agent }.count, 2)

        // 3. User edits Task A's title and Task B's title after the agent changes.
        let taskB = try XCTUnwrap(model.tasks.first { $0.title == "AI Task B" })
        let taskC = try XCTUnwrap(model.tasks.first { $0.title == "AI Task C" })
        try await change(model) { _ = try $0.patchTask(id: taskA.id, title: "User Task A Updated") }
        try await change(model) { _ = try $0.patchTask(id: taskB.id, title: "User Kept B") }

        // 4. Undo latest agent action (set_due_date on A): reverts due date while keeping A's user title.
        model.undoLastAgentAction()
        try await waitForIdle(model)
        XCTAssertEqual(model.tasks.first { $0.id == taskA.id }?.title, "User Task A Updated")
        XCTAssertNil(model.tasks.first { $0.id == taskA.id }?.dueDate)
        XCTAssertTrue(model.canUndoAgentAction)

        // 5. Undo earlier agent batch (add_tasks B & C): deletes untouched C, preserves user-edited B.
        model.undoLastAgentAction()
        try await waitForIdle(model)
        XCTAssertNil(model.tasks.first { $0.id == taskC.id })
        XCTAssertEqual(model.tasks.first { $0.id == taskB.id }?.title, "User Kept B")
        XCTAssertEqual(model.tasks.first { $0.id == taskA.id }?.title, "User Task A Updated")
        XCTAssertFalse(model.canUndoAgentAction)
        // User's own history entries remain available on the undo stack.
        XCTAssertTrue(model.canUndoAction)
    }

    func testOrdinaryUndoAndRedoAfterSelectiveAgentWithdrawalDoesNotRestoreWithdrawnField() async throws {
        let (store, model) = try fixture()
        let tools = DotistMCPTools(store: store, focus: { _ in }, onMutation: { [weak model] patch, name in
            model?.recordAgentHistory(patch, label: name)
        })

        try await change(model) { _ = try $0.addTask(title: "Original", category: "work") }
        let id = try XCTUnwrap(model.tasks.first?.id)

        // MCP sets due date on the task.
        let dated = await tools.call("set_due_date", ["id": .string(id), "due_date": "2026-12-05"])
        XCTAssertNotEqual(dated.isError, true)
        model.refresh()
        for _ in 0..<50 where model.tasks.first?.dueDate == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.tasks.first?.dueDate, "2026-12-05")

        // User renames the task.
        try await change(model) { _ = try $0.patchTask(id: id, title: "Renamed") }
        XCTAssertEqual(model.tasks.first?.title, "Renamed")
        XCTAssertEqual(model.tasks.first?.dueDate, "2026-12-05")

        // User withdraws the MCP due-date change.
        model.undoLastAgentAction()
        try await waitForIdle(model)
        XCTAssertEqual(model.tasks.first?.title, "Renamed")
        XCTAssertNil(model.tasks.first?.dueDate)

        // Pressing ⌘Z to undo the rename must NOT restore the withdrawn due date.
        model.undoLast()
        try await waitForIdle(model)
        XCTAssertEqual(model.tasks.first?.title, "Original")
        XCTAssertNil(model.tasks.first?.dueDate)

        // Pressing ⇧⌘Z to redo the rename must keep due date cleared as well.
        model.redoLast()
        try await waitForIdle(model)
        XCTAssertEqual(model.tasks.first?.title, "Renamed")
        XCTAssertNil(model.tasks.first?.dueDate)
    }

    func testMCPWriteInterleavedWithInFlightRedoDoesNotCrashOrCorruptHistory() async throws {
        let (store, model) = try fixture()
        try await change(model) { _ = try $0.addTask(title: "First", category: "work") }
        let id = try XCTUnwrap(model.tasks.first?.id)
        try await change(model) { _ = try $0.patchTask(id: id, title: "Second") }
        model.undoLast()
        try await waitForIdle(model)
        XCTAssertEqual(model.tasks.first?.title, "First")
        XCTAssertEqual(model.redoEntries.count, 1)

        // Start an in-flight redo, then interleave an MCP agent write before redo completes.
        model.redoLast()
        XCTAssertTrue(model.historyActionInFlight)
        let agentPatch = try store.captureChanges { _ = try $0.addTask(title: "From MCP", category: "work") }
        model.recordAgentHistory(agentPatch, label: "add_tasks")

        try await waitForIdle(model)
        XCTAssertFalse(model.historyActionInFlight)
        XCTAssertEqual(model.tasks.first { $0.id == id }?.title, "Second")
        XCTAssertTrue(model.tasks.contains { $0.title == "From MCP" })
        XCTAssertTrue(model.canUndoAgentAction)
        XCTAssertEqual(model.undoEntries.last?.source, .agent)
        XCTAssertTrue(model.redoEntries.isEmpty)
    }
}
