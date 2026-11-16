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
        let selection = view.selection
        view.selection = nil
        view.handle = nil
        guard selection?.responder === view else { return }
        selection?.responder = nil
        // SwiftUI is invalidating its graph here. Publishing synchronously can
        // reenter that graph; detach now and publish after teardown has returned.
        DispatchQueue.main.async { [weak selection] in
            guard let selection, selection.responder == nil, selection.rowFocused else { return }
            selection.rowFocused = false
        }
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
        var actionSymbol = ""
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
            // 矢量统一使用向上的 Y 轴，避免 NSButton 翻转坐标把日历倒置。
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            if isFlipped {
                let transform = NSAffineTransform()
                transform.translateX(by: 0, yBy: bounds.minY + bounds.maxY)
                transform.scaleX(by: 1, yBy: -1)
                transform.concat()
            }
            let focused = window?.firstResponder === self
            let active = eligible && isEnabled && (hovered || isHighlighted || focused)
            let color = NSColor(active ? (destructive ? DotistDesign.danger : DotistDesign.accent) : DotistDesign.muted)
            if eligible && isEnabled && (hovered || isHighlighted) {
                let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                // 柔边状态染色直接叠在共享玻璃上，不生成独立底板。
                let high = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ||
                    effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) == .accessibilityHighContrastAqua ||
                    effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) == .accessibilityHighContrastDarkAqua
                let ink = DotistDesign.hoverInk(dark: dark, highContrast: high)
                let peak = ink.withAlphaComponent(ink.alphaComponent * (isHighlighted ? 1.6 : 1))
                let glow = NSGradient(starting: peak, ending: ink.withAlphaComponent(0))!
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: bounds).addClip()
                glow.draw(fromCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: 0,
                          toCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: min(bounds.width, bounds.height) / 2,
                          options: [])
                NSGraphicsContext.restoreGraphicsState()
            }
            // 加号与叉号共用笔画长度，叉号旋转 45°，而非拉伸不同 SF glyph。
            let path = NSBezierPath()
            path.lineWidth = isHighlighted ? 1.35 : (active ? 1.2 : 1.05)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let cx = bounds.midX, cy = bounds.midY
            func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
                path.move(to: NSPoint(x: cx + x1, y: cy + y1))
                path.line(to: NSPoint(x: cx + x2, y: cy + y2))
            }
            switch actionSymbol {
            case "plus":
                line(-5, 0, 5, 0); line(0, -5, 0, 5)
            case "xmark":
                // 对角线端点距中心 5.2pt，轻微光学校正斜线的视觉收缩。
                let d: CGFloat = 3.68
                line(-d, -d, d, d); line(-d, d, d, -d)
            case "calendar":
                // 顶栏 OpticalSymbol 使用 SF calendar / regular / medium。
                // 直接复用同一系统矢量，保留顶部结构与日期点阵；状态以颜色反馈。
                if let image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .regular, scale: .medium))?
                    .withSymbolConfiguration(.init(paletteColors: [color])) {
                    let size = image.size
                    image.draw(in: NSRect(x: cx - size.width / 2, y: cy - size.height / 2,
                                          width: size.width, height: size.height),
                               from: .zero, operation: .sourceOver, fraction: 1,
                               respectFlipped: false, hints: nil)
                }
            default: break
            }
            color.setStroke()
            path.stroke()
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
        button.actionSymbol = symbol
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.toolTip = visible ? (tooltip ?? label) : nil
        button.refreshHover()
        button.needsDisplay = true
    }
    static func dismantleNSView(_ button: Button, coordinator: ()) {
        let selection = button.selection
        button.selection = nil
        button.run = nil
        selection?.buttons.removeAll { $0.value == nil || $0.value === button }
        DispatchQueue.main.async { [weak selection] in
            guard let selection, selection.actionFocused === button else { return }
            selection.actionFocused = nil
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Button, context: Context) -> CGSize? { CGSize(width: 22, height: 22) }
}

final class WeakTaskAction {
    weak var value: TaskNativeAction.Button?
    init(_ value: TaskNativeAction.Button) { self.value = value }
}
