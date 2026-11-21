import Foundation
import GRDB
import XCTest
@testable import DotistCore

final class TaskPlanTests: XCTestCase {
    private func store() throws -> TaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-plan-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
    }

    private func calendar(_ zone: String = "Asia/Shanghai", firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testTodayRollsIntoWeekAndReturnsToOriginalGroupWithoutWriting() throws {
        let store = try store()
        let parent = try store.addTask(title: "Deliver draft", category: "work")
        let child = try store.addTask(title: "Proofread #writing", parentId: parent.id, dueDate: "2026-11-27")
        _ = try store.setStartDate(child.id, date: "2026-11-21")
        _ = try store.patchTask(id: child.id, status: .doing)
        let friday = instant("2026-11-20T15:59:59Z")
        let saturday = instant("2026-11-20T16:00:00Z")
        let monday = instant("2026-11-22T16:00:00Z")
        let calendar = calendar()
        let planned = try store.setPlan(child.id, scope: .today, now: friday, calendar: calendar)
        XCTAssertEqual(try store.setPlan(child.id, scope: .today, now: friday, calendar: calendar), planned)

        let reopened = try TaskStore(databasePath: store.databasePath())
        let tasks = try reopened.listTasks()
        let before = TaskFiltering(tasks, now: friday, calendar: calendar)
        let plan = before.filter(scope: TaskPlanScope.today.rawValue, groupID: "work", tag: "writing")
        XCTAssertEqual(plan.matches.map(\.id), [child.id])
        XCTAssertEqual(plan.contextIDs, [parent.id])
        XCTAssertTrue(before.filter(scope: TaskPlanScope.week.rawValue).matches.isEmpty)
        XCTAssertEqual(before.todaySections().openCount, 0)

        let nextDay = TaskFiltering(tasks, now: saturday, calendar: calendar)
        XCTAssertTrue(nextDay.filter(scope: TaskPlanScope.today.rawValue).matches.isEmpty)
        XCTAssertEqual(nextDay.filter(scope: TaskPlanScope.week.rawValue).matches, [planned])
        var newWeekPreference = calendar
        newWeekPreference.firstWeekday = 7
        XCTAssertEqual(TaskFiltering(tasks, now: saturday, calendar: newWeekPreference)
            .filter(scope: TaskPlanScope.week.rawValue).matches, [planned])

        let nextWeek = TaskFiltering(tasks, now: monday, calendar: calendar)
        XCTAssertTrue(nextWeek.filter(scope: TaskPlanScope.week.rawValue).matches.isEmpty)
        XCTAssertTrue(nextWeek.filter(scope: TaskPlanScope.today.rawValue).matches.isEmpty)
        XCTAssertEqual(nextWeek.filter(scope: "all", groupID: "work").matches.first { $0.id == child.id }, planned)
        XCTAssertEqual(nextWeek.filter(scope: "week").matches, [planned])
        XCTAssertEqual(try reopened.listTasks(), tasks)
        XCTAssertEqual(planned.dueDate, "2026-11-27")
        XCTAssertEqual(planned.startDate, "2026-11-21")
        XCTAssertEqual(planned.status, .doing)
        XCTAssertEqual(planned.parentId, parent.id)
    }

    func testRolloverUsesLocalWeekAcrossDSTAndCivilYearBoundary() throws {
        let store = try store()
        let task = try store.addTask(title: "Plan")
        let pacific = calendar("America/Los_Angeles", firstWeekday: 1)
        let sunday = instant("2026-11-01T07:30:00Z")
        let monday = instant("2026-11-02T08:00:00Z")
        let plan = try store.setPlan(task.id, scope: .today, now: sunday, calendar: pacific)
        XCTAssertEqual(plan.plannedDay, "2026-11-01")
        XCTAssertEqual(TaskFiltering([plan], now: monday, calendar: pacific).filter(scope: TaskPlanScope.week.rawValue).matches, [plan])
        let newYear = instant("2027-01-01T04:00:00Z")
        let yearEnd = try store.setPlan(task.id, scope: .today, now: instant("2026-12-31T04:00:00Z"), calendar: calendar())
        XCTAssertEqual(TaskFiltering([yearEnd], now: newYear, calendar: calendar()).filter(scope: TaskPlanScope.week.rawValue).matches, [yearEnd])
    }

    func testPlanChangesCanBeUndoneAndSurviveCompletionAndDeletion() throws {
        let store = try store()
        let task = try store.addTask(title: "Review", dueDate: "2026-11-27")
        let now = instant("2026-11-20T04:00:00Z")
        let calendar = calendar()
        let patch = try store.captureChanges { _ = try $0.setPlan(task.id, scope: .today, now: now, calendar: calendar) }
        XCTAssertFalse(patch.isEmpty)
        try store.apply(patch: patch.before)
        XCTAssertNil(try store.listTasks().first?.plannedDay)
        try store.apply(patch: patch.after)
        let completed = try store.patchTask(id: task.id, completed: true)
        XCTAssertTrue(TaskFiltering([completed], now: now, calendar: calendar).filter(scope: TaskPlanScope.today.rawValue).matches.isEmpty)
        let reopened = try store.patchTask(id: task.id, completed: false)
        XCTAssertEqual(reopened.plannedDay, "2026-11-20")
        try store.deleteTask(task.id)
        let restored = try store.restoreTask(task.id)
        XCTAssertEqual(restored.plannedDay, reopened.plannedDay)
        _ = try store.setPlan(task.id, scope: nil)
        let cleared = try XCTUnwrap(store.listTasks().first)
        XCTAssertNil(cleared.plannedWeekStart)
        XCTAssertEqual(cleared.dueDate, task.dueDate)
    }

    func testLegacyV5TasksKeepTheirDatesAndHaveNoPlanOnRepeatedOpen() throws {
        let store = try store()
        let task = try store.addTask(title: "Legacy", dueDate: "2026-11-20")
        _ = try store.setStartDate(task.id, date: "2026-11-19")
        let original = try store.snapshot().tasks
        try store.database.write { db in
            try db.execute(sql: "ALTER TABLE tasks DROP COLUMN planned_day; ALTER TABLE tasks DROP COLUMN planned_week_start")
        }
        for _ in 0..<2 {
            let reopened = try TaskStore(databasePath: store.databasePath())
            XCTAssertEqual(try reopened.listTasks(), original)
            XCTAssertEqual(try reopened.database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, 5)
        }
    }

    func testUndoAndRedoKeepIndependentDeadlineAndPlanEditsFromAnotherClient() throws {
        let store = try store()
        let task = try store.addTask(title: "Review", dueDate: "2026-11-27")
        let dateChange = try store.captureChanges { _ = try $0.setDueDate(task.id, date: "2026-11-28") }
        let client = try TaskStore(databasePath: store.databasePath())
        let today = try client.setPlan(task.id, scope: .today)
        try store.apply(mutation: dateChange, redo: false)
        XCTAssertEqual(try store.listTasks().first?.plannedDay, today.plannedDay)
        XCTAssertEqual(try store.listTasks().first?.dueDate, task.dueDate)
        try store.apply(mutation: dateChange, redo: true)

        let planChange = try store.captureChanges { _ = try $0.setPlan(task.id, scope: .week) }
        _ = try client.setDueDate(task.id, date: "2026-11-29")
        try store.apply(mutation: planChange, redo: false)
        XCTAssertEqual(try store.listTasks().first?.plannedDay, today.plannedDay)
        XCTAssertEqual(try store.listTasks().first?.dueDate, "2026-11-29")
        try store.apply(mutation: planChange, redo: true)
        XCTAssertNil(try store.listTasks().first?.plannedDay)
        XCTAssertEqual(try store.listTasks().first?.dueDate, "2026-11-29")
    }
}
