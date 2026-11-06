import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

enum TaskDragBatch {
    /// Preflight every selected subtree before the first write. Core owns each
    /// subtree transaction; this adapter preserves displayed selection order.
    static func commit(ids: [String], target: TaskReorderEngine.Target, store: TaskStore) throws {
        let tasks = try store.listTasks()
        let hierarchy = TaskHierarchy(tasks)
        let carried = Set(ids.flatMap { [$0] + hierarchy.descendants(of: $0).map(\.id) })
        if let parent = target.parentID, carried.contains(parent) { throw TaskStoreError("不能将任务移到自己或自己的后代下面") }
        if let before = target.beforeID, carried.contains(before) { throw TaskStoreError("找不到任务") }
        let parentDepth = target.parentID.map { hierarchy.depth(of: $0) + 1 } ?? 0
        for id in ids {
            guard tasks.contains(where: { $0.id == id }) else { throw TaskStoreError("找不到任务") }
            guard parentDepth + hierarchy.subtreeHeight(of: id) <= DotistTask.maxDepth else { throw TaskStoreError("最多支持 5 层任务") }
        }
        for id in ids { try store.commitReorder(id, groupID: target.groupID, parentID: target.parentID, beforeID: target.beforeID) }
    }
}

