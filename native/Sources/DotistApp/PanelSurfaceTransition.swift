import AppKit
import CoreText
import DotistCore
import SwiftUI

/// Insets interpolate along actual window anchors, not elapsed time. A clipped
/// stationary anchor uses the other moving edges; an entirely stationary rect
/// has no geometric progress and resolves directly to its endpoint padding.
struct PanelSurfaceTransition {
    let start: NSRect
    let target: NSRect
    let from: EdgeInsets
    let to: EdgeInsets
    let onRight: Bool

    func insets(at frame: NSRect) -> EdgeInsets {
        let a = [start.minX, start.maxX, start.minY, start.maxY]
        let b = [target.minX, target.maxX, target.minY, target.maxY]
        let c = [frame.minX, frame.maxX, frame.minY, frame.maxY]
        var dot: CGFloat = 0, length: CGFloat = 0
        for i in a.indices { dot += (c[i] - a[i]) * (b[i] - a[i]); length += (b[i] - a[i]) * (b[i] - a[i]) }
        let fallback = length > 0 ? min(1, max(0, dot / length)) : 1
        func progress(_ index: Int) -> CGFloat {
            let distance = b[index] - a[index]
            return distance == 0 ? fallback : min(1, max(0, (c[index] - a[index]) / distance))
        }
        let x = progress(onRight ? 1 : 0), y = progress(3)
        func mix(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * p }
        return EdgeInsets(top: mix(from.top, to.top, y), leading: mix(from.leading, to.leading, x),
                          bottom: mix(from.bottom, to.bottom, y), trailing: mix(from.trailing, to.trailing, x))
    }
}

