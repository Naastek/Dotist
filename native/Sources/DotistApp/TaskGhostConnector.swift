import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

struct TaskGhostConnector: Shape {
    var start: CGPoint
    var end: CGPoint
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(start.x, start.y), .init(end.x, end.y)) }
        set { start = .init(x: newValue.first.first, y: newValue.first.second); end = .init(x: newValue.second.first, y: newValue.second.second) }
    }
    func path(in rect: CGRect) -> Path {
        guard end.y > start.y, end.x > start.x else { return Path() }
        let radius = min(4, (end.y - start.y) / 2, (end.x - start.x) / 2)
        return Path { path in
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x, y: end.y - radius))
            path.addQuadCurve(to: CGPoint(x: start.x + radius, y: end.y), control: CGPoint(x: start.x, y: end.y))
            path.addLine(to: end)
        }
    }
}

