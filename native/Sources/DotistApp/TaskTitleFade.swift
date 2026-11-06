import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

/// Erases only title glyphs behind the floating row actions. It never paints
/// paper over the panel tint, and leaves the transparent title hit region intact.
struct TaskTitleFade: View {
    let trailing: CGFloat
    var rowRight: CGFloat? = nil
    var coordinateSpace: String = "dotist-task-list"
    var body: some View {
        GeometryReader { geometry in
            let title = geometry.frame(in: .named(coordinateSpace))
            let metadata = rowRight.map { max(0, $0 - title.maxX - 8) } ?? 0
            let rawEnd = max(0, rowRight.map { $0 - TaskRowActionMetrics.rightInset(metadataWidth: metadata) - trailing - title.minX } ?? (geometry.size.width - trailing))
            let end = min(geometry.size.width, rawEnd)
            let start = max(0, end - 24)
            let width = max(1, geometry.size.width)
            LinearGradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: start / width),
                .init(color: .clear, location: end / width),
                .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        }
    }
}

