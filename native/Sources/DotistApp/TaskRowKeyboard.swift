import AppKit
import SwiftUI

/// 行与动作共用原生首响应者；没有包围按钮的 SwiftUI 可聚焦容器。
struct TaskRowKey {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    init?(_ event: NSEvent) {
        switch event.keyCode {
        case 36, 76: key = .return
        case 49: key = .space
        case 48: key = .tab
        case 53: key = .escape
        case 126: key = .upArrow
        case 125: key = .downArrow
        default: return nil
        }
        var flags: EventModifiers = []
        if event.modifierFlags.contains(.shift) { flags.insert(.shift) }
        if event.modifierFlags.contains(.command) { flags.insert(.command) }
        if event.modifierFlags.contains(.option) { flags.insert(.option) }
        if event.modifierFlags.contains(.control) { flags.insert(.control) }
        modifiers = flags
    }
}

struct TaskRowKeyboard: NSViewRepresentable {
    @ObservedObject var selection: TaskRowSelection
    let label: String
    var enabled = true
    let handle: (TaskRowKey) -> KeyPress.Result
    final class Row: NSView {
        weak var selection: TaskRowSelection?
        var handle: ((TaskRowKey) -> KeyPress.Result)?
        var enabled = true
        override var acceptsFirstResponder: Bool { enabled }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func becomeFirstResponder() -> Bool {
            selection?.rowFocused = true
            return true
        }
        override func resignFirstResponder() -> Bool {
            selection?.rowFocused = false
            return true
        }
        override func keyDown(with event: NSEvent) {
            guard enabled else { return }
            if event.keyCode == 124, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                if let button = selection?.buttons.compactMap(\.value).sorted(by: {
                    $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
                }).first(where: { $0.window === window && $0.acceptsFirstResponder }) {
                    window?.makeFirstResponder(button)
                }
                return
            }
            if let key = TaskRowKey(event), handle?(key) == .handled { return }
            super.keyDown(with: event)
        }
    }
    func makeNSView(context: Context) -> Row { Row() }
    func updateNSView(_ view: Row, context: Context) {
        view.selection = selection
        view.handle = handle
        view.enabled = enabled
        selection.responder = view
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(label)
    }
    static func dismantleNSView(_ view: Row, coordinator: ()) {
        if view.selection?.responder === view { view.selection?.responder = nil; view.selection?.rowFocused = false }
    }
}

struct TaskNativeAction: NSViewRepresentable {
    let symbol: String
    let label: String
    let identifier: String
    let selection: TaskRowSelection
    let visible: Bool
    var destructive = false
    var tooltip: String? = nil
    let action: () -> Void

    final class Button: NSButton {
        weak var selection: TaskRowSelection?
        var run: (() -> Void)?
        var eligible = false
        var destructive = false
        var hovered = false
        override var acceptsFirstResponder: Bool { eligible && isEnabled }
        override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { selection?.actionFocused = self; needsDisplay = true }
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted, selection?.actionFocused === self { selection?.actionFocused = nil }
            needsDisplay = true
            return accepted
        }
        override func keyDown(with event: NSEvent) {
            guard eligible && isEnabled else { return }
            if event.keyCode == 48 {
                if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
                else { window?.selectNextKeyView(self) }
                return
            }
            if event.keyCode == 53 || event.keyCode == 123 {
                if let row = selection?.responder { window?.makeFirstResponder(row) }
                return
            }
            // 按钮只激活自己，既不向行转发，也不重复激活。
            if [UInt16(36), 76, 49].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                if !event.isARepeat { performClick(nil) }
                return
            }
            super.keyDown(with: event)
        }
        override func updateTrackingAreas() {
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
            super.updateTrackingAreas()
            refreshHover()
        }
        // 显现时指针可能已经位于按钮上，不能只等待下一次 entered。
        func refreshHover() {
            let inside = eligible && window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } == true
            if hovered != inside { hovered = inside; needsDisplay = true }
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshHover() }
        override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) {
            let focused = window?.firstResponder === self
            let active = eligible && (hovered || isHighlighted || focused)
            let color = NSColor(active ? (destructive ? DotistDesign.danger : DotistDesign.accent) : DotistDesign.muted)
            if active {
                let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                // 无边界的局部光照，边缘归零，不再绘制独立按钮底板。
                let peak: CGFloat = isHighlighted ? 0.24 : (dark ? 0.16 : 0.28)
                let glow = NSGradient(starting: NSColor.white.withAlphaComponent(peak), ending: NSColor.white.withAlphaComponent(0))!
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: bounds).addClip()
                glow.draw(fromCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: 0,
                          toCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: min(bounds.width, bounds.height) / 2,
                          options: [])
                NSGraphicsContext.restoreGraphicsState()
            }
            if let image {
                let side: CGFloat = isHighlighted ? 10 : 11
                let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
                image.withSymbolConfiguration(.init(paletteColors: [color]))?.draw(in: rect)
            }
            if focused {
                NSColor(DotistDesign.accent).setFill()
                NSBezierPath(roundedRect: NSRect(x: bounds.midX - 5, y: 1, width: 10, height: 2), xRadius: 1, yRadius: 1).fill()
            }
        }
        @objc func invoke() { run?() }
    }
    func makeNSView(context: Context) -> Button {
        let button = Button()
        button.isBordered = false
        button.focusRingType = .none
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(Button.invoke)
        selection.buttons.append(.init(button))
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        button.selection = selection
        button.eligible = visible
        button.isEnabled = visible
        button.destructive = destructive
        button.run = action
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.toolTip = visible ? (tooltip ?? label) : nil
        button.refreshHover()
        button.needsDisplay = true
    }
    static func dismantleNSView(_ button: Button, coordinator: ()) {
        if button.selection?.actionFocused === button { button.selection?.actionFocused = nil }
        button.selection?.buttons.removeAll { $0.value == nil || $0.value === button }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Button, context: Context) -> CGSize? { CGSize(width: 22, height: 22) }
}

final class WeakTaskAction {
    weak var value: TaskNativeAction.Button?
    init(_ value: TaskNativeAction.Button) { self.value = value }
}
