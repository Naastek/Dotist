import AppKit
import SwiftUI

final class FocusSegmentedControl: NSSegmentedControl {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 124, 115, 119:
            let next = event.keyCode == 115 ? 0 : event.keyCode == 119 ? segmentCount - 1 : min(max(selectedSegment + (event.keyCode == 123 ? -1 : 1), 0), segmentCount - 1)
            guard next != selectedSegment else { return }
            selectedSegment = next
            sendAction(action, to: target)
        case 49, 36:
            sendAction(action, to: target)
        default: super.keyDown(with: event)
        }
    }
}
