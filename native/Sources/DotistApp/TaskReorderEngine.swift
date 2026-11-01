import Foundation

/// Geometry is in one list coordinate space. Row midpoints and group bounds are
/// current on-screen positions, including any open placeholder gap.
enum TaskReorderEngine {
    struct Row: Equatable {
        let id: String
        let level: Int
        let groupID: String
        let parentID: String?
        let midY: Double
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

    static func target(rows: [Row], groups: [Group], draggedID: String, blockIDs: Set<String>, startY: Double, offsetY: Double, offsetX: Double, indentStep: Double = 22) -> Target? {
        guard let head = rows.first(where: { $0.id == draggedID }), blockIDs.contains(draggedID),
              !groups.isEmpty, indentStep > 0, startY.isFinite, offsetY.isFinite, offsetX.isFinite else { return nil }
        let y = startY + offsetY
        let group = groups.first(where: { y >= $0.minY && y < $0.maxY })
            ?? groups.min { lhs, rhs in
                max(lhs.minY - y, y - lhs.maxY, 0) < max(rhs.minY - y, y - rhs.maxY, 0)
            }!
        let rest = rows.filter { $0.groupID == group.id && !blockIDs.contains($0.id) }
        var slot = rest.prefix { $0.midY < y }.count
        let carriesChildren = blockIDs.count > 1
        var level = head.level == 1 ? 1 : 0
        if offsetX > indentStep * 0.7 { level = 1 }
        if offsetX < -indentStep * 0.7 { level = 0 }
        if carriesChildren { level = 0 }
        var parentID: String?
        if level == 1, slot > 0 {
            let preceding = rest[slot - 1]
            parentID = preceding.level == 0 ? preceding.id : preceding.parentID
        }
        if parentID == nil { level = 0 }
        // A top-level block cannot split another parent's visible subtree.
        if level == 0 {
            while slot < rest.count && rest[slot].level == 1 { slot += 1 }
        }
        let beforeID = rest.dropFirst(slot).first { $0.level == level && (level == 0 || $0.parentID == parentID) }?.id
        return Target(groupID: group.id, slot: slot, level: level, parentID: parentID, beforeID: beforeID)
    }
}
