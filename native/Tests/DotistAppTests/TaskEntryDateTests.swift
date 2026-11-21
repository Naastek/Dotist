import AppKit
import DotistCore
import XCTest
@testable import DotistApp

final class TaskEntryDateTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-20T17:00:00Z")!
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    private func resolve(_ text: String, date: TaskEntryDate = TaskEntryDate(),
                         fallback: String? = nil, composing: Bool = false) -> TaskEntryDate.Submission {
        date.resolve(text, fallback: fallback, composing: composing, now: now, timeZone: shanghai)
    }

    func testRecognizedDatesKeepTheTaskAndItsTags() {
        XCTAssertEqual(resolve("明天核对样稿 #客户"), .init(title: "核对样稿 #客户", day: "2026-11-22"))
        XCTAssertEqual(resolve("核对样稿 下週一 #明天 #客户"), .init(title: "核对样稿 #明天 #客户", day: "2026-11-23"))
        XCTAssertEqual(resolve("Day after tomorrow: Review draft #client"), .init(title: "Review draft #client", day: "2026-11-23"))
        XCTAssertEqual(resolve("2028-02-29，校对"), .init(title: "校对", day: "2028-02-29"))
        XCTAssertEqual(resolve("après-demain Relire le dossier"), .init(title: "Relire le dossier", day: "2026-11-23"))
    }

    func testAmbiguousLiteralAndIncompleteTextStaysIntact() {
        for title in ["阅读《明天》 #读书", "明天的会议纪要", "明天之后再议", "研究 tomorrow 的用法", "检查 #明天",
                      "Tomorrow", "明天 #客户", "2026-02-29 校对", "今天 明天 核对", "今天 核对 明天",
                      "Review before tomorrow", "第一条\n明天 第二条", "2026-11- 核对"] {
            XCTAssertEqual(resolve(title), .init(title: title, day: nil), title)
        }
    }

    func testManualChoiceAndClearOverrideRecognitionAndFilterDefaults() {
        let raw = "明天核对样稿 #客户"
        let fallback = "2026-11-20"
        var date = TaskEntryDate(contextDay: "2026-12-01")
        XCTAssertEqual(resolve("核对样稿", fallback: fallback).day, fallback)
        XCTAssertEqual(resolve("核对样稿", date: date, fallback: fallback).day, "2026-12-01")
        XCTAssertEqual(resolve(raw, date: date, fallback: fallback).day, "2026-11-22")
        XCTAssertEqual(resolve(raw, date: date, fallback: fallback, composing: true),
                       .init(title: raw, day: "2026-12-01"))
        date.selection = .selected("2026-11-25")
        XCTAssertEqual(resolve(raw, date: date, fallback: fallback), .init(title: raw, day: "2026-11-25"))
        date.selection = .cleared
        XCTAssertEqual(resolve(raw, date: date, fallback: fallback), .init(title: raw, day: nil))
        XCTAssertEqual(resolve("今天核对另一份", date: date, fallback: fallback).day, nil)
        XCTAssertEqual(resolve("今天核对另一份", fallback: fallback).day, "2026-11-21")
    }

    func testRelativeDatesUseLocalDayAcrossClockChanges() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let beforeDST = ISO8601DateFormatter().date(from: "2026-03-08T04:30:00Z")!
        XCTAssertEqual(TaskEntryDate().resolve("tomorrow Call", now: beforeDST, timeZone: newYork).day, "2026-03-08")
        let monday = ISO8601DateFormatter().date(from: "2026-12-28T12:00:00Z")!
        XCTAssertEqual(TaskEntryDate().resolve("下周一 校对", now: monday, timeZone: shanghai).day, "2027-01-04")
    }

    @MainActor
    func testComposerTabCompletesTagAndReturnPersistsDateBeforeNextDraft() async throws {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let existing = try store.addTask(title: "明天核对旧稿 #客户", dueDate: "2026-12-01")
        let model = try AppModel(store: store)
        let window = MainWindow(model: model, state: TaskPanelState(scope: "all"),
                                showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {})
        let fixture = NativeRenderingFixture(window, size: CGSize(width: 320, height: 440))
        defer { fixture.close() }
        let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first)
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? ComposerFieldEditor)
        let coordinator = try XCTUnwrap(field.delegate as? ComposerInput.Coordinator)
        let returnKey = #selector(NSResponder.insertNewline(_:))
        let replaceSelection = NSRange(location: NSNotFound, length: 0)
        editor.insertText("2028-02-29 核对新稿 #客", replacementRange: replaceSelection)
        _ = try await fixture.capture(scale: 1)
        let dateButton = try XCTUnwrap(accessibilityNodes(fixture.host).first {
            ($0 as? any NSAccessibilityElementProtocol)?.accessibilityIdentifier?() == "composer-due"
        })
        let value = #selector(NSAccessibilityProtocol.accessibilityValue)
        XCTAssertEqual(dateButton.perform(value)?.takeUnretainedValue() as? String, model.dueLabel("2028-02-29"))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        _ = try await fixture.capture(scale: 1)
        XCTAssertEqual(field.stringValue, "2028-02-29 核对新稿 #客户 ")
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: returnKey))
        try await waitForSave(in: model)
        _ = try await fixture.capture(scale: 1)
        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(model.tasks.first { $0.title == "核对新稿 #客户" }?.dueDate, "2028-02-29")

        editor.insertText("下一件事", replacementRange: replaceSelection)
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: returnKey))
        try await waitForSave(in: model)
        let next = try XCTUnwrap(model.tasks.first { $0.title == "下一件事" })
        XCTAssertNil(next.dueDate)
        XCTAssertEqual(model.tasks.first { $0.id == existing.id }, existing)
        XCTAssertEqual(model.tagCounts.first { $0.tag == "客户" }?.all, 2)
    }

    @MainActor
    func testQuickAddWindowSuppressesMarkedDateThenSavesCommittedTitleAndTag() async throws {
        try await withEntryStore { store, model in
            var closed = false
            let fixture = NativeRenderingFixture(QuickAddWindow(model: model) { closed = true },
                                                 size: CGSize(width: 560, height: 112))
            defer { fixture.close() }
            let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first)
            XCTAssertTrue(fixture.window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? ComposerFieldEditor)
            let coordinator = try XCTUnwrap(field.delegate as? QuickInput.Coordinator)
            let returnKey = #selector(NSResponder.insertNewline(_:))
            let replacement = NSRange(location: NSNotFound, length: 0)
            let title = "2028-02-29 核对样稿 #客户"
            editor.setMarkedText(title, selectedRange: NSRange(location: title.utf16.count, length: 0), replacementRange: replacement)
            _ = try await fixture.capture(scale: 1)
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertEqual(try accessibleValue("quick-add-due", in: fixture.host), model.text("到期日"))
            XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: returnKey))
            XCTAssertFalse(closed)
            XCTAssertTrue(try store.listTasks().isEmpty)

            editor.insertText(title, replacementRange: replacement)
            _ = try await fixture.capture(scale: 1)
            XCTAssertEqual(try accessibleValue("quick-add-due", in: fixture.host), model.dueLabel("2028-02-29"))
            editor.doCommand(by: returnKey)
            try await waitForSave(in: model)
            XCTAssertTrue(closed)
            let task = try XCTUnwrap(store.listTasks().first)
            XCTAssertEqual(task.title, "核对样稿 #客户")
            XCTAssertEqual(task.dueDate, "2028-02-29")
            XCTAssertEqual(model.tagCounts.first { $0.tag == "客户" }?.all, 1)
        }
    }

    @MainActor
    func testQuickAddWindowMenuOverridesAndClearsRecognizedDueDate() async throws {
        try await withEntryStore { store, model in
            let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: Date())).dotistDay
            let cases: [(action: String, label: String, due: String?)] = [("明天", "明天", tomorrow), ("清除到期日", "无日期", nil)]
            for (index, choice) in cases.enumerated() {
                var closed = false
                let fixture = NativeRenderingFixture(QuickAddWindow(model: model) { closed = true },
                                                     size: CGSize(width: 560, height: 112))
                defer { fixture.close() }
                _ = try await fixture.capture(scale: 1)
                let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first)
                XCTAssertTrue(fixture.window.makeFirstResponder(field))
                let editor = try XCTUnwrap(field.currentEditor() as? ComposerFieldEditor)
                let title = "2028-02-29 样稿 \(index) #客户"
                editor.insertText(title, replacementRange: NSRange(location: 0, length: 0))
                try await Task.sleep(for: .milliseconds(50))
                _ = try await fixture.capture(scale: 1)
                XCTAssertEqual(try accessibleValue("quick-add-due", in: fixture.host), model.dueLabel("2028-02-29"))
                let cell = try XCTUnwrap(try accessibleNode("quick-add-due", in: fixture.host) as? NSPopUpButtonCell)
                try await chooseMenuItem(model.text(choice.action), in: cell)
                _ = try await fixture.capture(scale: 1)
                XCTAssertEqual(try accessibleValue("quick-add-due", in: fixture.host), model.text(choice.label))
                XCTAssertFalse(fixture.window.isVisible)

                XCTAssertTrue(fixture.window.makeFirstResponder(field))
                field.currentEditor()?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                try await waitForSave(in: model)
                XCTAssertTrue(closed)
                let task = try XCTUnwrap(store.listTasks().first { $0.title == title })
                XCTAssertEqual(task.dueDate, choice.due)
            }
            XCTAssertEqual(model.tagCounts.first { $0.tag == "客户" }?.all, 2)
        }
    }

    @MainActor
    private func chooseMenuItem(_ title: String, in cell: NSPopUpButtonCell) async throws {
        let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu else { return }
            DispatchQueue.main.async { menu.cancelTracking() }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        // SwiftUI materializes the AppKit items when the cell opens its menu.
        // Cancel native tracking before invoking the selected item's action.
        _ = cell.accessibilityPerformPress()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        repeat {
            try await Task.sleep(for: .milliseconds(10))
        } while cell.menu?.item(withTitle: title) == nil && clock.now < deadline
        let menu = try XCTUnwrap(cell.menu, "Menu was not built for \(title)")
        let item = try XCTUnwrap(menu.item(withTitle: title), "Available items: \(menu.items.map(\.title))")
        menu.performActionForItem(at: menu.index(of: item))
    }

    @MainActor
    func testEmptyComposerDropsContextDateWhenScopeChanges() async throws {
        try await withEntryStore { store, model in
            let state = TaskPanelState(scope: "tomorrow")
            let fixture = NativeRenderingFixture(MainWindow(model: model, state: state,
                showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false),
                size: CGSize(width: 364, height: 620))
            defer { fixture.close() }
            _ = try await fixture.capture(scale: 1)
            let add = try accessibleNode("empty-state-add", in: fixture.host)
            let press = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            XCTAssertTrue(unsafeBitCast(try XCTUnwrap(add.method(for: press)), to: Press.self)(add, press))
            _ = try await fixture.capture(scale: 1)
            XCTAssertEqual(try accessibleValue("composer-due", in: fixture.host), model.text("明天"))
            state.scope = "undated"
            _ = try await fixture.capture(scale: 1)
            XCTAssertEqual(try accessibleValue("composer-due", in: fixture.host), "")
            let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first)
            XCTAssertTrue(fixture.window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? ComposerFieldEditor)
            editor.insertText("After scope change", replacementRange: NSRange(location: 0, length: 0))
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try await waitForSave(in: model)
            XCTAssertNil(try XCTUnwrap(store.listTasks().first).dueDate)
        }
    }

    @MainActor
    private func withEntryStore(_ test: (TaskStore, AppModel) async throws -> Void) async throws {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        try await test(store, AppModel(store: store))
    }

    private func accessibleNode(_ id: String, in host: NSObject) throws -> NSObject {
        try XCTUnwrap(accessibilityNodes(host).first {
            ($0 as? any NSAccessibilityElementProtocol)?.accessibilityIdentifier?() == id
        }, "Missing accessibility element \(id)")
    }

    private func accessibleValue(_ id: String, in host: NSObject) throws -> String {
        let node = try accessibleNode(id, in: host)
        return node.perform(#selector(NSAccessibilityProtocol.accessibilityValue))?.takeUnretainedValue() as? String ?? ""
    }

    private func accessibilityNodes(_ node: NSObject) -> [NSObject] {
        let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        let children = node.responds(to: selector)
            ? node.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
        return [node] + children.flatMap(accessibilityNodes)
    }

    @MainActor
    private func waitForSave(in model: AppModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while model.busy && clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
    }
}
