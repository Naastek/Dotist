import AppKit
import SwiftUI
import XCTest
import DotistCore
@testable import DotistApp

@MainActor
final class TaskRowKeyboardTests: XCTestCase {
    private func event(_ code: UInt16, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: code == 48 ? "\t" : code == 36 ? "\r" : " ", charactersIgnoringModifiers: code == 48 ? "\t" : code == 36 ? "\r" : " ", isARepeat: repeatKey, keyCode: code))
    }

    func testNativeOwnershipActivationAndReturnToRowWithoutDesktop() async throws {
        let selection = TaskRowSelection()
        var rowKeys: [TaskRowKey] = []
        var calls = [0, 0, 0]
        let fixture = NativeRenderingFixture(VStack {
            TaskRowKeyboard(selection: selection, label: "合成任务") { rowKeys.append($0); return .handled }.frame(height: 24)
            HStack {
                ForEach(0..<3) { index in
                    TaskNativeAction(symbol: "plus", label: "合成动作", identifier: "action-\(index)", selection: selection, visible: true) { calls[index] += 1 }.frame(width: 22, height: 22)
                }
            }
        }, size: CGSize(width: 200, height: 80))
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        let row = try XCTUnwrap(fixture.descendants(TaskRowKeyboard.Row.self).first)
        let buttons = fixture.descendants(TaskNativeAction.Button.self).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        XCTAssertEqual(buttons.count, 3)
        XCTAssertTrue(fixture.window.makeFirstResponder(row))
        row.keyDown(with: try event(48))
        row.keyDown(with: try event(48, flags: .shift))
        XCTAssertEqual(rowKeys.map(\.key), [.tab, .tab])
        XCTAssertEqual(rowKeys.last?.modifiers, .shift)
        row.keyDown(with: try event(124))
        XCTAssertTrue(fixture.window.firstResponder === buttons[0])
        XCTAssertTrue(selection.actionFocused === buttons[0])
        for (index, button) in buttons.enumerated() {
            XCTAssertTrue(fixture.window.makeFirstResponder(button))
            button.keyDown(with: try event(49))
            button.keyDown(with: try event(36))
            button.keyDown(with: try event(49, repeatKey: true))
            XCTAssertEqual(calls[index], 2)
        }
        XCTAssertEqual(rowKeys.count, 2, "按钮激活不能冒泡为行完成或新建")
        fixture.window.recalculateKeyViewLoop()
        XCTAssertTrue(fixture.window.makeFirstResponder(buttons[0]))
        buttons[0].keyDown(with: try event(48))
        XCTAssertFalse(fixture.window.firstResponder === buttons[0], "Tab 必须移出当前按钮")
        XCTAssertEqual(rowKeys.count, 2, "按钮 Tab 不得触发行缩进")
        XCTAssertTrue(fixture.window.makeFirstResponder(buttons[1]))
        buttons[1].keyDown(with: try event(48, flags: .shift))
        XCTAssertFalse(fixture.window.firstResponder === buttons[1], "Shift+Tab 必须移出当前按钮")
        buttons[2].keyDown(with: try event(53))
        XCTAssertTrue(fixture.window.firstResponder === row)
        XCTAssertNil(selection.actionFocused)
        XCTAssertTrue(selection.rowFocused)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testProductionRowKeepsIndentAndActionActivationSeparate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let parent = try store.addTask(title: "合成父任务", category: DotistGroup.inboxID)
        let child = try store.addTask(title: "合成待缩进任务", category: DotistGroup.inboxID)
        let model = try AppModel(store: store)
        let view = MainWindow(model: model, state: TaskPanelState(), showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: true)
        let fixture = NativeRenderingFixture(view, size: CGSize(width: 408, height: 620))
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(200))
        let row = try XCTUnwrap(fixture.descendants(TaskRowKeyboard.Row.self).first { $0.accessibilityLabel() == child.title })
        let parentRow = try XCTUnwrap(fixture.descendants(TaskRowKeyboard.Row.self).first { $0.accessibilityLabel() == parent.title })
        XCTAssertTrue(fixture.window.makeFirstResponder(parentRow))
        parentRow.keyDown(with: try event(125))
        XCTAssertTrue(fixture.window.firstResponder === row)
        try await Task.sleep(for: .milliseconds(100))
        row.keyDown(with: try event(48))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.tasks.first { $0.id == child.id }?.parentId, parent.id)
        row.keyDown(with: try event(48, flags: .shift))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(model.tasks.first { $0.id == child.id }?.parentId)
        row.keyDown(with: try event(124))
        let action = try XCTUnwrap(fixture.window.firstResponder as? TaskNativeAction.Button)
        XCTAssertEqual(action.accessibilityIdentifier(), "task-action:\(child.id):plus")
        action.keyDown(with: try event(48))
        XCTAssertFalse(fixture.window.firstResponder === action)
        XCTAssertNil(model.tasks.first { $0.id == child.id }?.parentId)
        let delete = try XCTUnwrap(fixture.descendants(TaskNativeAction.Button.self).first { $0.accessibilityIdentifier() == "task-action:\(child.id):xmark" })
        XCTAssertTrue(fixture.window.makeFirstResponder(delete))
        delete.keyDown(with: try event(49))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(model.tasks.first { $0.id == child.id })
        XCTAssertEqual(model.tasks.first { $0.id == parent.id }?.completed, false)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testHiddenActionIsExcludedFromNativeKeyViews() async throws {
        let selection = TaskRowSelection()
        let fixture = NativeRenderingFixture(TaskNativeAction(symbol: "plus", label: "隐藏动作", identifier: "hidden", selection: selection, visible: false) {}, size: CGSize(width: 22, height: 22))
        defer { fixture.close() }
        let button = try XCTUnwrap(fixture.descendants(TaskNativeAction.Button.self).first)
        XCTAssertFalse(button.acceptsFirstResponder)
        XCTAssertFalse(button.canBecomeKeyView)
        XCTAssertFalse(fixture.window.isVisible)
    }
}
