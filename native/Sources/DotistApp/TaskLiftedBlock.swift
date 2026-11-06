import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

enum TaskLiftedSurfaceMetrics {
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 4
}

/// Only this layer observes pointer frames; the list reads slot and level only.
struct TaskLiftedBlock<Content: View>: View {
    static var height: CGFloat { 32 }
    let drag: TaskListDrag
    @ObservedObject var motion: TaskDragMotion
    @ViewBuilder let content: (TaskListRowFrame) -> Content
    var body: some View {
        if let row = drag.visibleBlock.first(where: { $0.task.id == drag.taskID }) {
            content(row).frame(height: Self.height).clipped()
                .overlay(alignment: .trailing) {
                    if drag.blockIDs.count > 1 {
                        Text("+\(drag.blockIDs.count - 1)").font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).background(.regularMaterial, in: Capsule())
                    }
                }
                .frame(width: drag.startFrame.width, height: Self.height)
                .background {
                    TransientGlassMaterial(cornerRadius: 12)
                        .padding(.horizontal, -TaskLiftedSurfaceMetrics.horizontalInset)
                        .padding(.vertical, -TaskLiftedSurfaceMetrics.verticalInset)
                }
                .offset(x: drag.startFrame.minX + motion.location.x - drag.startLocation.x,
                        y: motion.location.y - min(max(drag.startLocation.y - drag.startFrame.minY, 0), Self.height))
                .allowsHitTesting(false).accessibilityHidden(true)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
        }
    }
}

