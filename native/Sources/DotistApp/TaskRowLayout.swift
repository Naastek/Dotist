import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

/// Three independent columns: the title owns the height and the circle is
/// centered on that whole block, including wrapped lines and inline tags.
struct TaskRowLayout: Layout {
    let depth: Int
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 332
        let title = subviews[1].sizeThatFits(.init(width: titleWidth(width, subviews), height: nil))
        return CGSize(width: width, height: TaskRowMetrics.height(depth, titleHeight: title.height))
    }
    private func titleWidth(_ width: CGFloat, _ subviews: Subviews) -> CGFloat {
        // Metadata is never compressed by the title, including at depth four.
        let meta = subviews[2].sizeThatFits(.unspecified).width
        return max(1, width - (TaskRowMetrics.textX(depth) - TaskRowMetrics.inset) - (meta > 0 ? meta + 8 : 0))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let titleWidth = titleWidth(bounds.width, subviews)
        let title = subviews[1].sizeThatFits(.init(width: titleWidth, height: nil))
        let circle = TaskRowMetrics.diameter(depth)
        subviews[0].place(at: CGPoint(x: bounds.minX + TaskRowMetrics.circleX(depth) - TaskRowMetrics.inset, y: bounds.midY - circle / 2), proposal: .init(width: circle, height: circle))
        subviews[1].place(at: CGPoint(x: bounds.minX + TaskRowMetrics.textX(depth) - TaskRowMetrics.inset, y: bounds.midY - title.height / 2), proposal: .init(width: titleWidth, height: title.height))
        let metadata = subviews[2].sizeThatFits(.unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX - metadata.width, y: bounds.midY - metadata.height / 2), proposal: .init(width: metadata.width, height: metadata.height))
        if subviews.count > 3 {
            let actions = subviews[3].sizeThatFits(.unspecified)
            let frame = TaskRowActionMetrics.frame(row: bounds, metadataWidth: metadata.width, actionWidth: actions.width)
            subviews[3].place(at: frame.origin, proposal: .init(width: frame.width, height: frame.height))
        }
    }
}

