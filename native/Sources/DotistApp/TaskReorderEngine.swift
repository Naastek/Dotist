import Foundation
import DotistCore

/// Geometry is in one list coordinate space. Row midpoints and group bounds are
/// current on-screen positions, including any open placeholder gap.
enum TaskReorderEngine {
    struct Row: Equatable {
        let id: String
        let level: Int
        let groupID: String
        let parentID: String?
        let midY: Double
        var depth: Int { level }

        init(id: String, level: Int, groupID: String, parentID: String?, midY: Double) {
            self.id = id; self.level = level; self.groupID = groupID; self.parentID = parentID; self.midY = midY
        }
        init(id: String, depth: Int, groupID: String, parentID: String?, midY: Double) {
            self.init(id: id, level: depth, groupID: groupID, parentID: parentID, midY: midY)
        }
    }
    struct Group: Equatable {
        let id: String
        let minY: Double
        let maxY: Double
    }
    struct Target: Equatable {
        let groupID: String
        /// Index among visible rows in this group after removing the dragged block.
        let slot: Int
        let level: Int
        let parentID: String?
        /// Next visible sibling, or nil to append. Used as a transactional anchor.
        let beforeID: String?
    }

    /// Each additional level crosses the 70% point of its indent step.
    static func levelSteps(_ offsetX: Double, indentStep: Double) -> Int {
        guard offsetX.isFinite, indentStep.isFinite, indentStep > 0 else { return 0 }
        let distance = abs(offsetX) / indentStep
        guard distance >= 0.7 else { return 0 }
        let steps = Int(min(floor(distance - 0.7) + 1, Double(DotistTask.maxDepth + 1)))
        return offsetX < 0 ? -steps : steps
    }

    /// Supply the model's subtree height to include collapsed descendants. The
    /// fallback derives height from known block rows for existing callers.
    static func target(rows: [Row], groups: [Group], draggedID: String, blockIDs: Set<String>, startY: Double, offsetY: Double, offsetX: Double, indentStep: Double = 22, subtreeHeight: Int? = nil) -> Target? {
        guard let head = rows.first(where: { $0.id == draggedID }), blockIDs.contains(draggedID),
              !groups.isEmpty, indentStep.isFinite, indentStep > 0, startY.isFinite, offsetY.isFinite, offsetX.isFinite,
              (0...DotistTask.maxDepth).contains(head.level) else { return nil }
        let y = startY + offsetY
        guard y.isFinite else { return nil }
        let group = groups.first(where: { y >= $0.minY && y < $0.maxY })
            ?? groups.min { lhs, rhs in
                max(lhs.minY - y, y - lhs.maxY, 0) < max(rhs.minY - y, y - rhs.maxY, 0)
            }!
        let rest = rows.filter { $0.groupID == group.id && !blockIDs.contains($0.id) }
        var slot = rest.prefix { $0.midY < y }.count
        let visibleHeight = rows.filter { blockIDs.contains($0.id) }.map { $0.level - head.level }.max() ?? 0
        let height = subtreeHeight ?? max(visibleHeight, blockIDs.count > 1 ? 1 : 0)
        guard (0...DotistTask.maxDepth).contains(height) else { return nil }
        let prevDepth = slot > 0 ? rest[slot - 1].level : -1
        let maximum = max(0, min(prevDepth + 1, DotistTask.maxDepth - height))
        var level = min(max(head.level + levelSteps(offsetX, indentStep: indentStep), 0), maximum)
        var parentID: String?
        if level > 0 {
            parentID = rest.prefix(slot).last(where: { $0.level == level - 1 })?.id
            // A filtered list may omit the ancestor's own row.
            if parentID == nil, slot > 0, rest[slot - 1].level == level {
                parentID = rest[slot - 1].parentID
            }
        }
        if parentID == nil { level = 0 }
        // A block must land after all descendants of its preceding sibling.
        while slot < rest.count && rest[slot].level > level { slot += 1 }
        let beforeID = rest.dropFirst(slot).prefix { $0.level >= level }.first { $0.level == level && $0.parentID == parentID }?.id
        return Target(groupID: group.id, slot: slot, level: level, parentID: parentID, beforeID: beforeID)
    }
}
