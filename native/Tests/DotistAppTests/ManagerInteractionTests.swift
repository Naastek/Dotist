import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class ManagerInteractionTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        addTeardownBlock { await MainActor.run { NSApp.accessibilitySetValue(previous, forAttribute: attribute) } }
    }
    private struct InputFixture: View {
        @State var text = ""
        var body: some View {
            // Exact baseline new-group control combination; the live manager
            // now uses OpticalInput and is exercised separately below.
            TextField("New group", text: $text).textFieldStyle(.plain)
                .modifier(DotistFocusRing())
        }
    }
    func testBaselineTextFieldFocusKeepsTheSameNativeEditorAcrossTyping() async throws {
        let fixture = NativeRenderingFixture(InputFixture(), size: CGSize(width: 300, height: 40))
        defer { fixture.close() }
        let field = try XCTUnwrap(fixture.descendants(NSTextField.self).first)
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        for letter in ["a", "b", "完整文字"] {
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertTrue(fixture.descendants(NSTextField.self).first === field, "Focus must not replace the native input")
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText(letter, replacementRange: editor.selectedRange())
        }
        XCTAssertEqual(field.stringValue, "ab完整文字")
    }
    private func model(_ seed: (TaskStore) throws -> Void = { _ in }) throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manager-test-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        try seed(store)
        return try AppModel(store: store)
    }

    func testGroupManagerTypesAndSubmitsWholeNameWithoutReplacingField() async throws {
        let model = try model()
        let fixture = NativeRenderingFixture(GroupManager(model: model, close: {}, tags: {}), size: CGSize(width: 364, height: 620))
        defer { fixture.close() }
        let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first { $0.accessibilityIdentifier() == "manager-new-group" })
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        for text in ["New", " group", " 完整名称"] {
            editor.insertText(text, replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(field.currentEditor() === editor)
        }
        XCTAssertEqual(field.stringValue, "New group 完整名称")
        let delegate = try XCTUnwrap(field.delegate as? OpticalInput.Coordinator)
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        for _ in 0..<100 {
            if model.groups.contains(where: { $0.name == "New group 完整名称" }) && field.stringValue.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.groups.filter { $0.name == "New group 完整名称" }.count, 1)
        XCTAssertEqual(field.stringValue, "")
        XCTAssertTrue(fixture.descendants(ComposerTextField.self).contains { $0 === field })
    }

    private func accessibilityElement(_ object: NSObject, id: String) -> NSObject? {
        if (object as? any NSAccessibilityElementProtocol)?.accessibilityIdentifier?() == id { return object }
        let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        guard object.responds(to: selector),
              let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return nil }
        return children.lazy.compactMap { self.accessibilityElement($0, id: id) }.first
    }

    private func visibleFilterToolbar() throws -> ToolbarConfig {
        let suite = "dotist-filter-manager-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let config = ToolbarConfig(defaults: defaults)
        config.setVisibility(.always, for: .filters)
        return config
    }

    func testMainWindowHasUnifiedFilterEntryWithoutAnyTags() async throws {
        let model = try model()
        let config = try visibleFilterToolbar()
        let fixture = NativeRenderingFixture(MainWindow(model: model, state: TaskPanelState(), showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, toolbarConfig: config), size: CGSize(width: 364, height: 620))
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNotNil(accessibilityElement(fixture.host, id: "unified-filter"))
    }

    func testMainWindowRetainsCompletedOnlyTagOnSnapshotChange() async throws {
        let model = try model { store in
            let task = try store.addTask(title: "Finished #archive", category: DotistGroup.inboxID)
            _ = try store.patchTask(id: task.id, completed: true)
        }
        let state = TaskPanelState(scope: "done")
        state.activeTag = "archive"
        let config = try visibleFilterToolbar()
        let fixture = NativeRenderingFixture(MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, toolbarConfig: config), size: CGSize(width: 364, height: 620))
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNotNil(accessibilityElement(fixture.host, id: "unified-filter"))
        var finished = false
        model.change(completed: { finished = true }) { store in
            _ = try store.addTask(title: "New #other", category: DotistGroup.inboxID)
        }
        for _ in 0..<100 {
            if finished { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(finished)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.activeTag, "archive")
    }

    func testRowHoverObserverCoversActionRectAndDoesNotInterceptInput() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 332, height: 32), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = DateFilterHoverView(frame: CGRect(x: 0, y: 0, width: 332, height: 32))
        window.contentView = view
        view.enabled = true
        var hovered = false
        view.changed = { hovered = $0 }
        for x in stride(from: 0.5, to: 332.0, by: 0.5) {
            view.pointerInWindow = { _ in CGPoint(x: x, y: 16) }
            view.samplePointer()
            XCTAssertTrue(hovered)
            XCTAssertNil(view.hitTest(CGPoint(x: x, y: 16)))
        }
        view.pointerInWindow = { _ in CGPoint(x: 333, y: 16) }
        view.samplePointer()
        XCTAssertFalse(hovered)
    }

    func testDefaultAutoCollapseWaitsAfterPointerLeaves() throws {
        let model = try model()
        XCTAssertTrue(model.settings.autoCollapse)
        XCTAssertEqual(model.settings.autoCollapseSecs, 20)
        XCTAssertFalse(model.settings.locked)
        let panel = DotistPanel(contentRect: CGRect(x: 100, y: 100, width: 364, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        var now = Date()
        var pointer = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        var environment = PanelMotion.Environment()
        environment.now = { now }
        environment.mouseLocation = { pointer }
        environment.pressedMouseButtons = { 0 }
        environment.pointerEventsEnabled = false
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "test" }, environment: environment)
        defer { motion.stop(); panel.close() }
        now.addTimeInterval(100)
        motion.updateIdleState()
        XCTAssertFalse(motion.bubble)
        pointer = CGPoint(x: -10000, y: -10000)
        now.addTimeInterval(19)
        motion.updateIdleState()
        XCTAssertFalse(motion.bubble)
        now.addTimeInterval(1)
        motion.updateIdleState()
        XCTAssertTrue(motion.bubble)
    }

    func testBlankDoubleClickRejectsRowsMovementAndUnfilteredView() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = TaskListBlankDoubleClick.Observer(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        window.contentView = observer
        defer { observer.stop(); window.close() }
        observer.enabled = true
        observer.origin = CGPoint(x: 0, y: 80)
        observer.excluded = [CGRect(x: 0, y: 80, width: 300, height: 40)]
        var added = 0
        observer.add = { added += 1 }
        func event(_ type: NSEvent.EventType, _ point: CGPoint, count: Int = 2) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: observer.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 0))
        }
        observer.receive(try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        observer.receive(try event(.leftMouseUp, CGPoint(x: 100, y: 100)))
        XCTAssertEqual(added, 1)
        observer.receive(try event(.leftMouseDown, CGPoint(x: 100, y: 20)))
        observer.receive(try event(.leftMouseUp, CGPoint(x: 100, y: 20)))
        XCTAssertEqual(added, 1, "Task rows must not add tasks")
        observer.receive(try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        observer.receive(try event(.leftMouseDragged, CGPoint(x: 110, y: 100)))
        observer.receive(try event(.leftMouseUp, CGPoint(x: 100, y: 100)))
        XCTAssertEqual(added, 1, "Dragging away and back must not become a double click")
        observer.enabled = false
        observer.receive(try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        observer.receive(try event(.leftMouseUp, CGPoint(x: 100, y: 100)))
        XCTAssertEqual(added, 1)
        XCTAssertNil(observer.hitTest(CGPoint(x: 100, y: 100)))
    }

    func testFixedGroupBlankDoubleClickFocusesItsComposer() async throws {
        var groupID = ""
        let model = try model { groupID = try $0.addGroup(name: "Current group").id }
        let state = TaskPanelState(groupID: groupID)
        let fixture = NativeRenderingFixture(MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}), size: CGSize(width: 364, height: 620))
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        let observer = try XCTUnwrap(fixture.descendants(TaskListBlankDoubleClick.Observer.self).first)
        XCTAssertTrue(observer.enabled)
        let local = CGPoint(x: observer.bounds.maxX - 2, y: observer.bounds.maxY - 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: observer.convert(local, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 0))
            observer.receive(event)
        }
        try await Task.sleep(for: .milliseconds(80))
        let group = try XCTUnwrap(accessibilityElement(fixture.host, id: "composer-group"))
        let value = #selector(NSAccessibilityProtocol.accessibilityValue)
        XCTAssertEqual(group.perform(value)?.takeUnretainedValue() as? String, "Current group")
        let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first { $0.currentEditor() != nil })
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("Added from blank", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(30))
        let delegate = try XCTUnwrap(field.delegate as? ComposerInput.Coordinator)
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        for _ in 0..<100 {
            if model.tasks.contains(where: { $0.title == "Added from blank" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.tasks.first { $0.title == "Added from blank" }?.category, groupID)
    }

}
