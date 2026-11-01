import Combine
import DotistCore
import Foundation
import XCTest
@testable import DotistApp

@MainActor
final class DateFilterModelTests: XCTestCase {
    func testDayAndTimezoneChangesInvalidateVisibleDateQueriesWithoutTaskChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-date-clock-\(UUID().uuidString)")
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            let changed = expectation(description: "Refresh date filters for \(name.rawValue)")
            let subscription = model.objectWillChange.sink { changed.fulfill() }
            NotificationCenter.default.post(name: name, object: nil)
            await fulfillment(of: [changed], timeout: 0.5)
            subscription.cancel()
        }
    }

    func testPanelQueryKeepsDeepUngroupedMatchUnderCompletedAncestorAndIsolatesPanelTags() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-date-model-\(UUID().uuidString)")
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try store.addTask(title: "done root")
        _ = try store.patchTask(id: root.id, completed: true)
        let a = try store.addTask(title: "a", parentId: root.id)
        let b = try store.addTask(title: "b", parentId: a.id)
        let c = try store.addTask(title: "c", parentId: b.id)
        let leaf = try store.addTask(title: "leaf #focus", parentId: c.id, dueDate: "2026-11-02")
        let other = try store.addTask(title: "other #elsewhere", category: "work", dueDate: "2026-11-02")
        let model = try AppModel(store: store)
        model.selectTag("elsewhere")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 1
        let now = ISO8601DateFormatter().date(from: "2026-11-01T04:00:00Z")!
        let result = model.filteredTasks(scope: "tomorrow", groupID: DotistGroup.inboxID, tag: "focus", now: now, calendar: calendar)
        XCTAssertEqual(result.matches.map(\.id), [leaf.id])
        XCTAssertEqual(result.contextIDs, [root.id, a.id, b.id, c.id])
        XCTAssertEqual(result.roots.map(\.id), [root.id])
        XCTAssertFalse(result.tasks.contains { $0.id == other.id })
        XCTAssertEqual(model.filteredTasks(scope: "all", groupID: DotistGroup.inboxID, now: now, calendar: calendar).matches.count, 4)
        XCTAssertEqual(model.filteredTasks(scope: "done", groupID: DotistGroup.inboxID, now: now, calendar: calendar).matches.map(\.id), [root.id])
        XCTAssertEqual(model.todayTaskSections(groupID: DotistGroup.inboxID, tag: "focus", now: now, calendar: calendar).upcoming.matches.map(\.id), [leaf.id])
        XCTAssertEqual(model.dateFilterRange(scope: "week", now: now, calendar: calendar), TaskDateRange("2026-11-01", "2026-11-07"))
        XCTAssertEqual(model.activeTag, "elsewhere", "Each panel supplies its own tag without changing another panel")
    }
}
