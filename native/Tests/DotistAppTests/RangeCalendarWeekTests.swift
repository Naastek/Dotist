import DotistCore
import XCTest
@testable import DotistApp

final class RangeCalendarWeekTests: XCTestCase {
    // Wednesday 2026-11-11, noon in the test machine's time zone.
    private let wednesday = Date.dotistDay("2026-11-11")!.addingTimeInterval(12 * 3600)

    private func calendar(firstWeekday: Int) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        value.firstWeekday = firstWeekday
        return value
    }

    private func ranges(single: Bool, firstWeekday: Int) -> [String: (String, String)] {
        let pairs = RangeCalendar.quickRanges(single: single, now: wednesday, calendar: calendar(firstWeekday: firstWeekday))
        return Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, ($0.1, $0.2)) })
    }

    func testWeekShortcutsFollowTheSystemWeekStart() {
        let monday = ranges(single: false, firstWeekday: 2)
        XCTAssertEqual(monday["本周"]?.0, "2026-11-09")
        XCTAssertEqual(monday["本周"]?.1, "2026-11-15")
        XCTAssertEqual(monday["下周"]?.0, "2026-11-16")
        XCTAssertEqual(monday["下周"]?.1, "2026-11-22")

        let sunday = ranges(single: false, firstWeekday: 1)
        XCTAssertEqual(sunday["本周"]?.0, "2026-11-08")
        XCTAssertEqual(sunday["本周"]?.1, "2026-11-14")
        XCTAssertEqual(sunday["下周"]?.0, "2026-11-15")
        XCTAssertEqual(sunday["下周"]?.1, "2026-11-21")
        XCTAssertEqual(sunday["未来 7 天"]?.0, "2026-11-11")
        XCTAssertEqual(sunday["未来 7 天"]?.1, "2026-11-17")
    }

    func testWeekShortcutsMatchThePanelFilter() {
        for firstWeekday in [1, 2] {
            let filter = TaskFiltering([], now: wednesday, calendar: calendar(firstWeekday: firstWeekday))
            let quick = ranges(single: false, firstWeekday: firstWeekday)
            for (label, scope) in [("本周", "week"), ("下周", "nextweek"), ("未来 7 天", "next7"), ("明天", "tomorrow")] {
                let range = filter.range(scope: scope)
                XCTAssertEqual(quick[label]?.0, range.start, "\(label) start, firstWeekday \(firstWeekday)")
                XCTAssertEqual(quick[label]?.1, range.end, "\(label) end, firstWeekday \(firstWeekday)")
            }
        }
    }

    func testNextMondayStaysMondayWhateverTheWeekStart() {
        XCTAssertEqual(ranges(single: true, firstWeekday: 2)["下周一"]?.0, "2026-11-16")
        XCTAssertEqual(ranges(single: true, firstWeekday: 1)["下周一"]?.0, "2026-11-16")
    }
}
