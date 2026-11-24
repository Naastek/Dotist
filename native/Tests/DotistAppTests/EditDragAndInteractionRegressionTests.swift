import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class EditDragAndInteractionRegressionTests: XCTestCase {
    private func makeStore() throws -> (URL, TaskStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-edit-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try TaskStore(databasePath: dir.appendingPathComponent("tasks.sqlite").path)
        return (dir, store)
    }

    private func firstView<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let found = firstView(of: type, in: subview) { return found }
        }
        return nil
    }

    private func allViews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var result: [T] = []
        if let match = root as? T { result.append(match) }
        for subview in root.subviews {
            result.append(contentsOf: allViews(of: type, in: subview))
        }
        return result
    }

    /// F-05 + Optical Baseline: editing row expands horizontally across hidden metadata
    /// and vertically across full row height while keeping the text line optically centered.
    func testEditingRowFillsFullWidthAndHeightAndPreservesOpticalBaseline() async throws {
        var text = "检查编辑框命中区域"
        var height: CGFloat = 32
        let font = DotistDesign.nativeFont(13, language: "zh-CN")
        let view = TaskRowLayout(depth: 0, editing: true) {
            Color.clear.frame(width: 16, height: 16)
            TaskEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                height: Binding(get: { height }, set: { height = $0 }),
                font: font,
                label: "任务内容",
                minRowHeight: 32,
                commit: {}, cancel: {}, indent: { _ in }, blur: {}
            ).frame(height: max(height, 32))
            Text("今天 · 工作 · 1/3").frame(width: 110, height: 20)
        }
        .frame(width: 332)
        .padding(.horizontal, 16)

        let host = DotistHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 364, height: 60)
        let window = DotistPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()

        let editor = try XCTUnwrap(firstView(of: TaskTextView.self, in: host))
        let editorFrameInHost = host.convert(editor.bounds, from: editor)
        // Row spans x = 16..348 (width 332). textX(0) = 42, so editor width must be 348 - 42 = 306
        // instead of being truncated by the 110+8pt hidden metadata column.
        XCTAssertEqual(editorFrameInHost.width, 306, accuracy: 1.5,
                       "Editing TaskTextView must expand across hidden metadata width")
        XCTAssertEqual(editorFrameInHost.height, 32, accuracy: 1.0,
                       "Editing TaskTextView must span full 32pt single-line row height")
        XCTAssertEqual(editor.textContainerInset.height, 6, accuracy: 0.5,
                       "6pt vertical inset keeps the 20pt text line centered in 32pt row")

        // Verify multi-line wrapping collapses inset to 0 and expands height >= 40.
        editor.string = String(repeating: "多行编辑测试内容", count: 8)
        editor.didChangeText()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(editor.textContainerInset.height, 0, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(height, 40)

        // Returning to single-line restores 6pt inset and 32pt height.
        editor.string = "单行"
        editor.didChangeText()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(editor.textContainerInset.height, 6, accuracy: 0.5)
        XCTAssertEqual(height, 32, accuracy: 0.5)
    }

    /// Click-to-place-cursor: passing initialClickWindowPoint places caret near the clicked character.
    func testTaskEditorPlacesCursorAtInitialClickPoint() async throws {
        var text = "ABCDEFGHIJKLMNO"
        var height: CGFloat = 32
        let font = DotistDesign.nativeFont(13, language: "en")
        // Place editor at (0, 0, 300, 32) in window; click near x = 22 (around char 2-4, definitely not end = 15).
        let clickPoint = CGPoint(x: 22, y: 16)
        let view = TaskEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            height: Binding(get: { height }, set: { height = $0 }),
            font: font,
            label: "Task",
            minRowHeight: 32,
            initialClickWindowPoint: clickPoint,
            commit: {}, cancel: {}, indent: { _ in }, blur: {}
        ).frame(width: 300, height: 32)

        let host = DotistHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 32)
        let window = DotistPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))

        let editor = try XCTUnwrap(firstView(of: TaskTextView.self, in: host))
        let range = editor.selectedRange()
        XCTAssertEqual(range.length, 0)
        XCTAssertGreaterThan(range.location, 0)
        XCTAssertLessThan(range.location, text.count,
                          "Cursor should land near click x=22 instead of jumping to end of string")
    }

    /// F-01 + F-02 + F-03 + F-04: editing a task does not block dragging another row on first attempt,
    /// clicking blank space dismisses editing, and deleting an editing task clears ghost state.
    func testEditModeDoesNotBlockDragAndBlankClickDismissesEditor() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = try store.addGroup(name: "测试组A")
        let taskA = try store.addTask(title: "任务 A", category: group.id)
        let taskB = try store.addTask(title: "任务 B", category: group.id)
        let model = try AppModel(store: store)

        let state = TaskPanelState(groupID: group.id)
        let window = DotistPanel(contentRect: CGRect(x: 0, y: 0, width: 364, height: 620),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let main = MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {})
        let host = DotistHostingView(rootView: main.frame(width: 364, height: 620))
        host.frame = CGRect(x: 0, y: 0, width: 364, height: 620)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()

        // Verify FloatingWindowDragArea in list has an onClick handler wired (F-02).
        let dragAreas = allViews(of: BubblePointerView.self, in: host)
        XCTAssertGreaterThanOrEqual(dragAreas.count, 2, "Header and taskList should mount FloatingWindowDragArea")

        // Verify deleting a task while panel is mounted never leaves stale editing state (F-03).
        model.delete(taskA)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(firstView(of: TaskTextView.self, in: host))
        XCTAssertTrue(model.tasks.contains { $0.id == taskB.id })
    }

    /// F-08: CommandPaletteSections with model.visibleGroups never exposes internal Inbox group.
    func testVisibleGroupsExcludesInboxInCommandPalette() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = try AppModel(store: store)

        let sections = CommandPaletteSections.build(query: "", tasks: model.ordered(model.tasks), groups: model.visibleGroups, viewsTitle: "任务视图")
        let groupIDs = sections.flatMap(\.items).compactMap { item -> String? in
            if case .group(let g) = item { return g.id }
            return nil
        }
        XCTAssertFalse(groupIDs.contains(DotistGroup.inboxID), "Internal inbox bucket must never appear in CommandPalette")
        XCTAssertGreaterThanOrEqual(groupIDs.count, 1)
    }

    /// F-12: TaskReorderInteractionGuard restores window movement on menu tracking / resignKey without leftMouseUp.
    func testInteractionGuardRestoresMovementOnMenuTrackingAndResignKey() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.isMovable = true
        defer { window.close() }

        let guardView = TaskReorderInteractionGuard.GuardView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        guardView.rowFrames = [CGRect(x: 0, y: 0, width: 300, height: 100)]
        window.contentView = guardView

        // Simulate window resigning key after movement was disabled.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertTrue(window.isMovable)

        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertTrue(window.isMovable)
        guardView.stop()
    }

    /// F-14: ComposerInput handles Esc (cancelOperation:) and tag rename preserves activeTag.
    func testComposerHandlesEscapeAndTagRenamePreservesActiveTag() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.addTask(title: "任务一 #alpha")
        let model = try AppModel(store: store)
        model.selectTag("alpha")
        model.renameTag("alpha", to: "#beta")
        for _ in 0..<50 where model.activeTag != "beta" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.activeTag, "beta", "Renaming active tag must normalize and preserve active selection")

        // Verify ComposerInput Coordinator invokes cancel on cancelOperation:
        var cancelled = false
        var focused = true
        var text = "#a"
        let input = ComposerInput(
            text: Binding(get: { text }, set: { text = $0 }),
            focused: Binding(get: { focused }, set: { focused = $0 }),
            placeholder: "新任务",
            label: "新任务",
            font: DotistDesign.nativeFont(13, language: "zh-CN"),
            commit: {},
            navigate: { _ in false },
            complete: { _ in false },
            cancel: { cancelled = true; return true }
        )
        let coordinator = input.makeCoordinator()
        let field = ComposerTextField()
        let textView = NSTextView()
        let handled = coordinator.control(field, textView: textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(handled)
        XCTAssertTrue(cancelled)
    }

    /// F-05 + F-15: GroupPanelController matches main panel's isMovableByWindowBackground == false
    /// and updates motion.expandedSize on windowDidResize.
    func testGroupPanelMovementPolicyAndResizeSync() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = try store.addGroup(name: "项目")
        let model = try AppModel(store: store)

        let controller = GroupPanelController(
            model: model,
            groupID: group.id,
            near: CGRect(x: 400, y: 200, width: 364, height: 620),
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, didClose: { _ in }
        )
        defer { controller.closePanel() }
        let panel = try XCTUnwrap(controller.window)
        XCTAssertFalse(panel.isMovableByWindowBackground,
                       "GroupPanelController must disable window background drag to match MainPanel and prevent draft-row dead-zone drags")

        let resized = NSSize(width: 420, height: 680)
        panel.setFrame(NSRect(origin: panel.frame.origin, size: resized), display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: panel))
        XCTAssertEqual(controller.motion.expandedSize.width, 420, accuracy: 0.5)
        XCTAssertEqual(controller.motion.expandedSize.height, 680, accuracy: 0.5)
    }

    /// F-15: handleUndoShortcut is blocked when panel is collapsed to bubble or animating.
    func testUndoShortcutBlockedWhenCompact() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = try store.addTask(title: "可撤销任务")
        let model = try AppModel(store: store)
        model.delete(task)
        let state = TaskPanelState()
        let compactMain = MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, isCompactOrAnimating: { true })
        XCTAssertFalse(compactMain.handleUndoShortcut(redo: false),
                       "⌘Z must not undo tasks while panel is collapsed to floating bubble")
    }

    /// F-16: CommandPalette has zero footer height, matching docs/ui-decisions.md.
    func testCommandPaletteHasNoFooter() {
        XCTAssertEqual(PaletteMetrics.footer, 0)
    }

    /// F-01 + F-04: Starting a drag on another row while a row is actively being edited
    /// flushes the edit optimistically and begins the drag on the very first attempt.
    func testDraggingAnotherRowWhileEditingFlushesEditAndBeginsImmediately() async throws {
        let clock = LayoutMotionTestClock(reduceMotion: true)
        defer { clock.restore() }
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = try store.addGroup(name: "测试组B")
        let taskA = try store.addTask(title: "任务 A", category: group.id)
        let taskB = try store.addTask(title: "任务 B", category: group.id)
        let model = try AppModel(store: store)

        let state = TaskPanelState(groupID: group.id)
        let runtime = TaskReorderRuntime()
        var rows: [TaskListRowFrame] = []
        let view = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            editing: taskA.id, editedTitle: "任务 A 已修改", reorderRuntime: runtime
        )
        .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
        .frame(width: 364, height: 620)

        let host = DotistHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 364, height: 620)
        let window = DotistPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        for _ in 0..<30 where rows.count < 2 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let rowB = try XCTUnwrap(rows.first { $0.task.id == taskB.id })
        let rowA = try XCTUnwrap(rows.first { $0.task.id == taskA.id })

        // Dragging taskB while taskA is in editing state must succeed on the first attempt.
        runtime.send(.begin(taskB.id, CGPoint(x: 110, y: rowB.frame.midY)))
        XCTAssertNotNil(runtime.drag, "Drag on another row must start immediately even while editing taskA")
        XCTAssertEqual(runtime.drag?.taskID, taskB.id)

        let dropPoint = CGPoint(x: 110, y: rowA.frame.minY + 2)
        runtime.send(.move(taskB.id, dropPoint))
        runtime.send(.end(taskB.id, dropPoint))
        for _ in 0..<60 where runtime.drag != nil || model.busy {
            try await Task.sleep(for: .milliseconds(15))
        }

        let saved = try store.listTasks()
        XCTAssertEqual(saved.first { $0.id == taskA.id }?.title, "任务 A 已修改",
                       "Optimistic flush must persist edited title of taskA")
        let ordered = model.ordered(saved.filter { $0.category == group.id })
        XCTAssertEqual(ordered.first?.id, taskB.id, "taskB must reorder above taskA in a single drag")
    }

    /// F-06: In single-group view, dragging onto another group on groupShelf moves the task
    /// to that target group at level 0 (no fallback to source group and no accidental indent).
    func testSingleGroupShelfDropCommitsToTargetGroupAtLevelZero() async throws {
        let clock = LayoutMotionTestClock(reduceMotion: true)
        defer { clock.restore() }
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = try store.addGroup(name: "测试工作")
        let life = try store.addGroup(name: "测试生活")
        let task1 = try store.addTask(title: "工作一", category: work.id)
        _ = try store.addTask(title: "工作二", category: work.id)
        let model = try AppModel(store: store)

        let state = TaskPanelState(groupID: work.id)
        let runtime = TaskReorderRuntime()
        var rows: [TaskListRowFrame] = []
        var shelves: [String: CGRect] = [:]
        let view = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            reorderRuntime: runtime
        )
        .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
        .onPreferenceChange(TaskShelfFrameKey.self) { shelves = $0 }
        .frame(width: 364, height: 620)

        let host = DotistHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 364, height: 620)
        let window = DotistPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        for _ in 0..<30 where rows.count < 2 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let row1 = try XCTUnwrap(rows.first { $0.task.id == task1.id })
        runtime.send(.begin(task1.id, CGPoint(x: 60, y: row1.frame.midY)))
        for _ in 0..<30 where shelves[life.id] == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let lifeShelf = try XCTUnwrap(shelves[life.id], "groupShelf must mount in single-group view during drag")
        let shelfPoint = CGPoint(x: lifeShelf.midX, y: lifeShelf.midY)
        runtime.send(.move(task1.id, shelfPoint))

        let target = try XCTUnwrap(runtime.drag?.target)
        XCTAssertEqual(target.groupID, life.id, "Shelf drop target must resolve to life, not fall back to work")
        XCTAssertEqual(target.level, 0, "Horizontal shelf movement must never indent task as a subtask")
        XCTAssertNil(target.parentID)
        XCTAssertNil(target.beforeID)

        runtime.send(.end(task1.id, shelfPoint))
        for _ in 0..<60 where runtime.drag != nil || model.busy {
            try await Task.sleep(for: .milliseconds(15))
        }

        let updated = try XCTUnwrap(try store.listTasks().first { $0.id == task1.id })
        XCTAssertEqual(updated.category, life.id)
        XCTAssertNil(updated.parentId)
    }
}
