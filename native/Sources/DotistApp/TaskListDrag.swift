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

/// Pure rules for cross-section drops in date-filtered task lists.
enum TaskDropSection {
    static func sectionKey(of region: String) -> String? {
        guard let colon = region.firstIndex(of: ":") else { return nil }
        return String(region[..<colon])
    }

    static func isCompletedSection(_ section: String?) -> Bool {
        section == "completed" || section == "done"
    }

    /// Returns whether dropping from `sourceRegion` into `destinationRegion`
    /// is allowed, and the due date (`YYYY-MM-DD`) to write on commit (`nil` preserves existing date).
    static func resolve(sourceRegion: String, destinationRegion: String, destinationDate: String?) -> (allowed: Bool, dueDate: String?) {
        guard let srcSection = sectionKey(of: sourceRegion),
              let dstSection = sectionKey(of: destinationRegion) else {
            return (true, nil)
        }
        if srcSection == dstSection {
            return (true, nil)
        }
        if isCompletedSection(srcSection) || isCompletedSection(dstSection) {
            return (false, nil)
        }
        guard let destinationDate else {
            return (false, nil)
        }
        return (true, destinationDate)
    }

    /// Evaluates every carried root region so a multi-date or mixed-completion
    /// selection only commits when all roots are valid, and applies `destinationDate`
    /// whenever any selected root crosses into a different date section.
    static func resolve(sourceRegions: [String], destinationRegion: String, destinationDate: String?) -> (allowed: Bool, dueDate: String?) {
        guard !sourceRegions.isEmpty else { return (true, nil) }
        var resolvedDate: String? = nil
        for sourceRegion in sourceRegions {
            let outcome = resolve(sourceRegion: sourceRegion, destinationRegion: destinationRegion, destinationDate: destinationDate)
            guard outcome.allowed else { return (false, nil) }
            if let date = outcome.dueDate { resolvedDate = date }
        }
        return (true, resolvedDate)
    }
}

