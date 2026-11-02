import Foundation
import XCTest
@testable import DotistCore

final class TaskStoreTests: XCTestCase {
    func testTagsUseTheSharedTaskStoreAndKeepFamilyContext() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dotist-swift-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let parent = try store.addTask(title: "父任务", category: "work")
        let tagged = try store.addTask(title: "子任务 #设计", category: "work", parentId: parent.id)
        let sibling = try store.addTask(title: "另一子任务", category: "work", parentId: parent.id)
        let unrelated = try store.addTask(title: "保留  空格", category: "life")
        XCTAssertEqual(Set(try store.filterByTag("设计").map(\.id)), Set([parent.id, tagged.id, sibling.id]))
        XCTAssertEqual(try store.describeTags().counts.first { $0.tag == "设计" }?.open, 1)
        try store.retag("设计", replacement: "新标签")
        let tasks = try store.listTasks()
        XCTAssertEqual(tasks.first { $0.id == tagged.id }?.title, "子任务 #新标签")
        XCTAssertEqual(tasks.first { $0.id == unrelated.id }?.title, "保留  空格")
        try store.retag("新标签", replacement: nil)
        XCTAssertEqual(try store.listTasks().first { $0.id == tagged.id }?.title, "子任务")
    }
    func testNativeStoreRetainsTaskSemantics() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dotist-swift-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"theme":"dark","opacity":0,"window_width":100,"window_height":1000}"#.utf8).write(to: directory.appendingPathComponent("settings.json"))
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        XCTAssertEqual(try store.settings().theme, "dark")
        XCTAssertEqual(try store.settings().opacity, 0)
        XCTAssertEqual(try store.settings().windowWidth, 320)
        var patch = DotistSettingsPatch()
        patch.theme = "light"
        patch.opacity = 99
        let updated = try store.updateSettings(patch)
        XCTAssertEqual(updated.theme, "light")
        XCTAssertEqual(updated.opacity, 99)
        XCTAssertEqual(try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path).settings(), updated)
        patch.theme = "invalid"
        XCTAssertThrowsError(try store.updateSettings(patch))
        XCTAssertEqual(try store.settings(), updated)
        let work = try store.addTask(title: "工作任务", category: "work", dueDate: "2026-11-10")
        let life = try store.addTask(title: "生活任务", category: "life", dueDate: "2026-11-10")
        let child = try store.addTask(title: "子任务", category: "work", parentId: work.id)
        try store.reorder(life.id, relativeTo: work.id, after: true, allTasks: true)
        try store.reorder(life.id, relativeTo: work.id, after: false, allTasks: true)
        let reordered = try store.listTasks()
        let sorted = reordered.sorted { $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position }
        let lifeIndex = try XCTUnwrap(sorted.firstIndex { $0.id == life.id })
        let workIndex = try XCTUnwrap(sorted.firstIndex { $0.id == work.id })
        XCTAssertEqual(lifeIndex + 1, workIndex)
        XCTAssertEqual(reordered.first { $0.id == life.id }?.category, "life")
        XCTAssertEqual(reordered.first { $0.id == life.id }?.dueDate, "2026-11-10")
        XCTAssertThrowsError(try store.setDateRange(work.id, start: "2026-11-11", due: "2026-11-10"))
        _ = try store.patchTask(id: work.id, status: .done)
        XCTAssertEqual(try store.listTasks().first { $0.id == child.id }?.completed, true)
        try store.deleteTask(work.id)
        _ = try store.restoreTask(work.id)
        XCTAssertNotNil(try store.listTasks().first { $0.id == child.id })
    }
}
