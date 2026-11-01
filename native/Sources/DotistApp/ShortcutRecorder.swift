import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let value: String
    let label: String
    let empty: String
    let recordingText: String
    var language = "en"
    let begin: () -> Void
    let finish: (String?) -> Void
    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton()
        button.cell = OpticalShortcutCell(textCell: "")
        button.isBordered = false
        button.focusRingType = .none
        button.setButtonType(.momentaryChange)
        button.target = button
        button.action = #selector(ShortcutButton.startRecording(_:))
        button.begin = begin
        button.finish = finish
        button.recordingText = recordingText
        button.setAccessibilityLabel(label)
        return button
    }
    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.font = DotistDesign.nativeFont(13, language: language)
        button.begin = begin
        button.finish = finish
        button.recordingText = recordingText
        button.normalTitle = value.isEmpty ? empty : value.replacingOccurrences(of: "CommandOrControl", with: "⌘").replacingOccurrences(of: "Command", with: "⌘").replacingOccurrences(of: "Control", with: "⌃").replacingOccurrences(of: "Alt", with: "⌥").replacingOccurrences(of: "Shift", with: "⇧").replacingOccurrences(of: "+", with: " ")
        if !button.recording { button.title = button.normalTitle }
    }
}

final class ShortcutButton: NSButton {
    var begin: () -> Void = {}
    var finish: (String?) -> Void = { _ in }
    var recordingText = ""
    var normalTitle = ""
    var recording = false
    private var resignObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }
    override func draw(_ dirtyRect: NSRect) {
        contentTintColor = window?.firstResponder === self ? NSColor(DotistDesign.accent) : NSColor(DotistDesign.ink)
        super.draw(dirtyRect)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        guard let window else { if recording { stop(nil) }; return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            guard let self, self.recording else { return }
            self.stop(nil)
        }
    }
    deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }
    @objc func startRecording(_ sender: Any?) {
        guard !recording else { return }
        recording = true
        begin()
        title = recordingText
        if window?.makeFirstResponder(self) != true { stop(nil) }
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { stop(nil); return }
        if let accelerator = GlobalShortcuts.accelerator(event) { stop(accelerator) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func resignFirstResponder() -> Bool {
        if recording { stop(nil) }
        needsDisplay = true
        return super.resignFirstResponder()
    }
    private func stop(_ value: String?) {
        recording = false
        title = normalTitle
        finish(value)
    }
}

private final class OpticalShortcutCell: NSButtonCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        guard let font else { return super.titleRect(forBounds: rect) }
        return TextLineGeometry(font: font, in: super.titleRect(forBounds: rect), sample: title).lineRect
    }
}
