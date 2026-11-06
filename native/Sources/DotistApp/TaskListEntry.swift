import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

/// A flat, stable identity for every row and heading. Decorations do not count
/// toward the drop slot; visible headings do, just like ordinary rows in Tic.
struct TaskListEntry: Identifiable {
    let id: String
    var expanded = true
    var row: TaskListRowFrame? = nil
    var group: TaskListGroupFrame? = nil
    var content = AnyView(EmptyView())

    static func insertionIndex(_ slot: TaskInsertionSlot, in entries: [TaskListEntry]) -> Int {
        switch slot {
        case .before(let id, let region):
            return entries.firstIndex { $0.row?.task.id == id && $0.row?.region == region } ?? entries.count
        case .after(let id, let region):
            return entries.firstIndex { $0.row?.task.id == id && $0.row?.region == region }.map { $0 + 1 } ?? entries.count
        case .empty(let region):
            // An opening group may still have paint-only retained rows. An
            // empty interactive slot means append, matching the store target.
            return entries.lastIndex { $0.row?.region == region || $0.group?.region == region }.map { $0 + 1 } ?? entries.count
        }
    }
}

struct TaskGhostFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let next = nextValue(); if next != .zero { value = next } }
}

struct TaskSectionHeadingKey: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value.append(contentsOf: nextValue()) }
}
