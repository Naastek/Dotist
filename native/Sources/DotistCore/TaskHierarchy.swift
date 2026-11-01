import Foundation

/// A snapshot index shared by the store and UI. Traversals also tolerate orphaned
/// or cyclic legacy data so a malformed family cannot hide unrelated tasks.
public struct TaskHierarchy: Sendable {
    private let tasks: [DotistTask]
    private let byID: [String: DotistTask]
    private let byParent: [String: [DotistTask]]

    public init(_ tasks: [DotistTask]) {
        self.tasks = tasks
        byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        byParent = Dictionary(grouping: tasks.filter { $0.parentId != nil }, by: { $0.parentId! })
            .mapValues { $0.sorted(by: Self.ordered) }
    }

    private static func ordered(_ a: DotistTask, _ b: DotistTask) -> Bool {
        a.position == b.position ? a.id < b.id : a.position < b.position
    }

    public func children(of id: String) -> [DotistTask] { byParent[id] ?? [] }

    public func ancestors(of id: String) -> [DotistTask] {
        var result: [DotistTask] = []
        var seen: Set<String> = [id]
        var parentID = byID[id]?.parentId
        while let next = parentID, let parent = byID[next], seen.insert(next).inserted {
            result.append(parent)
            parentID = parent.parentId
        }
        return result
    }

    public func depth(of id: String) -> Int { ancestors(of: id).count }

    public func descendants(of id: String) -> [DotistTask] {
        var result: [DotistTask] = []
        var seen: Set<String> = [id]
        var stack = Array(children(of: id).reversed())
        while let task = stack.popLast() {
            guard seen.insert(task.id).inserted else { continue }
            result.append(task)
            stack.append(contentsOf: children(of: task.id).reversed())
        }
        return result
    }

    /// Height in edges, so a leaf has height zero, including when collapsed in UI.
    public func subtreeHeight(of id: String) -> Int {
        var height = 0
        var seen: Set<String> = [id]
        var stack = children(of: id).map { ($0, 1) }
        while let (task, level) = stack.popLast() {
            guard seen.insert(task.id).inserted else { continue }
            height = max(height, level)
            stack.append(contentsOf: children(of: task.id).map { ($0, level + 1) })
        }
        return height
    }

    /// Preorder in group/manual order, including collapsed descendants. Every
    /// identity is returned exactly once, even if its parent is missing.
    public func outline(groupIDs: [String] = []) -> [DotistTask] {
        let ranks = Dictionary(groupIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let sorted = tasks.sorted {
            if $0.category != $1.category {
                let a = ranks[$0.category] ?? Int.max, b = ranks[$1.category] ?? Int.max
                return a == b ? $0.category < $1.category : a < b
            }
            return Self.ordered($0, $1)
        }
        let roots = sorted.filter { $0.parentId == nil || byID[$0.parentId!] == nil }
        var result: [DotistTask] = []
        var seen: Set<String> = []
        for root in roots + sorted where !seen.contains(root.id) {
            for task in [root] + descendants(of: root.id) where seen.insert(task.id).inserted {
                result.append(task)
            }
        }
        return result
    }

    /// A selected ancestor carries its descendants; do not move them twice.
    public func selectionRoots(ids: [String], groupIDs: [String] = []) -> [DotistTask] {
        let selected = Set(ids)
        return outline(groupIDs: groupIDs).filter { task in
            selected.contains(task.id) && !ancestors(of: task.id).contains { selected.contains($0.id) }
        }
    }
}
