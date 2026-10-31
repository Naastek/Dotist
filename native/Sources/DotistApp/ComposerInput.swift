import AppKit
import SwiftUI

struct ComposerInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let label: String
    let font: NSFont
    let commit: () -> Void
    let navigate: (Int) -> Bool
    let complete: (Bool) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
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
