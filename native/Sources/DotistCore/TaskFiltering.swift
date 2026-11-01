import Foundation

/// Inclusive Gregorian civil dates, in the same YYYY-MM-DD format as dueDate.
public struct TaskDateRange: Equatable, Sendable {
    public let start: String
    public let end: String
    public init(_ start: String, _ end: String) {
        self.start = min(start, end)
        self.end = max(start, end)
    }
    public func contains(_ day: String) -> Bool { day >= start && day <= end }
}

public struct TaskFilterResult: Sendable {
    /// Only these tasks count toward the filter; ancestors never inflate counts.
    public let matches: [DotistTask]
    /// Matches and their ancestor paths, in outline order.
    public let tasks: [DotistTask]
    public let contextIDs: Set<String>
    public var roots: [DotistTask] {
        let ids = Set(tasks.map(\.id))
        return tasks.filter { $0.parentId.map { !ids.contains($0) } ?? true }
    }
}

public struct TaskTodaySections: Sendable {
    public let overdue: TaskFilterResult
    public let today: TaskFilterResult
    public let upcoming: TaskFilterResult
    public let completed: TaskFilterResult
}

/// Shared by AppModel and tests. Every task matches its own date/status, and a
/// matching descendant brings only its ancestors, never unrelated siblings.
/// Tag selection deliberately retains TaskTags' existing family semantics first.
public struct TaskFiltering {
    private let tasks: [DotistTask]
    private let now: Date
    private let calendar: Calendar
    private let dayFormatter: DateFormatter
    private let timestampFormatter: ISO8601DateFormatter
    private let fractionalTimestampFormatter: ISO8601DateFormatter

    public init(_ tasks: [DotistTask], now: Date = Date(), calendar: Calendar = .current) {
        self.tasks = tasks.filter { $0.deletedAt == nil }
        self.now = now
        // Storage uses Gregorian dates even with a Buddhist/Japanese system calendar.
        // Preserve the user's time zone and first weekday, independently of UI language.
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = calendar.timeZone
        civil.firstWeekday = calendar.firstWeekday
        civil.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        self.calendar = civil
        let formatter = DateFormatter()
        formatter.calendar = civil
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = civil.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        dayFormatter = formatter
        timestampFormatter = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalTimestampFormatter = fractional
    }

    private func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    private func timestamp(_ value: String) -> Date? {
        fractionalTimestampFormatter.date(from: value) ?? timestampFormatter.date(from: value)
    }

    public func range(scope: String) -> TaskDateRange {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday - calendar.firstWeekday + 7) % 7), to: today)!
        func add(_ date: Date, _ days: Int) -> String { day(calendar.date(byAdding: .day, value: days, to: date)!) }
        switch scope {
        case "tomorrow": return TaskDateRange(add(today, 1), add(today, 1))
        case "week": return TaskDateRange(day(weekStart), add(weekStart, 6))
        case "nextweek": return TaskDateRange(add(weekStart, 7), add(weekStart, 13))
        case "next7": return TaskDateRange(day(today), add(today, 6))
        default: return TaskDateRange(day(today), day(today))
        }
    }

    private func candidates(groupID: String?, tag: String?) -> [DotistTask] {
        let family = tag.map { TaskTags.filter(tasks, tag: $0) } ?? tasks
        return family.filter { groupID == nil || $0.category == groupID }
    }

    private func result(_ matches: [DotistTask], within candidates: [DotistTask], newestFirst: Bool = false) -> TaskFilterResult {
        let hierarchy = TaskHierarchy(candidates)
        let matchIDs = Set(matches.map(\.id))
        var included = matchIDs
        for task in matches { included.formUnion(hierarchy.ancestors(of: task.id).map(\.id)) }
        let updated = newestFirst ? Dictionary(uniqueKeysWithValues: matches.map { ($0.id, timestamp($0.updatedAt) ?? .distantPast) }) : [:]
        let orderedMatches = matches.sorted {
            if newestFirst {
                let a = updated[$0.id]!, b = updated[$1.id]!
                if a != b { return a > b }
            }
            return $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position
        }
        let outline: [DotistTask]
        if newestFirst {
            // Emit each ancestor before its first matching descendant, preserving
            // the completion ordering without repeating an ancestor identity.
            var seen: Set<String> = []
            outline = orderedMatches.flatMap { task in
                (Array(hierarchy.ancestors(of: task.id).reversed()) + [task]).filter { seen.insert($0.id).inserted }
            }
        } else {
            outline = TaskHierarchy(candidates.filter { included.contains($0.id) }).outline()
        }
        return TaskFilterResult(matches: orderedMatches, tasks: outline, contextIDs: included.subtracting(matchIDs))
    }

    public func filter(scope: String, groupID: String? = nil, tag: String? = nil,
                       customRange: TaskDateRange? = nil, completed: Bool = false) -> TaskFilterResult {
        let candidates = candidates(groupID: groupID, tag: tag)
        let bounds = customRange ?? range(scope: scope)
        let today = day(now)
        let matches = candidates.filter { task in
            // An explicit calendar range always takes precedence over a preset.
            if customRange != nil { return task.completed == completed && task.dueDate.map(bounds.contains) == true }
            switch scope {
            case "all": return task.completed == completed
            case "done": return task.completed
            case "overdue": return !task.completed && task.dueDate.map { $0 < today } == true
            case "undated": return !task.completed && task.dueDate == nil
            default: return task.completed == completed && task.dueDate.map(bounds.contains) == true
            }
        }
        return result(matches, within: candidates, newestFirst: (customRange == nil && scope == "done") || completed)
    }

    /// Today is an agenda: overdue + today, with tomorrow...today+7 and completed
    /// folded separately. Its completed section includes tasks due today OR
    /// completed/updated today, including undated and early-completed tasks.
    public func todaySections(groupID: String? = nil, tag: String? = nil) -> TaskTodaySections {
        let candidates = candidates(groupID: groupID, tag: tag)
        let today = day(now)
        let upcoming = TaskDateRange(day(calendar.date(byAdding: .day, value: 1, to: now)!), day(calendar.date(byAdding: .day, value: 7, to: now)!))
        let done = candidates.filter { $0.completed && ($0.dueDate == today || timestamp($0.updatedAt).map(day) == today) }
        return TaskTodaySections(overdue: filter(scope: "overdue", groupID: groupID, tag: tag),
                                 today: filter(scope: "today", groupID: groupID, tag: tag),
                                 upcoming: filter(scope: "today", groupID: groupID, tag: tag, customRange: upcoming),
                                 completed: result(done, within: candidates, newestFirst: true))
    }
}
