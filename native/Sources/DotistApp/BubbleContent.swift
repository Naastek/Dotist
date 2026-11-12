import AppKit
import CoreText
import DotistCore
import SwiftUI

enum BubbleLayout {
    static let circle: CGFloat = 48
    static let textGap: CGFloat = 18
    static let outerMargin: CGFloat = 20
    static let widthBudget = circle + textGap + outerMargin
    static let filterGap: CGFloat = 4
    static let filterBudget = filterGap + outerMargin
}

/// One source for the strip's task, metadata, count and measured width. Group identity
/// is an ID, never a display name (names can be empty, duplicated or renamed).
@MainActor
struct BubbleContent {
    let task: DotistTask?
    let title: String
    let group: String?
    let due: String?
    let remaining: Int
    var subtitle: String { [group, due].compactMap { $0 }.joined(separator: " · ") }

    init(model: AppModel, groupID: String? = nil, fallbackTitle: String? = nil, state: TaskPanelState? = nil) {
        if QAPerf.enabled { QAPerf.count(.bubbleContent) }
        var open = model.topLevelTasks.filter { $0.parentId == nil && !$0.completed && (groupID == nil || $0.category == groupID) }
        var next = groupID == nil ? model.nextTask : model.ordered(open).first
        var filteredEmpty = false
        // The bubble counts what the panel shows when a date or tag filter is active.
        if let state, state.scope != "done", state.dateFilterActive || state.activeTag != nil {
            let range = state.customStart.map { TaskDateRange($0, state.customEnd ?? $0) }
            let matches = model.ordered(model.filteredTasks(scope: state.scope, groupID: groupID, tag: state.activeTag, customRange: range).matches)
            open = matches
            next = matches.first
            filteredEmpty = matches.isEmpty
        }
        task = next
        remaining = open.count
        // The selected group already appears in the strip's filter context. An empty
        // group needs a status, not a second copy of its name (or the global next task).
        let emptyTitle: String
        if let groupID, next == nil {
            let hasTasks = model.topLevelTasks.contains { $0.category == groupID }
            emptyTitle = model.text(hasTasks ? "今天的事都做完了" : "这个分组还没有任务")
        } else {
            emptyTitle = Self.clean(fallbackTitle) ?? model.bubbleTitle
        }
        title = filteredEmpty ? model.text("没有符合筛选的任务") : Self.clean(next?.title) ?? (next == nil ? emptyTitle : model.text("未命名任务"))
        group = next.flatMap { model.group(for: $0) }.flatMap { Self.clean($0.name) }
        due = next?.dueDate.flatMap(Self.clean).flatMap { Self.clean(model.dueLabel($0)) }
    }

    static func clean(_ value: String?) -> String? {
        let text = value?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return text.isEmpty ? nil : text
    }

    func textWidth(language: String) -> CGFloat {
        let titleWidth = (title as NSString).size(withAttributes: [.font: DotistDesign.nativeFont(13, weight: .medium, language: language)]).width
        let groupWidth = ((group ?? "") as NSString).size(withAttributes: [.font: DotistDesign.nativeFont(12, weight: .semibold, serif: true, language: language)]).width
        let detail = (group != nil && due != nil ? " · " : "") + (due ?? "")
        let detailWidth = (detail as NSString).size(withAttributes: [.font: DotistDesign.nativeFont(12, language: language)]).width
        return max(titleWidth, groupWidth + detailWidth)
    }
}


/// Retained by the panel view across geometry-only updates.
@MainActor
final class BubbleContentCache {
    private struct Key: Equatable {
        let tasks: [DotistTask], groups: [DotistGroup], settings: DotistSettings
        let groupID: String?, scope: String, tag: String?, start: String?, end: String?, title: String
        let language: String, minute: Int
    }
    private var key: Key?
    private var value: BubbleContent?
    private(set) var buildCount = 0
    func content(model: AppModel, state: TaskPanelState, title: String) -> BubbleContent {
        let next = Key(tasks: model.tasks, groups: model.groups, settings: model.settings,
                       groupID: state.groupID, scope: state.scope, tag: state.activeTag,
                       start: state.customStart, end: state.customEnd, title: title, language: model.language,
                       minute: Int(Date().timeIntervalSinceReferenceDate / 60))
        if key == next, let value { return value }
        buildCount += 1
        let result = BubbleContent(model: model, groupID: state.groupID, fallbackTitle: title, state: state)
        key = next; value = result
        return result
    }
}
