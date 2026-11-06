import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

/// Panel coordinates, shared by live rows, editors and drag placeholders.
enum TaskRowMetrics {
    static let inset: CGFloat = 16
    static let indent: CGFloat = 22
    static func textX(_ depth: Int) -> CGFloat { 42 + indent * CGFloat(depth) }
    static func circleX(_ depth: Int) -> CGFloat { depth == 0 ? inset : textX(depth - 1) }
    static func diameter(_ depth: Int) -> CGFloat { depth == 0 ? 16 : 13 }
    static func height(_ depth: Int, titleHeight: CGFloat) -> CGFloat { max(depth == 0 ? 32 : 28, titleHeight) }
    static func circleFrame(_ depth: Int, titleHeight: CGFloat) -> CGRect {
        let size = diameter(depth)
        return CGRect(x: circleX(depth), y: (height(depth, titleHeight: titleHeight) - size) / 2, width: size, height: size)
    }
}

/// Action hit boxes share a fixed right edge, independent of metadata length.
enum TaskRowActionMetrics {
    /// Actions sit against metadata when there is some, otherwise at the row edge.
    static func rightInset(metadataWidth: CGFloat) -> CGFloat {
        metadataWidth > 0 ? metadataWidth + 8 : 0
    }
    static func width(count: Int) -> CGFloat { CGFloat(count * 22 + max(0, count - 1)) }
    static func frame(row: CGRect, metadataWidth: CGFloat, actionWidth: CGFloat) -> CGRect {
        CGRect(x: row.maxX - rightInset(metadataWidth: metadataWidth) - actionWidth,
               y: row.midY - 11, width: actionWidth, height: 22)
    }
}

enum TaskRowBackgroundState: Equatable {
    case idle, hovered, selected, editing
    init(hovered: Bool, selected: Bool, editing: Bool, dragging: Bool, carried: Bool = false) {
        if carried { self = .idle }
        else if editing { self = .editing }
        else if selected { self = .selected }
        else if hovered && !dragging { self = .hovered }
        else { self = .idle }
    }
    var opacity: Double {
        switch self { case .idle: 0; case .hovered: 0.10; case .selected: 0.16; case .editing: 0.18 }
    }
}

enum TaskDateFilterMetrics {
    static let rowHeight: CGFloat = 34
    static func opacity(distance: Int, hovered: Bool = false, focused: Bool = false,
                        increasedContrast: Bool = false, voiceOver: Bool = false) -> Double {
        guard !increasedContrast && !voiceOver && !focused else { return 1 }
        let values = [1.0, 0.78, 0.58, 0.42, 0.32]
        let value = values[min(max(distance, 0), 4)]
        return hovered ? max(0.9, value) : value
    }
    static func distance(of id: String, selected: String?, in filters: [String]) -> Int {
        guard let selected, let anchor = filters.firstIndex(of: selected), let index = filters.firstIndex(of: id) else { return 0 }
        return abs(index - anchor)
    }
    static func size(selected: Bool) -> CGFloat { selected ? 17 : 14 }
    static func weight(selected: Bool) -> NSFont.Weight { selected ? .medium : .regular }
    static func slotWidth(title: String, language: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: DotistDesign.nativeFont(17, weight: .medium, language: language)]).width)
    }
}

