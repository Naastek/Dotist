import AppKit
import DotistCore
import XCTest
@testable import DotistApp

/// Covers the gesture -> engine -> atomic commit boundary without a window or screen.
@MainActor
final class TaskDragDropTests: XCTestCase {
    private func store() throws -> TaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-reorder-\(UUID().uuidString)")
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return store
    }

    private func commit(_ taskID: String, to target: TaskReorderEngine.Target, model: AppModel) async {
        await withCheckedContinuation { continuation in
            model.commitReorder(taskID: taskID, to: target, completed: {
                model.endDrag()
                continuation.resume()
            }, failed: {
                model.endDrag()
                XCTFail(model.error ?? "Reorder failed")
                continuation.resume()
            })
        }
    }

    func testReleaseOverTaskPreservesCountAndVisibleRootIdentity() async throws {
        let store = try store()
        let source = try store.addTask(title: "source", category: DotistGroup.inboxID)
        let destination = try store.addTask(title: "destination", category: DotistGroup.inboxID)
        let model = try AppModel(store: store)
        let rows: [TaskReorderEngine.Row] = [
            .init(id: source.id, level: 0, groupID: source.category, parentID: nil, midY: 16),
            .init(id: destination.id, level: 0, groupID: destination.category, parentID: nil, midY: 48)
        ]
        model.beginDrag(source.id, scope: "list:all")
        let target = try XCTUnwrap(TaskReorderEngine.target(rows: rows, groups: [.init(id: source.category, minY: 0, maxY: 80)], draggedID: source.id, blockIDs: [source.id], startY: 16, offsetY: 40, offsetX: 0, indentStep: 26))
        XCTAssertNil(target.parentID)
        await commit(source.id, to: target, model: model)
        XCTAssertEqual(Set(model.tasks.map(\.id)), [source.id, destination.id])
        XCTAssertEqual(model.tasks.count, 2)
        XCTAssertNil(model.tasks.first { $0.id == source.id }?.parentId)
        XCTAssertEqual(model.ordered(model.tasks).map(\.id), [destination.id, source.id])
        XCTAssertNil(model.dragId)
        XCTAssertEqual(try store.listTasks().count, 2)
    }

    func testCrossGroupBlockCommitAndExplicitIndentOutdentPreserveEveryTask() async throws {
        let store = try store()
        let group = try store.addGroup(name: "Destination")
        let parent = try store.addTask(title: "parent", category: DotistGroup.inboxID)
        let child = try store.addTask(title: "child", category: DotistGroup.inboxID, parentId: parent.id)
        let sibling = try store.addTask(title: "sibling", category: group.id)
        let model = try AppModel(store: store)
        let identities = Set(model.tasks.map(\.id))
        model.beginDrag(parent.id, scope: "list:all")
        await commit(parent.id, to: .init(groupID: group.id, slot: 0, level: 0, parentID: nil, beforeID: sibling.id), model: model)
        XCTAssertEqual(Set(model.tasks.map(\.id)), identities)
        XCTAssertTrue(model.tasks.allSatisfy { $0.category == group.id })
        XCTAssertEqual(model.tasks.first { $0.id == child.id }?.parentId, parent.id)
        model.beginDrag(sibling.id, scope: "list:all")
        await commit(sibling.id, to: .init(groupID: group.id, slot: 1, level: 1, parentID: parent.id, beforeID: child.id), model: model)
        XCTAssertEqual(model.tasks.first { $0.id == sibling.id }?.parentId, parent.id)
        XCTAssertEqual(Set(model.tasks.map(\.id)), identities)
        model.beginDrag(sibling.id, scope: "list:all")
        await commit(sibling.id, to: .init(groupID: group.id, slot: 0, level: 0, parentID: nil, beforeID: parent.id), model: model)
        XCTAssertNil(model.tasks.first { $0.id == sibling.id }?.parentId)
        XCTAssertEqual(model.tasks.count, 3)
    }

    func testCancellationDoesNotMutateStore() throws {
        let store = try store()
        let task = try store.addTask(title: "cancel me", category: DotistGroup.inboxID)
        let model = try AppModel(store: store)
        let before = try store.listTasks()
        model.beginDrag(task.id, scope: "list:all")
        model.endDrag()
        XCTAssertEqual(try store.listTasks(), before)
        XCTAssertEqual(model.tasks, before)
    }
    func testAutoScrollMovesLongDocumentAndClampsAtBothEdges() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let document = FlippedReorderDocument(frame: NSRect(x: 0, y: 0, width: 320, height: 1200))
        scrollView.documentView = document
        scrollView.contentView.scroll(to: .zero)
        let runtime = TaskReorderRuntime()
        runtime.scrollView = scrollView
        XCTAssertFalse(runtime.scroll(by: -14))
        XCTAssertTrue(runtime.scroll(by: 14))
        XCTAssertEqual(scrollView.contentView.bounds.minY, 14, accuracy: 0.1)
        XCTAssertTrue(runtime.scroll(by: 5000))
        XCTAssertEqual(scrollView.contentView.bounds.minY, 1000, accuracy: 0.1)
        XCTAssertFalse(runtime.scroll(by: 14))
        XCTAssertTrue(runtime.scroll(by: -5000))
        XCTAssertEqual(scrollView.contentView.bounds.minY, 0, accuracy: 0.1)
    }

}

