import AppKit
import Combine
import DotistCore
import SwiftUI

#if DEBUG
/// A transparent layout anchor lets panel fixtures read the actual bar box;
/// AX encloses accessible content rather than this bar's complete padding.
struct ComposerBarLayoutAnchor: NSViewRepresentable {
    final class Box: NSView {
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Box { Box() }
    func updateNSView(_ view: Box, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Box, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
#endif
