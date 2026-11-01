import AppKit
import SwiftUI

enum ComposerMetrics {
    static let rowHeight: CGFloat = 24
    static let barHeight: CGFloat = 52
    static let fontSize: CGFloat = 13
    static let calendarSize: CGFloat = 13
    // Source Sans has an 18pt native line at this size; AppKit's fallback is
    // 16pt. Account for the extra descent allowance without shifting fallback.
    static func textOpticalOffset(font: NSFont?) -> CGFloat {
        guard let font else { return 0 }
        return max(0, (NSLayoutManager().defaultLineHeight(for: font) - 16) / 2)
    }
}

struct ComposerGroupLabel: View {
    let title: String
    let language: String
    var body: some View {
        Text(title).font(DotistDesign.nameFont(ComposerMetrics.fontSize, weight: .semibold, language: language))
            .lineLimit(1).frame(height: ComposerMetrics.rowHeight)
    }
}

struct ComposerCalendarIcon: View {
    var language = "en"
    var body: some View {
        Image(systemName: "calendar").font(DotistDesign.textFont(ComposerMetrics.calendarSize, language: language))
            .frame(width: ComposerMetrics.rowHeight, height: ComposerMetrics.rowHeight)
    }
}

/// NSTextField otherwise keeps its cell at the top of a taller SwiftUI frame.
/// Using the same drawing/editing rect also keeps the field editor's caret on
/// the resting text baseline when focus changes.
final class ComposerTextFieldCell: NSTextFieldCell {
    private let composerEditor = ComposerFieldEditor()

    override func fieldEditor(for view: NSView) -> NSTextView? {
        composerEditor.composer = view
        return composerEditor
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let height = min(result.height, cellSize(forBounds: rect).height)
        result.origin.y += (result.height - height) / 2 + ComposerMetrics.textOpticalOffset(font: font)
        result.size.height = height
        return result
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        drawingRect(forBounds: rect)
    }

    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }

    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, event: event)
    }
}

/// AppKit sizes a caret from font descent metrics. Center that native-height
/// caret in the same line box as the glyphs, without changing its text baseline.
final class ComposerFieldEditor: NSTextView {
    weak var composer: NSView?
    private let composerStorage: NSTextStorage
    convenience init() { self.init(frame: .zero, textContainer: nil) }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let resolved: NSTextContainer
        if let container, let storage = container.layoutManager?.textStorage {
            resolved = container
            composerStorage = storage
        } else {
            let layout = NSLayoutManager()
            composerStorage = NSTextStorage()
            composerStorage.addLayoutManager(layout)
            resolved = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            layout.addTextContainer(resolved)
        }
        super.init(frame: frameRect, textContainer: resolved)
        isFieldEditor = true
        allowsUndo = true
        clipsToBounds = false
    }
    required init?(coder: NSCoder) { nil }
    func centeredCaretRect(_ rect: NSRect) -> NSRect {
        guard let composer else { return rect }
        var result = rect
        result.origin.y = convert(composer.bounds, from: composer).midY - rect.height / 2
        return result
    }
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: centeredCaretRect(rect), color: color, turnedOn: flag)
    }
}

final class ComposerTextField: NSTextField {
    init() {
        super.init(frame: .zero)
        cell = ComposerTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        maximumNumberOfLines = 1
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        textColor = NSColor(DotistDesign.ink)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: ComposerMetrics.rowHeight)
    }
}

struct ComposerInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let label: String
    let font: NSFont
    let commit: () -> Void
    let navigate: (Int) -> Bool
    let complete: (Bool) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = ComposerTextField()
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: NSColor(DotistDesign.faint)])
        field.setAccessibilityLabel(label)
        field.font = font
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: (text as NSString).length, length: 0) }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposerInput
        init(_ parent: ComposerInput) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.focused = true
            if let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView {
                editor.insertionPointColor = NSColor(DotistDesign.accent)
                editor.allowsUndo = true
            }
        }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            if selector == #selector(NSResponder.moveDown(_:)) { return parent.navigate(1) }
            if selector == #selector(NSResponder.moveUp(_:)) { return parent.navigate(-1) }
            if selector == #selector(NSResponder.insertTab(_:)) { return parent.complete(true) }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if !parent.complete(false) { parent.commit() }
                return true
            }
            return false
        }
    }
}

/// A shared 24pt line box, used by the real bar and offscreen rendering tests.
struct ComposerLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 324, height: ComposerMetrics.rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let date = subviews[2].sizeThatFits(.unspecified).width
        let group = min(subviews[0].sizeThatFits(.unspecified).width, max(0, bounds.width - date - 70))
        let y = bounds.midY - ComposerMetrics.rowHeight / 2
        subviews[0].place(at: CGPoint(x: bounds.minX - 3, y: y), proposal: ProposedViewSize(width: group, height: ComposerMetrics.rowHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX + group + 8, y: y), proposal: ProposedViewSize(width: max(0, bounds.width - group - date - 16), height: ComposerMetrics.rowHeight))
        subviews[2].place(at: CGPoint(x: bounds.maxX - date, y: y), proposal: ProposedViewSize(width: date, height: ComposerMetrics.rowHeight))
    }
}
