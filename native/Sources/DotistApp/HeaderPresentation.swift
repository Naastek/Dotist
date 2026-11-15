import AppKit
import SwiftUI

enum HeaderPopover: Equatable { case filters, calendar, color }

@MainActor
final class HeaderPresentation: ObservableObject {
    @Published var manageTags = false
    @Published var manageGroups = false
    @Published var active: HeaderPopover?
    func set(_ target: HeaderPopover, presented: Bool) {
        if presented { active = target }
        else if active == target { active = nil }
    }
    func dismiss() { active = nil }
}

enum HeaderColorAnchor: Hashable { case color }
struct HeaderColorAnchorKey: PreferenceKey {
    static var defaultValue: [HeaderColorAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [HeaderColorAnchor: Anchor<CGRect>], nextValue: () -> [HeaderColorAnchor: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

final class HeaderMenuAction: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { run() }
}

/// 原生按钮持有菜单工厂，菜单追踪结束后再执行动作。
struct HeaderMenuButton: NSViewRepresentable {
    let title: String
    let symbol: String
    let identifier: String
    var accessibilityTitle: String? = nil
    let menu: () -> NSMenu
    final class TextCell: NSButtonCell {
        static let horizontalInset: CGFloat = 8
        override func titleRect(forBounds rect: NSRect) -> NSRect {
            NSRect(x: rect.minX + 14, y: rect.minY, width: max(0, rect.width - 32), height: rect.height)
        }
    }
    final class Button: NSButton {
        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
        var makeMenu: (() -> NSMenu)?
        private(set) var keyboardFocus = false
        override func mouseDown(with event: NSEvent) {
            keyboardFocus = false
            needsDisplay = true
            super.mouseDown(with: event)
        }
        override var intrinsicContentSize: NSSize {
            let textWidth = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
            return NSSize(width: imagePosition == .imageOnly ? 24 : ceil(textWidth) + 32, height: 24)
        }
        override func becomeFirstResponder() -> Bool {
            keyboardFocus = NSApp.currentEvent?.type == .keyDown
            let accepted = super.becomeFirstResponder()
            needsDisplay = true
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            needsDisplay = true
            return accepted
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if imagePosition == .noImage {
                NSColor(DotistDesign.muted).setFill()
                NSBezierPath(ovalIn: NSRect(x: 6, y: bounds.midY - 2, width: 4, height: 4)).fill()
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: bounds.maxX - 14, y: bounds.midY + (isFlipped ? -2 : 2)))
                arrow.line(to: NSPoint(x: bounds.maxX - 10, y: bounds.midY + (isFlipped ? 2 : -2)))
                arrow.line(to: NSPoint(x: bounds.maxX - 6, y: bounds.midY + (isFlipped ? -2 : 2)))
                arrow.close(); arrow.fill()
            }
            if keyboardFocus && window?.firstResponder === self {
                NSColor(DotistDesign.accent).setFill()
                NSBezierPath(roundedRect: NSRect(x: bounds.midX - 5, y: isFlipped ? bounds.maxY - 3 : bounds.minY + 1, width: 10, height: 2), xRadius: 1, yRadius: 1).fill()
            }
        }
        @objc func openMenu() {
            makeMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
            keyboardFocus = false
            needsDisplay = true
        }
    }
    func makeNSView(context: Context) -> Button {
        let button = Button()
        let cell = TextCell()
        cell.usesSingleLineMode = true
        cell.wraps = false
        cell.lineBreakMode = .byTruncatingTail
        cell.truncatesLastVisibleLine = true
        button.cell = cell
        button.alignment = .left
        button.font = NSFont.systemFont(ofSize: 13)
        button.isBordered = false
        button.focusRingType = .none
        button.imagePosition = .imageOnly
        button.target = button
        button.action = #selector(Button.openMenu)
        return button
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Button, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 24)
    }
    func updateNSView(_ button: Button, context: Context) {
        button.title = title
        button.imagePosition = symbol.isEmpty ? .noImage : .imageOnly
        button.image = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        button.contentTintColor = NSColor(DotistDesign.muted)
        button.invalidateIntrinsicContentSize()
        button.setAccessibilityLabel(accessibilityTitle ?? title)
        button.setAccessibilityIdentifier(identifier)
        button.cell?.setAccessibilityIdentifier(identifier)
        button.cell?.setAccessibilityLabel(accessibilityTitle ?? title)
        button.toolTip = title
        button.makeMenu = menu
    }
}

struct HeaderToolStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Plate(configuration: configuration)
    }
    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 8).fill(DotistDesign.rule.opacity(configuration.isPressed ? 0.16 : hovered ? 0.10 : 0.04)))
                .onHover { hovered = $0 }
        }
    }
}

/// A single row; the scope gets all space left by the two fixed control clusters.
struct HeaderClusterLayout: Layout {
    var reservedWindowWidth: CGFloat = 0
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +) + 8
        return CGSize(width: proposal.width ?? ideal, height: 24)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let filter = subviews[1].sizeThatFits(.unspecified)
        let window = subviews[2].sizeThatFits(.unspecified)
        let groupWidth = max(0, bounds.width - filter.width - max(window.width, reservedWindowWidth) - 8)
        subviews[0].place(at: bounds.origin, proposal: .init(width: min(groupWidth, subviews[0].sizeThatFits(.unspecified).width), height: 24))
        subviews[1].place(at: CGPoint(x: bounds.minX + groupWidth + 4, y: bounds.minY), proposal: .init(filter))
        subviews[2].place(at: CGPoint(x: bounds.maxX - window.width, y: bounds.minY), proposal: .init(window))
    }
}

enum PanelLayoutMetrics {
    static let primaryWidth: CGFloat = 408
    static let secondaryWidth: CGFloat = 432
}
