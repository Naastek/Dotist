import AppKit
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class ComposerAlignmentTests: XCTestCase {
    func testSharedLineBoxAndCenteredDrawingRect() {
        XCTAssertEqual(ComposerMetrics.rowHeight, 24)
        XCTAssertEqual(ComposerMetrics.barHeight, 52)
        XCTAssertEqual(ComposerMetrics.fontSize, 13)
        XCTAssertEqual(ComposerMetrics.calendarSize, 13)
        let field = ComposerTextField()
        field.font = DotistDesign.nativeFont(13, language: "zh-CN")
        let rect = field.cell!.drawingRect(forBounds: NSRect(x: 0, y: 0, width: 180, height: 24))
        XCTAssertEqual(rect.midY, 12 + ComposerMetrics.textOpticalOffset(font: field.font), accuracy: 0.5)
        XCTAssertLessThanOrEqual(rect.height, 24)
    }

    func testNativeUndoRoutingPreservesEveryTextEditor() throws {
        func key(_ flags: NSEvent.ModifierFlags, characters: String = "z") throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 6))
        }
        XCTAssertEqual(TaskPanelUndoShortcut.redo(for: try key(.command), responder: nil), false)
        XCTAssertEqual(TaskPanelUndoShortcut.redo(for: try key([.command, .shift], characters: "Z"), responder: nil), true)
        XCTAssertNil(TaskPanelUndoShortcut.redo(for: try key([.command, .option]), responder: nil))
        XCTAssertNil(TaskPanelUndoShortcut.redo(for: try key([]), responder: nil))
        XCTAssertNil(TaskPanelUndoShortcut.redo(for: try key(.command), responder: NSTextView()))
        XCTAssertNil(TaskPanelUndoShortcut.redo(for: try key([.command, .shift]), responder: ComposerTextField()))
    }

    func testActualComposerRendersTextAndCalendarOnSameVisualCenter() async throws {
        _ = NSApplication.shared
        let content = ComposerLayout {
            Menu {} label: { ComposerGroupLabel(title: "Inbox", language: "zh-CN") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height: ComposerMetrics.rowHeight)
            ComposerInput(text: .constant(""), focused: .constant(false), placeholder: "写下一件小事", label: "新任务",
                font: DotistDesign.nativeFont(13, language: "zh-CN"), commit: {}, navigate: { _ in false }, complete: { _ in false })
                .frame(height: ComposerMetrics.rowHeight)
            ComposerCalendarIcon()
        }.padding(.leading, 16).padding(.trailing, 11).frame(width: 364, height: ComposerMetrics.barHeight)
            .foregroundStyle(Color.black).background(Color.white).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 364, height: 52)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wE1-composer.png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: path)
        let scale = CGFloat(rep.pixelsWide) / 364
        func center(_ range: Range<CGFloat>) throws -> CGFloat {
            var ys: [CGFloat] = []
            for y in 0..<rep.pixelsHigh {
                for x in Int(range.lowerBound * scale)..<Int(range.upperBound * scale) {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.65 {
                        ys.append(CGFloat(y) / scale)
                    }
                }
            }
            if ys.isEmpty { throw XCTSkip("Offscreen AppKit host produced no glyph pixels; requires a WindowServer rendering context") }
            return (try XCTUnwrap(ys.min()) + XCTUnwrap(ys.max()) + 1 / scale) / 2
        }
        let group = try center(16..<64), input = try center(90..<250), calendar = try center(330..<351)
        print("wE1 composer rendered centers: group=\(group), input=\(input), calendar=\(calendar), scale=\(scale), png=\(path.path)")
        XCTAssertEqual(group, input, accuracy: 0.5)
        XCTAssertEqual(input, calendar, accuracy: 0.5)

        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let field = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerTextField }.first)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        XCTAssertTrue(window.makeFirstResponder(field))
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(field.currentEditor() as? ComposerFieldEditor)
        let screenCaret = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let nativeCaret = editor.convert(window.convertFromScreen(screenCaret), from: nil)
        let caret = editor.centeredCaretRect(nativeCaret)
        let actual = host.convert(caret, from: editor)
        XCTAssertEqual(actual.midY, input, accuracy: 0.5)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: try XCTUnwrap(editor.font))
        XCTAssertEqual(caret.height, lineHeight, accuracy: 0.5)
        XCTAssertTrue(editor.allowsUndo)
        print("wE1 native caret: center=\(actual.midY), height=\(caret.height), nativeLineHeight=\(lineHeight)")
        editor.insertText("native undo", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "", "Composer editing must retain native text undo")
    }
}
