import DotistCore
import Foundation
import XCTest
@testable import DotistApp

@MainActor
final class TaskHierarchyModelTests: XCTestCase {
    private func store() throws -> TaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-model-depth-\(UUID().uuidString)")
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return store
    }

    private func mutate(_ operation: (@escaping () -> Void, @escaping () -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            operation({ continuation.resume(returning: true) }, { continuation.resume(returning: false) })
        }
    }

    func testModelQueriesBatchCallbacksAndSingleTaskWrappers() async throws {
        let store = try store()
        let root = try store.addTask(title: "root", category: "work")
        let first = try store.addTask(title: "first", category: "work")
        let child = try store.addTask(title: "child", category: "work", parentId: first.id)
        let last = try store.addTask(title: "last", category: "work")
        _ = try store.patchTask(id: child.id, completed: true)
        let model = try AppModel(store: store)
        XCTAssertEqual(model.progress(of: first).done, 1)
        XCTAssertEqual(model.progress(of: first).total, 1)
        let success = await mutate { model.indent(ids: [last.id, child.id, first.id], completed: $0, failed: $1) }
        XCTAssertTrue(success)
        XCTAssertEqual(model.children(of: root).map(\.id), [first.id, last.id])
        XCTAssertEqual(model.depth(of: child), 2)
        XCTAssertEqual(model.descendants(of: root).map(\.id), [first.id, child.id, last.id])
        XCTAssertEqual(model.subtreeHeight(of: root), 2)
        XCTAssertTrue(model.expanded.contains(root.id))
        let outdented = await mutate { model.outdent(first, completed: $0, failed: $1) }
        XCTAssertTrue(outdented)
        XCTAssertEqual(model.depth(of: first), 0)
        XCTAssertEqual(model.depth(of: child), 1)
        let indented = await mutate { model.indent(first, completed: $0, failed: $1) }
        XCTAssertTrue(indented)
        XCTAssertEqual(model.depth(of: child), 2)
        let before = try store.snapshot()
        let rejected = await mutate { model.indent(ids: [root.id], completed: $0, failed: $1) }
        XCTAssertFalse(rejected)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try store.snapshot(), before)
        XCTAssertFalse(model.busy)
    }

    func testDeepDragCommitPublishesWholeSubtreeAndDestinationAncestors() async throws {
        let store = try store()
        let root = try store.addTask(title: "root", category: "work")
        let parent = try store.addTask(title: "parent", category: "work", parentId: root.id)
        let source = try store.addTask(title: "source", category: "life")
        let child = try store.addTask(title: "child", category: "life", parentId: source.id)
        let grandchild = try store.addTask(title: "grandchild", category: "life", parentId: child.id)
        let model = try AppModel(store: store)
        model.beginDrag(source.id, scope: "list:all")
        let success = await mutate { completed, failed in
            model.commitReorder(taskID: source.id, to: .init(groupID: "work", slot: 2, level: 2, parentID: parent.id, beforeID: nil), completed: {
                model.endDrag()
                completed()
            }, failed: { model.endDrag(); failed() })
        }
        XCTAssertTrue(success)
        XCTAssertEqual(Set(model.tasks.map(\.id)), Set([root.id, parent.id, source.id, child.id, grandchild.id]))
        XCTAssertTrue(model.tasks.allSatisfy { $0.category == "work" })
        XCTAssertEqual(model.depth(of: grandchild), 4)
        XCTAssertTrue(model.expanded.isSuperset(of: [root.id, parent.id]))
        XCTAssertEqual(model.tasks, try store.listTasks())
    }
}
