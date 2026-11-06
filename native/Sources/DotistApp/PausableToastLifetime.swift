import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

/// A pure countdown: callers inject monotonic timestamps, so tests need no sleeps.
struct PausableToastLifetime {
    let duration: TimeInterval
    private var remaining: TimeInterval = 0
    private var resumedAt: TimeInterval?
    private var hovered = false

    init(duration: TimeInterval) {
        self.duration = duration
    }

    mutating func restart(at now: TimeInterval) {
        remaining = duration
        resumedAt = hovered ? nil : now
    }
    mutating func setHovered(_ value: Bool, at now: TimeInterval) {
        guard value != hovered else { return }
        if value {
            if let resumedAt { remaining = max(0, remaining - max(0, now - resumedAt)) }
            resumedAt = nil
        } else { resumedAt = now }
        hovered = value
    }
    func isVisible(at now: TimeInterval) -> Bool {
        remaining - (resumedAt.map { max(0, now - $0) } ?? 0) > 0
    }
}

