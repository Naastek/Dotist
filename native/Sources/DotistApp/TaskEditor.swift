import AppKit
import SwiftUI

struct TaskEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let font: NSFont
    let label: String
    var minRowHeight: CGFloat = 32
    var initialClickWindowPoint: CGPoint? = nil
    let commit: () -> Void
    let cancel: () -> Void
    let indent: (Bool) -> Void
    let blur: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        let initialInset = max(0, (minRowHeight - 20) / 2)
        let editor = TaskTextView(frame: NSRect(x: 0, y: 0, width: 120, height: minRowHeight))
        editor.delegate = context.coordinator
        editor.layoutManager?.delegate = context.coordinator
        editor.drawsBackground = false
        editor.isRichText = false
        editor.importsGraphics = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainerInset = NSSize(width: 0, height: initialInset)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.font = font
        editor.opticalSample = text.components(separatedBy: .newlines).first.flatMap { $0.isEmpty ? nil : $0 } ?? "中文任务"
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20
        paragraph.maximumLineHeight = 20
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: font, .paragraphStyle: paragraph]
        editor.insertionPointColor = NSColor(DotistDesign.accent)
        editor.textColor = NSColor(DotistDesign.ink)
        editor.string = text
        editor.commit = commit
        editor.cancel = cancel
        editor.indent = indent
        editor.blur = blur
        editor.setAccessibilityLabel(label)
        scroll.documentView = editor
        let clickPoint = initialClickWindowPoint
        DispatchQueue.main.async {
            scroll.layoutSubtreeIfNeeded()
            editor.window?.makeFirstResponder(editor)
            context.coordinator.measure(editor)
            if let clickPoint, editor.window != nil {
                let local = editor.convert(clickPoint, from: nil)
                if editor.bounds.insetBy(dx: -4, dy: -4).contains(local) {
                    let index = editor.characterIndexForInsertion(at: local)
                    editor.setSelectedRange(NSRange(location: index, length: 0))
                }
            }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? TaskTextView else { return }
        editor.font = font
        editor.setAccessibilityLabel(label)
        editor.commit = commit; editor.cancel = cancel; editor.indent = indent; editor.blur = blur
        if editor.string != text && !editor.hasMarkedText() { editor.string = text }
        context.coordinator.measure(editor)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? TaskTextView else { return }
        editor.blur = {}; editor.commit = {}; editor.cancel = {}; editor.indent = { _ in }
        editor.delegate = nil
    }
    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>, lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
            let rect = CGRect(x: 0, y: 0, width: lineFragmentRect.pointee.width, height: 20)
            let editor = textContainer.textView as? TaskTextView
            let scale = editor?.window?.backingScaleFactor ?? 1
            let geometry = TextLineGeometry(font: parent.font, in: rect, sample: editor?.opticalSample ?? "中文任务")
            // TextKit snaps fractional baselines upward when drawing. Round to
            // the nearest device pixel first; otherwise Projects jumps one pixel
            // at 1x even though its CoreText bounds are analytically centered.
            baselineOffset.pointee = (geometry.baseline * scale).rounded() / scale
            return true
        }
        var parent: TaskEditor
        init(_ parent: TaskEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? TaskTextView else { return }
            parent.text = editor.string
            measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let contentHeight = max(20, ceil(layout.usedRect(for: container).height))
            let inset = max(0, (parent.minRowHeight - contentHeight) / 2)
            if abs(editor.textContainerInset.height - inset) > 0.5 {
                editor.textContainerInset = NSSize(width: 0, height: inset)
            }
            let measured = max(parent.minRowHeight, contentHeight)
            if abs(parent.height - measured) > 0.5 { DispatchQueue.main.async { self.parent.height = measured } }
        }
    }
}

final class TaskTextView: NSTextView {
    var opticalSample = "中文任务"
    var commit: () -> Void = {}
    var cancel: () -> Void = {}
    var indent: (Bool) -> Void = { _ in }
    var blur: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { super.keyDown(with: event); return }
        if event.keyCode == 53 { cancel(); return }
        if event.keyCode == 48 { indent(event.modifierFlags.contains(.shift)); return }
        if (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.contains(.shift) { commit(); return }
        super.keyDown(with: event)
    }
    override func resignFirstResponder() -> Bool {
        // Capture this editor session's action. Reading self.blur on the next
        // run loop can execute a new row's callback after representable reuse.
        let action = blur
        let result = super.resignFirstResponder()
        if result { DispatchQueue.main.async(execute: action) }
        return result
    }
}