@MainActor
final class LegacyTaskDragSourceTests: XCTestCase {
    private func source() -> TaskDragSourceView {
        _ = NSApplication.shared
        let window = DotistPanel(contentRect: NSRect(x: 200, y: 200, width: 200, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let view = TaskDragSourceView(id: "task-id", title: "A task", font: .systemFont(ofSize: 13))
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        window.contentView = view
        addTeardownBlock { window.close() }
        return view
    }
    private func event(_ type: NSEvent.EventType, point: NSPoint, in view: NSView, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    func testTitleAcceptsFirstClickAndDoesNotDragThePanel() {
        let view = source()
        var clicks = 0
        var begins = 0
        view.click = { clicks += 1 }
        view.begin = { begins += 1 }
        let before = view.window!.frame
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertFalse(view.mouseDownCanMoveWindow)
        view.mouseDown(with: event(.leftMouseDown, point: NSPoint(x: 40, y: 20), in: view))
        view.mouseUp(with: event(.leftMouseUp, point: NSPoint(x: 40, y: 20), in: view))
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(begins, 0)
        XCTAssertEqual(view.window!.frame, before)
    }

    func testSmallPointerMovementStillEditsOnceWithoutStartingDrag() {
        let view = source()
        var clicks = 0
        var begins = 0
        view.click = { clicks += 1 }
        view.begin = { begins += 1 }
        view.mouseDown(with: event(.leftMouseDown, point: NSPoint(x: 40, y: 20), in: view))
        view.mouseDragged(with: event(.leftMouseDragged, point: NSPoint(x: 42, y: 19), in: view))
        view.mouseUp(with: event(.leftMouseUp, point: NSPoint(x: 42, y: 19), in: view))
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(begins, 0)
    }

    func testReleasingOutsideTitleDoesNotEdit() {
        let view = source()
        var clicks = 0
        view.click = { clicks += 1 }
        view.mouseDown(with: event(.leftMouseDown, point: NSPoint(x: 40, y: 20), in: view))
        view.mouseUp(with: event(.leftMouseUp, point: NSPoint(x: 250, y: 20), in: view))
        XCTAssertEqual(clicks, 0)
        view.mouseDown(with: event(.leftMouseDown, point: NSPoint(x: 40, y: 20), in: view))
        view.mouseUp(with: event(.leftMouseUp, point: NSPoint(x: 40, y: 20), in: view))
        XCTAssertEqual(clicks, 1)
    }
}

private final class FlippedReorderDocument: NSView {
    override var isFlipped: Bool { true }
}
