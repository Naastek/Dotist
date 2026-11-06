import AppKit
import CoreText
import DotistCore
import SwiftUI

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
        // A selected empty group must not borrow the global next task's title.
        let emptyTitle = groupID.map { model.groupDisplayName($0) } ?? Self.clean(fallbackTitle) ?? model.bubbleTitle
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

