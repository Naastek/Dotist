import AppKit
import Combine
import DotistCore
import SwiftUI

/// Non-observable bookkeeping for press-and-hold lift, so pointer updates never re-render the list.
final class TaskHoldTracker {
    static let duration = 0.3
    var pointer = CGPoint.zero
    var lifted = false
    /// True while the active mouse-down press began inside a TaskTextView text hit zone.
    var pointerInsideEditor = false
    /// Task ID whose inline editing was just dismissed on the current mouse-down, so the
    /// matching mouse-up tap does not immediately re-enter editing on the same row.
    var dismissedEditingTaskID: String?
    private var releasedAt: TimeInterval?
    /// The mouse-up that ends a hold must not also count as a click-to-edit.
    var suppressesClick: Bool {
        if lifted { return true }
        guard let releasedAt else { return false }
        return ProcessInfo.processInfo.systemUptime - releasedAt < 0.3
    }
    func finish() {
        guard lifted else { return }
        lifted = false
        releasedAt = ProcessInfo.processInfo.systemUptime
    }
}
