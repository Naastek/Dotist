import Foundation
import XCTest
@testable import DotistCore

final class TaskReorderCommitTests: XCTestCase {
    func testAtomicMovePreservesTasksAndChildrenAndRejectsInvalidParent() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathComponent("tasks.sqlite").path
        let store = try TaskStore(databasePath: path)
        let a = try store.addTask(title: "A", category: "work")
        let child = try store.addTask(title: "child", category: "work", parentId: a.id)
        let b = try store.addTask(title: "B", category: "life")
        try store.commitReorder(a.id, groupID: "life", parentID: nil, beforeID: b.id)
        let moved = try store.listTasks()
        XCTAssertEqual(moved.count, 3)
        XCTAssertEqual(moved.first { $0.id == child.id }?.category, "life")
        XCTAssertEqual(moved.filter { $0.parentId == nil && $0.category == "life" }.sorted { ($0.position, $0.id) < ($1.position, $1.id) }.map(\.id), [a.id, b.id])
        XCTAssertThrowsError(try store.commitReorder(a.id, groupID: "life", parentID: b.id, beforeID: nil))
        XCTAssertEqual(try store.listTasks(), moved)
        XCTAssertThrowsError(try store.commitReorder(b.id, groupID: "work", parentID: nil, beforeID: "stale"))
        XCTAssertEqual(try store.listTasks(), moved)
        try store.commitReorder(b.id, groupID: "life", parentID: a.id, beforeID: child.id)
        let nested = try store.listTasks()
        XCTAssertEqual(nested.count, 3)
        XCTAssertEqual(nested.first { $0.id == b.id }?.parentId, a.id)
        XCTAssertEqual(nested.filter { $0.parentId == a.id }.sorted { ($0.position, $0.id) < ($1.position, $1.id) }.map(\.id), [b.id, child.id])
    }
}
