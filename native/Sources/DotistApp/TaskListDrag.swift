import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

struct TaskListDrag {
    let generation = UUID()
    let taskID: String
    let blockIDs: Set<String>
    let visibleBlock: [TaskListRowFrame]
    let startFrame: CGRect
    let startLocation: CGPoint
    /// One semantic destination owns gap feedback and selects the committed row.
    var destination: TaskDropDestination?
    var target: TaskReorderEngine.Target? { destination?.target }
    var committing = false
    var rootIDs: [String] = []
    var sourceDepth = 0
    var subtreeHeight = 0
    var expandedDropGroup: String?
    func carries(_ id: String, region: String) -> Bool {
        visibleBlock.contains { $0.task.id == id && $0.region == region }
    }
}

/// The semantic slot is shared by the one-line placeholder and atomic commit.
struct TaskDropDestination: Equatable {
    let target: TaskReorderEngine.Target
    let region: String
    let slot: TaskInsertionSlot
    let frame: CGRect
    var date: String? = nil
}

