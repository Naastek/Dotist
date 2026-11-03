import AppKit
import XCTest
@testable import DotistApp

@MainActor
final class ShortcutRecorderTests: XCTestCase {
    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func testCommandEquivalentRecordsInsteadOfInvokingItsNormalAction() throws {
        _ = NSApplication.shared
        let button = ShortcutButton()
        button.normalTitle = "original"
        button.recordingText = "recording"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 32), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = button
        defer { window.close() }
        var begins = 0
        var results: [String?] = []
        button.begin = { begins += 1 }
        button.finish = { results.append($0) }
        button.startRecording(nil)
        XCTAssertTrue(button.recording)
        XCTAssertEqual(button.title, "recording")
        XCTAssertTrue(button.performKeyEquivalent(with: try key(40, [.command, .shift], characters: "K")))
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(results, ["Command+Shift+K"])
        XCTAssertFalse(button.recording)
        XCTAssertEqual(button.title, "original")
    }

    func testEscapeAndFocusLossCancelWithoutChangingTheBinding() throws {
        _ = NSApplication.shared
        let button = ShortcutButton()
        button.normalTitle = "original"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 32), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = button
        defer { window.close() }
        var results: [String?] = []
        button.finish = { results.append($0) }
        button.startRecording(nil)
        button.keyDown(with: try key(53, [], characters: "\u{1b}"))
        XCTAssertFalse(button.recording)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0])
        button.startRecording(nil)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(button.recording)
        XCTAssertEqual(results.count, 2)
        XCTAssertNil(results[1])
        XCTAssertEqual(button.title, "original")
    }

    func testShortcutMatchingKeepsModifiersExactAndReservesCommandComma() throws {
        let commandK = try key(40, .command, characters: "k")
        XCTAssertTrue(GlobalShortcuts.matches("Command+K", event: commandK))
        XCTAssertFalse(GlobalShortcuts.matches("Command+Shift+K", event: commandK))
        XCTAssertFalse(GlobalShortcuts.matches("", event: commandK))
        XCTAssertThrowsError(try GlobalShortcuts.validate("Command+Comma", id: 5))
        XCTAssertThrowsError(try GlobalShortcuts.validate("CommandOrControl+Comma", id: 1))
        XCTAssertNoThrow(try GlobalShortcuts.validate("Command+Comma", id: 3))
        XCTAssertNoThrow(try GlobalShortcuts.validate("", id: 3))
    }

    func testGlobalApplyRejectsAliasDuplicatesBeforeAnyRegistration() throws {
        let shortcuts = try GlobalShortcuts { _ in XCTFail("No shortcut should fire") }
        // Non-settings Command-comma is reserved, so the unfixed implementation
        // fails before RegisterEventHotKey as well. The duplicate guard must win.
        for alias in ["CommandOrControl+Comma", "CommandOrControl+Command+Comma"] {
            XCTAssertThrowsError(try shortcuts.apply([1: "Command+Comma", 2: alias])) {
                XCTAssertEqual($0.localizedDescription, "不同的动作不能使用同一个快捷键")
            }
            XCTAssertTrue(shortcuts.values.isEmpty)
        }
    }

    func testRuntimeSupportedKeysAndModifierAliasesKeepTheirExistingMeaning() throws {
        let commandOptionD = try key(2, [.command, .option], characters: "d")
        for value in ["CommandOrControl+Alt+D", "Alt+Command+D", "Alt+Command+Command+D"] {
            XCTAssertTrue(GlobalShortcuts.matches(value, event: commandOptionD))
        }
        XCTAssertFalse(GlobalShortcuts.matches("Control+Alt+D", event: commandOptionD))
        XCTAssertThrowsError(try GlobalShortcuts.validate("Command+Unknown", id: 5))
        XCTAssertThrowsError(try GlobalShortcuts.validate("Meta+K", id: 5))
        XCTAssertThrowsError(try GlobalShortcuts.validate("Command+F21", id: 5))
        XCTAssertNoThrow(try GlobalShortcuts.validate("Shift+CommandOrControl+F20", id: 5))
        XCTAssertNoThrow(try GlobalShortcuts.validate("Command+Backslash", id: 5))
    }

}
