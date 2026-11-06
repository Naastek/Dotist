import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

/// A draft never reads any previous editor's buffer. Tab changes only its
/// parent; an empty draft is discarded by commit/blur/Escape.
enum TaskDraftFlow {
    static func parent(reverse: Bool, current: String?, after task: DotistTask, tasks: [DotistTask]) -> String? {
        let hierarchy = TaskHierarchy(tasks)
        if reverse { return current.flatMap { id in tasks.first { $0.id == id }?.parentId } }
        let currentDepth = current.map { hierarchy.depth(of: $0) + 1 } ?? 0
        let wanted = min(currentDepth + 1, hierarchy.depth(of: task.id) + 1, DotistTask.maxDepth)
        guard wanted > currentDepth else { return current }
        return ([task] + hierarchy.ancestors(of: task.id)).first { hierarchy.depth(of: $0.id) == wanted - 1 }?.id ?? current
    }
    static func titleToSave(_ text: String) -> String? {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}

