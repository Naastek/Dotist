import Foundation
import GRDB

public enum TaskTags {
    private static let pattern = try! NSRegularExpression(pattern: #"(^|\s)#([^\s#]+)"#)

    public static func describe(_ tasks: [DotistTask]) -> DotistTagDescription {
        var counts: [String: (open: Int, all: Int)] = [:]
        let values = tasks.map { task in
            let title = task.title as NSString
            var seen: Set<String> = []
            let tags = pattern.matches(in: task.title, range: NSRange(location: 0, length: title.length)).map {
                title.substring(with: $0.range(at: 2))
            }.filter { seen.insert($0).inserted }
            for tag in tags {
                counts[tag, default: (0, 0)].all += 1
                if !task.completed { counts[tag, default: (0, 0)].open += 1 }
            }
            let text = pattern.stringByReplacingMatches(in: task.title, range: NSRange(location: 0, length: title.length), withTemplate: "$1")
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            return DotistTaskTags(id: task.id, text: text.isEmpty ? task.title : text, tags: tags)
        }
        return DotistTagDescription(tasks: values, counts: counts.keys.sorted().map { DotistTagCount(tag: $0, open: counts[$0]!.open, all: counts[$0]!.all) })
    }

    public static func filter(_ tasks: [DotistTask], tag: String, description: DotistTagDescription? = nil) -> [DotistTask] {
        let matches = Set((description ?? describe(tasks)).tasks.filter { $0.tags.contains(tag) }.map(\.id))
        let hierarchy = TaskHierarchy(tasks)
        var family = matches
        for id in matches { family.formUnion(hierarchy.ancestors(of: id).map(\.id)) }
        // Preserve family context from the two-level behavior at every depth.
        for id in family { family.formUnion(hierarchy.descendants(of: id).map(\.id)) }
        return tasks.filter { family.contains($0.id) }
    }
}

extension TaskStore {
    public func describeTags() throws -> DotistTagDescription { TaskTags.describe(try listTasks()) }
    public func filterByTag(_ tag: String) throws -> [DotistTask] { TaskTags.filter(try listTasks(), tag: tag) }

    public func retag(_ tag: String, replacement: String?) throws {
        let replacement = replacement.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "#" }).filter { !$0.isWhitespace }.prefix(24)) }
        if replacement == "" || replacement == tag { return }
        let regex = try NSRegularExpression(pattern: #"(^|\s)#"# + NSRegularExpression.escapedPattern(for: tag) + #"(?=\s|$)"#)
        try database.write { db in
            // Use the same database transaction for the whole rename, including partial-update validation.
            let tasks = try DotistTask.fetchAll(db, sql: "SELECT * FROM tasks WHERE deleted_at IS NULL")
            for task in tasks {
                let range = NSRange(task.title.startIndex..., in: task.title)
                guard regex.firstMatch(in: task.title, range: range) != nil else { continue }
                let template = "$1" + (replacement.map { "#" + NSRegularExpression.escapedTemplate(for: $0) } ?? "")
                let title = regex.stringByReplacingMatches(in: task.title, range: range, withTemplate: template)
                    .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                _ = try Self.validated(title, limit: 500, empty: "任务内容不能为空", long: "任务内容不能超过 500 个字")
                try db.execute(sql: "UPDATE tasks SET title=?,updated_at=?,revision=revision+1 WHERE id=?", arguments: [title, Self.timestamp(), task.id])
                try Self.record(db, Self.task(db, task.id), kind: "update", base: task.revision)
            }
        }
    }
}
