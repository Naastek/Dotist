import AppKit
import SwiftUI

struct TaskEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let font: NSFont
    let label: String
    var minRowHeight: CGFloat = 32
    var initialClickWindowPoint: CGPoint? = nil
    var restrictHitTestToText: Bool = false
    let commit: () -> Void
    let cancel: () -> Void
    let indent: (Bool) -> Void
    let blur: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TaskEditorScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        let initialInset = max(0, (minRowHeight - 20) / 2)
        let editor = TaskTextView(frame: NSRect(x: 0, y: 0, width: 120, height: minRowHeight))
        editor.restrictHitTestToText = restrictHitTestToText
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
        editor.restrictHitTestToText = restrictHitTestToText
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
            editor.invalidateTextCursorRects()
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
            (editor as? TaskTextView)?.invalidateTextCursorRects()
        }
    }
}

final class TaskEditorScrollView: NSScrollView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let editor = documentView as? TaskTextView,
              let superview else { return super.hitTest(point) }
        let localInScroll = convert(point, from: superview)
        guard bounds.contains(localInScroll) else { return nil }
        let localInEditor = editor.convert(localInScroll, from: self)
        guard editor.isPointInTextHitZone(localInEditor) else { return nil }
        return super.hitTest(point)
    }
}

final class TaskTextView: NSTextView {
    static let trailingHitMargin: CGFloat = 12
    static let emptyTextHitWidth: CGFloat = 36

    var opticalSample = "中文任务"
    var restrictHitTestToText = false
    private(set) var registeredCursorRects: [CGRect] = []
    var commit: () -> Void = {}
    var cancel: () -> Void = {}
    var indent: (Bool) -> Void = { _ in }
    var blur: () -> Void = {}

    func textHitRects() -> [CGRect] {
        guard restrictHitTestToText else { return [bounds] }
        guard let layout = layoutManager, let container = textContainer else { return [bounds] }
        layout.ensureLayout(for: container)
        let origin = textContainerOrigin
        let glyphRange = layout.glyphRange(for: container)
        if glyphRange.length == 0 {
            return [CGRect(x: 0, y: 0, width: min(bounds.width, origin.x + Self.emptyTextHitWidth), height: bounds.height)]
        }
        var lineRects: [CGRect] = []
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            var rect = usedRect.offsetBy(dx: origin.x, dy: origin.y)
            rect.origin.x = 0
            rect.size.width = min(self.bounds.width, usedRect.maxX + origin.x + Self.trailingHitMargin)
            lineRects.append(rect)
        }
        let extra = layout.extraLineFragmentRect
        if !extra.isEmpty {
            var rect = extra.offsetBy(dx: origin.x, dy: origin.y)
            rect.origin.x = 0
            rect.size.width = min(bounds.width, origin.x + Self.emptyTextHitWidth)
            lineRects.append(rect)
        }
        guard !lineRects.isEmpty else {
            return [CGRect(x: 0, y: 0, width: min(bounds.width, origin.x + Self.emptyTextHitWidth), height: bounds.height)]
        }
        // Extend top of the first line and bottom of the last line across vertical
        // textContainerInset so clicking directly above/below glyphs stays in text.
        lineRects[0].size.height += lineRects[0].origin.y
        lineRects[0].origin.y = 0
        let lastIndex = lineRects.count - 1
        lineRects[lastIndex].size.height = max(lineRects[lastIndex].size.height, bounds.maxY - lineRects[lastIndex].origin.y)
        return lineRects
    }

    func isPointInTextHitZone(_ point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        return textHitRects().contains { $0.contains(point) }
    }

    func invalidateTextCursorRects() {
        guard restrictHitTestToText else { return }
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateTextCursorRects()
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateTextCursorRects()
    }

    override func resetCursorRects() {
        guard restrictHitTestToText else {
            registeredCursorRects = [visibleRect]
            super.resetCursorRects()
            return
        }
        discardCursorRects()
        let visible = visibleRect
        var active: [CGRect] = []
        for rect in textHitRects() {
            let clipped = rect.intersection(visible)
            if !clipped.isNull, !clipped.isEmpty {
                addCursorRect(clipped, cursor: .iBeam)
                active.append(clipped)
            }
        }
        registeredCursorRects = active
    }

    override func cursorUpdate(with event: NSEvent) {
        guard restrictHitTestToText else {
            super.cursorUpdate(with: event)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        if isPointInTextHitZone(local) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard isPointInTextHitZone(local) else { return nil }
        return super.hitTest(point)
    }

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
