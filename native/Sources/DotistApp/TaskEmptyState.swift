import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

/// Display copy and creation defaults share the exact filter semantics. No UI or
/// clock dependency: tests supply a date/calendar, including the system week start.
struct TaskEmptyState: Equatable {
    let title: String
    let hint: String?
    let allowsAdding: Bool
    let groupID: String
    let dueDate: String?
    static let addTitle = "添加任务"
    static let addAccessibilityLabel = "在这里添加任务"

    init(scope: String, groupID: String?, customRange: TaskDateRange? = nil,
         now: Date = Date(), calendar: Calendar = .current) {
        self.groupID = groupID ?? DotistGroup.inboxID
        allowsAdding = customRange != nil || !["done", "overdue"].contains(scope)
        hint = allowsAdding ? "写下一件小事，或在下方输入栏添加。" : nil
        if customRange != nil { title = "这个日期范围内没有任务" }
        else {
            switch scope {
            case "today": title = "今天没有安排"
            case "tomorrow": title = "明天没有任务"
            case "week": title = "本周没有任务"
            case "nextweek": title = "下周没有任务"
            case "next7": title = "未来 7 天没有任务"
            case "overdue": title = "没有已逾期的任务"
            case "undated": title = "没有无日期的任务"
            case "done": title = "还没有已完成的任务"
            default: title = groupID == nil ? "这里什么都没有" : "这个分组还没有任务"
            }
        }
        if let customRange { dueDate = customRange.start }
        else if ["today", "tomorrow", "week", "nextweek", "next7"].contains(scope) {
            dueDate = TaskFiltering([], now: now, calendar: calendar).range(scope: scope).start
        } else { dueDate = nil }
    }
}

/// Position the complete empty-state block at 38% of the list viewport. Layout
/// owns placement; text and native editors retain the optical centering wrappers.
struct TaskEmptyStateLayout: Layout {
    var viewportHeight: CGFloat? = nil
    var minimumTop: CGFloat = 0
    static func top(height: CGFloat, contentHeight: CGFloat, minimumTop: CGFloat = 0) -> CGFloat {
        max(minimumTop, min(height - contentHeight, height * 0.38 - contentHeight / 2))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 332
        let content = subviews[0].sizeThatFits(.init(width: width, height: nil))
        // Only an explicit empty-state viewport can reserve height. An incidental
        // proposal from a stack must not turn this into a vertically flexible row.
        return CGSize(width: width, height: max(content.height + minimumTop, viewportHeight ?? 0))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let content = subviews[0].sizeThatFits(.init(width: bounds.width, height: nil))
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + Self.top(height: bounds.height, contentHeight: content.height, minimumTop: minimumTop)),
                          proposal: .init(width: bounds.width, height: content.height))
    }
}

