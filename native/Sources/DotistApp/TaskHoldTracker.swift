import AppKit
import Combine
import DotistCore
import SwiftUI

/// Non-observable bookkeeping for press-and-hold lift, so pointer updates never re-render the list.
final class TaskHoldTracker {
    static let duration = 0.3
    var pointer = CGPoint.zero
    var lifted = false
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
