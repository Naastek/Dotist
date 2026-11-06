import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

struct TaskProgressSegments {
    static func values(completed: [Bool]) -> [Bool] {
        guard completed.count > 12 else { return completed }
        let done = Int((Double(completed.filter { $0 }.count) / Double(completed.count) * 12).rounded())
        return (0..<12).map { $0 < done }
    }
}

struct TaskCheckmark: View {
    let depth: Int
    let completed: Bool
    let children: [Bool]
    let emphasized: Bool
    var body: some View {
        ZStack {
            if completed {
                Circle().fill(DotistDesign.accent)
                OpticalSymbol(name: "checkmark", size: depth == 0 ? 9 : 7.5, weight: .heavy).foregroundStyle(DotistDesign.paper)
            } else if children.isEmpty {
                Circle().strokeBorder(emphasized ? DotistDesign.accent : DotistDesign.checkStroke, lineWidth: 1.25)
            } else {
                let segments = TaskProgressSegments.values(completed: children)
                ForEach(segments.indices, id: \.self) { index in
                    let step = 360.0 / Double(segments.count)
                    let gap = segments.count == 1 ? 0.0 : 8.0
                    Circle().inset(by: 0.625)
                        .trim(from: (Double(index) * step + gap / 2) / 360, to: (Double(index + 1) * step - gap / 2) / 360)
                        .stroke(segments[index] ? DotistDesign.accent : emphasized ? DotistDesign.accent.opacity(0.5) : DotistDesign.checkStroke, lineWidth: 1.25)
                        .rotationEffect(.degrees(-90))
                }
            }
        }.frame(width: TaskRowMetrics.diameter(depth), height: TaskRowMetrics.diameter(depth))
            // A ring has no fill to hit-test; without this the tap falls through to row editing.
            .contentShape(Circle())
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.18), value: completed)
    }
}

@MainActor final class TaskDragMotion: ObservableObject {
    @Published var location = CGPoint.zero
}

