import AppKit
import SwiftUI

struct TaskEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let font: NSFont
    let label: String
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
        let editor = TaskTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 20))
        editor.delegate = context.coordinator
        editor.drawsBackground = false
        editor.isRichText = false
        editor.importsGraphics = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.font = font
        editor.textColor = NSColor.labelColor
        editor.string = text
        editor.commit = commit
        editor.cancel = cancel
        editor.indent = indent
        editor.blur = blur
        editor.setAccessibilityLabel(label)
        scroll.documentView = editor
        DispatchQueue.main.async { editor.window?.makeFirstResponder(editor); context.coordinator.measure(editor) }
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
    final class Coordinator: NSObject, NSTextViewDelegate {
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
            let measured = max(20, ceil(layout.usedRect(for: container).height))
            if abs(parent.height - measured) > 0.5 { DispatchQueue.main.async { self.parent.height = measured } }
        }
    }
}

final class TaskTextView: NSTextView {
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
        let result = super.resignFirstResponder()
        if result { DispatchQueue.main.async { self.blur() } }
        return result
    }
}
