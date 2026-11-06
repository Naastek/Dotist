import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

/// Toolbar buttons are 28pt wide with 4pt spacing. The dragged icon follows
/// the pointer; only neighbors between its original and target slots move.
enum ToolbarDragLayout {
    static let step: CGFloat = 32
    static func targetIndex(from source: Int, translation: CGFloat, count: Int) -> Int {
        guard count > 0, translation.isFinite else { return source }
        let displacement = (translation / step).rounded()
        return Int(min(CGFloat(count - 1), max(0, CGFloat(source) + displacement)))
    }
    static func offset(index: Int, source: Int, target: Int, translation: CGFloat) -> CGFloat {
        if index == source { return translation }
        if source < target && index > source && index <= target { return -step }
        if target < source && index >= target && index < source { return step }
        return 0
    }
}

struct ToolbarDragSession {
    let item: ToolbarItem
    let items: [ToolbarItem]
    var translation: CGFloat = 0
    var source: Int { items.firstIndex(of: item) ?? 0 }
    var target: Int { ToolbarDragLayout.targetIndex(from: source, translation: translation, count: items.count) }
    func offset(for item: ToolbarItem) -> CGFloat {
        guard let index = items.firstIndex(of: item) else { return 0 }
        return ToolbarDragLayout.offset(index: index, source: source, target: target, translation: translation)
    }
}

struct ToolbarFrameKey: PreferenceKey {
    static let defaultValue: [ToolbarItem: CGRect] = [:]
    static func reduce(value: inout [ToolbarItem: CGRect], nextValue: () -> [ToolbarItem: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

