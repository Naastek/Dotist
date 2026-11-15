import Foundation
import XCTest
@testable import DotistCore

final class FirstRunExamplesTests: XCTestCase {
    func testFreshLibraryHasEnglishGroupsTasksAndUsableTags() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("tasks.sqlite").path
        let store = try TaskStore(databasePath: path, includeExamples: true)
        XCTAssertEqual(Set(try store.listGroups().map(\.name)), ["Inbox", "Work", "Life", "Study"])
        let tasks = try store.listTasks()
        XCTAssertEqual(tasks.count, 6)
        XCTAssertTrue(tasks.allSatisfy { $0.title.unicodeScalars.allSatisfy(\.isASCII) })
        XCTAssertEqual(Set(tasks.map(\.category)), ["work", "life", "study"])
        XCTAssertEqual(try store.filterByTag("reading").count, 1)
        XCTAssertEqual(try store.describeTags().counts.count, 6)
        XCTAssertEqual(try TaskStore(databasePath: path, includeExamples: true).snapshot(), try store.snapshot())
    }

    func testExistingNamesTasksAndSettingsArePreservedAndEmptyLibraryStaysEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("tasks.sqlite").path
        let store = try TaskStore(databasePath: path)
        _ = try store.updateGroup("work", name: "我的工作")
        _ = try store.addTask(title: "个人任务 #私人", category: "work")
        var patch = DotistSettingsPatch()
        patch.theme = "dark"
        _ = try store.updateSettings(patch)
        let before = try store.snapshot()
        let reopened = try TaskStore(databasePath: path, includeExamples: true)
        XCTAssertEqual(try reopened.snapshot(), before)
        XCTAssertEqual(try reopened.settings(), try store.settings())
        for task in try store.listTasks() { try store.deleteTask(task.id) }
        XCTAssertTrue(try TaskStore(databasePath: path, includeExamples: true).listTasks().isEmpty)
    }
}
