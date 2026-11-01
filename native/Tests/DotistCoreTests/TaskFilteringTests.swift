import Foundation
import XCTest
@testable import DotistCore

final class TaskFilteringTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai", firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func task(_ id: String, due: String? = nil, done: Bool = false, parent: String? = nil,
                      group: String = "inbox", title: String? = nil, updated: String = "2026-10-01T00:00:00Z") -> DotistTask {
        DotistTask(id: id, title: title ?? id, category: group, completed: done, status: done ? .done : .todo,
                   position: Int64(id.utf8.reduce(0) { $0 + Int($1) }), createdAt: updated, updatedAt: updated,
                   deletedAt: nil, revision: 1, parentId: parent, dueDate: due, startDate: nil)
    }

    func testDateFilterMatrixUsesEachTasksOwnDateAndCompletion() {
        let tasks = [task("old", due: "2026-10-31"), task("today", due: "2026-11-01"),
                     task("tomorrow", due: "2026-11-02"), task("six", due: "2026-11-07"),
                     task("seven", due: "2026-11-08"), task("none"),
                     task("done", due: "2026-11-01", done: true), task("done-none", done: true)]
        let filtering = TaskFiltering(tasks, now: instant("2026-11-01T04:00:00Z"), calendar: calendar())
        let matrix: [(String, Set<String>)] = [
            ("today", ["today"]), ("all", ["old", "today", "tomorrow", "six", "seven", "none"]),
            ("tomorrow", ["tomorrow"]), ("week", ["old", "today"]),
            ("nextweek", ["tomorrow", "six", "seven"]), ("next7", ["today", "tomorrow", "six"]),
            ("overdue", ["old"]), ("undated", ["none"]), ("done", ["done", "done-none"])
        ]
        for (scope, expected) in matrix {
            XCTAssertEqual(Set(filtering.filter(scope: scope).matches.map(\.id)), expected, scope)
        }
    }

    func testWeekUsesSystemFirstWeekdayIncludingSundayAndYearBoundary() {
        let now = instant("2026-11-01T04:00:00Z") // Sunday
        let sunday = TaskFiltering([], now: now, calendar: calendar(firstWeekday: 1))
        XCTAssertEqual(sunday.range(scope: "week"), TaskDateRange("2026-11-01", "2026-11-07"))
        XCTAssertEqual(sunday.range(scope: "nextweek"), TaskDateRange("2026-11-08", "2026-11-14"))
        let monday = TaskFiltering([], now: now, calendar: calendar())
        XCTAssertEqual(monday.range(scope: "week"), TaskDateRange("2026-10-26", "2026-11-01"))
        let newYear = TaskFiltering([], now: instant("2027-01-01T04:00:00Z"), calendar: calendar())
        XCTAssertEqual(newYear.range(scope: "week"), TaskDateRange("2026-12-28", "2027-01-03"))
    }

    func testCivilDaysUseLocalTimeZoneAndDoNotAddFixedSecondsAcrossDST() {
        let tasks = [task("oct", due: "2026-10-31"), task("nov", due: "2026-11-01")]
        let now = instant("2026-11-01T00:30:00Z")
        XCTAssertEqual(TaskFiltering(tasks, now: now, calendar: calendar()).filter(scope: "today").matches.map(\.id), ["nov"])
        XCTAssertEqual(TaskFiltering(tasks, now: now, calendar: calendar("America/Los_Angeles")).filter(scope: "today").matches.map(\.id), ["oct"])
        let dst = TaskFiltering([], now: instant("2026-11-01T07:30:00Z"), calendar: calendar("America/Los_Angeles"))
        XCTAssertEqual(dst.range(scope: "tomorrow"), TaskDateRange("2026-11-02", "2026-11-02"))
        XCTAssertEqual(dst.range(scope: "next7"), TaskDateRange("2026-11-01", "2026-11-07"))
        let before = TaskFiltering(tasks, now: instant("2026-10-31T15:59:59Z"), calendar: calendar())
        let after = TaskFiltering(tasks, now: instant("2026-10-31T16:00:00Z"), calendar: calendar())
        XCTAssertEqual(before.filter(scope: "today").matches.map(\.id), ["oct"])
        XCTAssertEqual(after.filter(scope: "today").matches.map(\.id), ["nov"])
    }

    func testNonGregorianSystemCalendarStillComparesGregorianStorageDates() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let filtering = TaskFiltering([task("today", due: "2026-11-01")], now: instant("2026-11-01T04:00:00Z"), calendar: buddhist)
        XCTAssertEqual(filtering.filter(scope: "today").matches.map(\.id), ["today"])
    }

    func testCustomRangeIncludesBothEndpointsAndOverridesOtherScopes() {
        let tasks = [task("before", due: "2026-11-01"), task("start", due: "2026-11-02"),
                     task("end", due: "2026-11-04"), task("after", due: "2026-11-05"),
                     task("done", due: "2026-11-03", done: true), task("none")]
        let filtering = TaskFiltering(tasks, now: instant("2026-11-01T04:00:00Z"), calendar: calendar())
        for scope in ["today", "all", "overdue", "done"] {
            let result = filtering.filter(scope: scope, customRange: TaskDateRange("2026-11-04", "2026-11-02"))
            XCTAssertEqual(Set(result.matches.map(\.id)), ["start", "end"], scope)
        }
        XCTAssertEqual(Set(filtering.filter(scope: "today", customRange: TaskDateRange("2026-11-02", "2026-11-04"), completed: true).matches.map(\.id)), ["done"])
    }

    func testDeepMatchRetainsOnlyAncestorsAndDoesNotCountOrIncludeTheirSiblings() {
        let tasks = [task("root"), task("a", parent: "root"), task("b", parent: "a"),
                     task("c", parent: "b"), task("leaf", due: "2026-11-02", parent: "c"),
                     task("sibling", parent: "root")]
        let result = TaskFiltering(tasks, now: instant("2026-11-01T04:00:00Z"), calendar: calendar()).filter(scope: "tomorrow")
        XCTAssertEqual(result.matches.map(\.id), ["leaf"])
        XCTAssertEqual(result.tasks.map(\.id), ["root", "a", "b", "c", "leaf"])
        XCTAssertEqual(result.contextIDs, ["root", "a", "b", "c"])
    }

    func testCompletedParentDoesNotHideOpenChildOrPromoteItToCompleted() {
        let tasks = [task("root", done: true), task("child", due: "2026-11-01", parent: "root"),
                     task("done-child", done: true, parent: "root")]
        let filtering = TaskFiltering(tasks, now: instant("2026-11-01T04:00:00Z"), calendar: calendar())
        let open = filtering.filter(scope: "all")
        XCTAssertEqual(open.matches.map(\.id), ["child"])
        XCTAssertEqual(open.contextIDs, ["root"])
        XCTAssertEqual(Set(filtering.filter(scope: "done").matches.map(\.id)), ["root", "done-child"])
        XCTAssertEqual(filtering.filter(scope: "today").matches.map(\.id), ["child"])
    }

    func testTagFamilyContextCombinesWithDateAndGroupWithoutLeakingOtherGroups() {
        let tasks = [task("root", group: "work"), task("tagged", due: "2026-11-02", parent: "root", group: "work", title: "task #focus"),
                     task("sibling", due: "2026-11-02", parent: "root", group: "work"),
                     task("other", due: "2026-11-02", group: "life", title: "other #focus"),
                     task("unrelated", due: "2026-11-02", group: "work")]
        let result = TaskFiltering(tasks, now: instant("2026-11-01T04:00:00Z"), calendar: calendar())
            .filter(scope: "tomorrow", groupID: "work", tag: "focus")
        XCTAssertEqual(Set(result.matches.map(\.id)), ["tagged", "sibling"])
        XCTAssertEqual(result.contextIDs, ["root"])
        XCTAssertEqual(Set(result.tasks.map(\.id)), ["root", "tagged", "sibling"])
    }

    func testTodayDashboardPartitionsOpenTasksAndIncludesUndatedCompletionsToday() {
        let tasks = [task("old", due: "2026-10-31"), task("due", due: "2026-11-01"), task("next", due: "2026-11-02"),
                     task("seven", due: "2026-11-08"), task("eight", due: "2026-11-09"), task("none"),
                     task("due-done", due: "2026-11-01", done: true),
                     task("undated-done", done: true, updated: "2026-10-31T16:10:00Z"),
                     task("future-done", due: "2026-12-01", done: true, updated: "2026-11-01T01:00:00.123456789Z"),
                     task("old-done", due: "2026-10-31", done: true)]
        let result = TaskFiltering(tasks, now: instant("2026-11-01T04:00:00Z"), calendar: calendar()).todaySections()
        XCTAssertEqual(result.overdue.matches.map(\.id), ["old"])
        XCTAssertEqual(result.today.matches.map(\.id), ["due"])
        XCTAssertEqual(Set(result.upcoming.matches.map(\.id)), ["next", "seven"])
        XCTAssertEqual(Set(result.completed.matches.map(\.id)), ["due-done", "undated-done", "future-done"])
    }

    func testCompletedResultsAreNotTruncatedAndNewestCompletionComesFirst() {
        let tasks = (0..<205).map { task("done-\($0)", done: true, updated: $0 == 204 ? "2026-11-01T04:00:00Z" : "2026-10-31T04:00:00Z") }
        let result = TaskFiltering(tasks, now: instant("2026-11-01T04:00:00Z"), calendar: calendar()).filter(scope: "done")
        XCTAssertEqual(result.matches.count, 205)
        XCTAssertEqual(result.tasks.first?.id, "done-204")
    }
}
