import Combine
import Foundation
import XCTest
@testable import DotistApp
@testable import DotistCore

@MainActor
final class AppModelWriteDeduplicationTests: XCTestCase {
    private func makeModel(taskCount: Int = 150) throws -> (TaskStore, AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-write-dedup-\(UUID().uuidString)")
        let store = try TaskStore(databasePath: dir.appendingPathComponent("tasks.sqlite").path)
        let groups = [DotistGroup.inboxID, "work", "life", "study"]
        let batch = (0..<taskCount).map { idx in
            TaskStore.NewTask(title: "Task \(idx) #tag\(idx % 5)", category: groups[idx % groups.count])
        }
        _ = try store.addTasks(batch)
        let model = try AppModel(store: store)
        return (store, model, dir)
    }

    private func waitUntil(_ timeout: Duration = .seconds(3), condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { XCTFail("Timed out waiting for condition"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testMeasureWriteSettingsAndSnapshotBehavior() async throws {
        let (store, model, dir) = try makeModel(taskCount: 150)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Allow initial observation fetch to settle.
        try await Task.sleep(for: .milliseconds(150))

        var settingsPublishes = 0
        let cancellable = model.$settings.dropFirst().sink { _ in settingsPublishes += 1 }
        defer { cancellable.cancel() }

        let target = try XCTUnwrap(model.tasks.first)

        // 1. Single normal task mutation (complete)
        let snapBeforeComplete = store.snapshotFetchCount
        let t0 = ContinuousClock.now
        model.complete(target)
        try await waitUntil { !model.busy && model.tasks.first(where: { $0.id == target.id })?.completed == true }
        let completeMs = t0.duration(to: .now).asMilliseconds
        try await Task.sleep(for: .milliseconds(150))
        let completeSnapshots = store.snapshotFetchCount - snapBeforeComplete
        let settingsAfterComplete = settingsPublishes

        // 2. commitReorder
        let second = try XCTUnwrap(model.tasks.dropFirst().first { $0.category == target.category && $0.parentId == nil })
        let snapBeforeReorder = store.snapshotFetchCount
        let t1 = ContinuousClock.now
        var reorderDone = false
        model.commitReorder(taskID: second.id, to: .init(groupID: target.category, slot: 0, level: 0, parentID: nil, beforeID: target.id), completed: { reorderDone = true })
        try await waitUntil { reorderDone && !model.busy }
        let reorderMs = t1.duration(to: .now).asMilliseconds
        try await Task.sleep(for: .milliseconds(150))
        let reorderSnapshots = store.snapshotFetchCount - snapBeforeReorder

        // 3. Undo & Redo
        let snapBeforeUndo = store.snapshotFetchCount
        model.undoLast()
        try await waitUntil { !model.busy && model.canRedoAction }
        try await Task.sleep(for: .milliseconds(120))
        let undoSnapshots = store.snapshotFetchCount - snapBeforeUndo

        model.redoLast()
        try await waitUntil { !model.busy && !model.canRedoAction }
        try await Task.sleep(for: .milliseconds(120))

        // 4. External write (simulating MCP / direct TaskStore write)
        let snapBeforeExternal = store.snapshotFetchCount
        let external = try store.addTask(title: "External MCP task", category: "work")
        try await waitUntil { model.tasks.contains(where: { $0.id == external.id }) }
        try await Task.sleep(for: .milliseconds(120))
        let externalSnapshots = store.snapshotFetchCount - snapBeforeExternal

        // 5. 5 rapid consecutive mutations
        let rapidTargets = Array(model.tasks.prefix(5))
        let snapBeforeRapid = store.snapshotFetchCount
        let t2 = ContinuousClock.now
        for item in rapidTargets {
            model.complete(item)
        }
        try await waitUntil {
            !model.busy && rapidTargets.allSatisfy { orig in
                model.tasks.first(where: { $0.id == orig.id })?.completed == !orig.completed
            }
        }
        let rapidMs = t2.duration(to: .now).asMilliseconds
        try await Task.sleep(for: .milliseconds(150))
        let rapidSnapshots = store.snapshotFetchCount - snapBeforeRapid

        print("WRITE_BENCH settingsPublishesTotal=\(settingsPublishes) settingsAfterComplete=\(settingsAfterComplete) completeSnaps=\(completeSnapshots) completeMs=\(String(format: "%.2f", completeMs)) reorderSnaps=\(reorderSnapshots) reorderMs=\(String(format: "%.2f", reorderMs)) undoSnaps=\(undoSnapshots) externalSnaps=\(externalSnapshots) rapid5Snaps=\(rapidSnapshots) rapid5Ms=\(String(format: "%.2f", rapidMs))")

        // Verify Item 2 guarantees:
        // 1. Normal task mutations emit 0 redundant $settings publications.
        XCTAssertEqual(settingsAfterComplete, 0, "Normal task write must not publish unchanged settings")
        XCTAssertEqual(settingsPublishes, 0, "Task writes, reorder, undo/redo, and rapid mutations must not publish unchanged settings")
        // 2. Deduplicated snapshots: 1 per local write, 1 per external write, 5 for 5 rapid writes.
        XCTAssertEqual(completeSnapshots, 1, "Single normal task write should fetch only 1 snapshot")
        XCTAssertEqual(reorderSnapshots, 1, "commitReorder should fetch only 1 snapshot")
        XCTAssertEqual(undoSnapshots, 1, "undoLast should fetch only 1 snapshot")
        XCTAssertEqual(externalSnapshots, 1, "External TaskStore write must still trigger 1 observation snapshot")
        XCTAssertEqual(rapidSnapshots, 5, "5 rapid consecutive mutations should fetch 5 snapshots without duplicate observation fetches")

        // 3. A change() that actually modifies settings (e.g. moveTag) must still publish $settings.
        let orderedTags = model.orderedTagCounts.map(\.tag)
        if orderedTags.count >= 2 {
            model.moveTag(orderedTags[0], toIndex: 1)
            try await waitUntil { !model.busy && settingsPublishes == 1 }
            XCTAssertEqual(settingsPublishes, 1, "Settings-mutating change() must still publish $settings")
        }
    }
}

private extension Duration {
    var asMilliseconds: Double {
        Double(components.seconds) * 1000.0 + Double(components.attoseconds) / 1e15
    }
}
