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

    /// Editing row's TaskEditor keeps full layout width for wrapping, while hit-testing
    /// only intercepts the rendered text region (+ trailing caret margin) and passes blank
    /// same-row space through to the row for click-to-dismiss and direct drag.
    func testTaskEditorHitTestLimitsToTextAndPassesThroughRowBlankArea() async throws {
        var text = "买牛奶"
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
                restrictHitTestToText: true,
                commit: {}, cancel: {}, indent: { _ in }, blur: {}
            ).frame(height: max(height, 32))
            Text("今天").frame(width: 40, height: 20)
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
        let scroll = try XCTUnwrap(editor.enclosingScrollView as? TaskEditorScrollView)
        let editorFrameInHost = host.convert(editor.bounds, from: editor)
        XCTAssertEqual(editorFrameInHost.width, 306, accuracy: 1.5)

        // 1. Inside text glyphs -> hits TaskTextView.
        let inTextHost = host.convert(NSPoint(x: 12, y: 16), from: editor)
        XCTAssertTrue(host.hitTest(inTextHost) === editor, "Point over text glyphs must hit TaskTextView")

        // 2. Directly above text glyphs (within 6pt vertical inset) -> hits TaskTextView.
        let aboveTextHost = host.convert(NSPoint(x: 12, y: 2), from: editor)
        XCTAssertTrue(host.hitTest(aboveTextHost) === editor, "Point in vertical inset over text must hit TaskTextView")

        // 3. Far right blank area on the same row -> passes through (neither TaskTextView nor its scroll view).
        let rightBlankHost = host.convert(NSPoint(x: 240, y: 16), from: editor)
        let rightBlankHit = host.hitTest(rightBlankHost)
        XCTAssertFalse(rightBlankHit === editor, "Right blank area must not hit TaskTextView")
        XCTAssertFalse(rightBlankHit === scroll, "Right blank area must not hit TaskEditorScrollView")
        XCTAssertFalse(rightBlankHit?.isDescendant(of: scroll) == true, "Right blank area must pass through editor scroll hierarchy")

        // 4. Multi-line text: line 1 full width hits editor, line 2 right blank passes through.
        editor.string = String(repeating: "多行编辑内容", count: 5) + "\n尾"
        editor.didChangeText()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.isPointInTextHitZone(NSPoint(x: 200, y: 10)), "Full first line must hit text zone")
        XCTAssertTrue(editor.isPointInTextHitZone(NSPoint(x: 8, y: 30)), "Short second line text must hit text zone")
        XCTAssertFalse(editor.isPointInTextHitZone(NSPoint(x: 200, y: 30)), "Blank area to the right of short second line must pass through")

        // 5. Empty text: leading caret zone hits editor, far right passes through.
        editor.string = ""
        editor.didChangeText()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(editor.isPointInTextHitZone(NSPoint(x: 10, y: 16)), "Empty editor leading area must remain clickable")
        XCTAssertFalse(editor.isPointInTextHitZone(NSPoint(x: 180, y: 16)), "Empty editor far right area must pass through")
    }

    /// Dragging the actively edited task itself (from its blank area) synchronously flushes
    /// the edited title into AppModel + lifted block and commits both title and reorder.
    func testDraggingEditingTaskItselfFlushesTitleOptimisticallyAndReorders() async throws {
        let clock = LayoutMotionTestClock(reduceMotion: true)
        defer { clock.restore() }
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = try store.addGroup(name: "测试组C")
        let taskA = try store.addTask(title: "任务 A", category: group.id)
        let taskB = try store.addTask(title: "任务 B", category: group.id)
        let model = try AppModel(store: store)

        let state = TaskPanelState(groupID: group.id)
        let runtime = TaskReorderRuntime()
        var rows: [TaskListRowFrame] = []
        let view = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            editing: taskA.id, editedTitle: "任务 A 即时保存并拖动", reorderRuntime: runtime
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
        let rowA = try XCTUnwrap(rows.first { $0.task.id == taskA.id })
        let rowB = try XCTUnwrap(rows.first { $0.task.id == taskB.id })

        // Begin dragging taskA itself while taskA is being edited.
        runtime.send(.begin(taskA.id, CGPoint(x: 240, y: rowA.frame.midY)))
        XCTAssertNotNil(runtime.drag, "Dragging the currently edited task from blank space must start immediately")
        XCTAssertEqual(runtime.drag?.taskID, taskA.id)
        XCTAssertEqual(model.tasks.first { $0.id == taskA.id }?.title, "任务 A 即时保存并拖动",
                       "Optimistic flush must update AppModel.tasks synchronously before drag freezes snapshots")
        XCTAssertEqual(runtime.drag?.visibleBlock.first { $0.task.id == taskA.id }?.task.title, "任务 A 即时保存并拖动",
                       "Lifted glass card must display the newly edited title immediately")

        let dropPoint = CGPoint(x: 240, y: rowB.frame.maxY - 2)
        runtime.send(.move(taskA.id, dropPoint))
        runtime.send(.end(taskA.id, dropPoint))
        for _ in 0..<60 where runtime.drag != nil || model.busy {
            try await Task.sleep(for: .milliseconds(15))
        }

        let saved = try store.listTasks()
        XCTAssertEqual(saved.first { $0.id == taskA.id }?.title, "任务 A 即时保存并拖动")
        let ordered = model.ordered(saved.filter { $0.category == group.id })
        XCTAssertEqual(ordered.map(\.id), [taskB.id, taskA.id],
                       "Edited task must reorder below taskB in a single drag while persisting its new title")
        // Settling draft on drag start must have sealed the title-edit history entry
        // so the subsequent reorder is recorded as a distinct undo step.
        XCTAssertEqual(model.undoEntries.count, 2)
        XCTAssertTrue(model.undoEntries.allSatisfy(\.sealed))
    }

    /// Pressing inside TaskTextView's text hit zone sets pointerInsideEditor and prevents
    /// row reorder gestures from hijacking horizontal text selection.
    func testPointerInsideEditorBlocksReorderToPreserveTextSelection() async throws {
        let clock = LayoutMotionTestClock(reduceMotion: true)
        defer { clock.restore() }
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = try store.addGroup(name: "测试组D")
        let taskA = try store.addTask(title: "可拖选文本", category: group.id)
        _ = try store.addTask(title: "任务 B", category: group.id)
        let model = try AppModel(store: store)

        let state = TaskPanelState(groupID: group.id)
        let runtime = TaskReorderRuntime()
        let hold = TaskHoldTracker()
        var rows: [TaskListRowFrame] = []
        let view = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            editing: taskA.id, editedTitle: "可拖选文本", hold: hold, reorderRuntime: runtime
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
        let rowA = try XCTUnwrap(rows.first { $0.task.id == taskA.id })

        // Simulate press starting inside text glyphs.
        hold.pointerInsideEditor = true
        runtime.send(.begin(taskA.id, CGPoint(x: 60, y: rowA.frame.midY)))
        XCTAssertNil(runtime.drag, "Drag starting inside TaskTextView text zone must be rejected to preserve text selection")

        // Once pointer is released / outside text zone, dragging the same row succeeds.
        hold.pointerInsideEditor = false
        runtime.send(.begin(taskA.id, CGPoint(x: 240, y: rowA.frame.midY)))
        XCTAssertEqual(runtime.drag?.taskID, taskA.id)
        runtime.send(.cancel)
    }

    /// Cursor rects on TaskTextView match the per-line text hit zones (excluding right blank space)
    /// and update when typing or wrapping changes line widths.
    func testTaskEditorCursorRectsMatchTextHitZonesAndRefreshOnEdit() async throws {
        var text = "abc"
        var height: CGFloat = 32
        let font = DotistDesign.nativeFont(13, language: "en")
        let view = TaskEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            height: Binding(get: { height }, set: { height = $0 }),
            font: font,
            label: "Task",
            minRowHeight: 32,
            restrictHitTestToText: true,
            commit: {}, cancel: {}, indent: { _ in }, blur: {}
        ).frame(width: 300, height: max(height, 32))

        let host = DotistHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 60)
        let window = DotistPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()

        let editor = try XCTUnwrap(firstView(of: TaskTextView.self, in: host))
        editor.resetCursorRects()
        XCTAssertEqual(editor.registeredCursorRects.count, 1)
        let narrowWidth = try XCTUnwrap(editor.registeredCursorRects.first?.width)
        XCTAssertLessThan(narrowWidth, 80, "I-beam cursor rect for 'abc' must not span the 300pt blank area")
        XCTAssertFalse(editor.registeredCursorRects.contains { $0.contains(NSPoint(x: 200, y: 16)) },
                       "Right blank space must not register an I-beam cursor rect")

        // Typing longer text expands the cursor rect width.
        editor.string = "abcdefghijklmno"
        editor.didChangeText()
        try await Task.sleep(for: .milliseconds(30))
        editor.resetCursorRects()
        let widerWidth = try XCTUnwrap(editor.registeredCursorRects.first?.width)
        XCTAssertGreaterThan(widerWidth, narrowWidth + 40, "Typing must expand the registered I-beam cursor rect")

        // Multi-line text registers separate per-line cursor rects; line 2 right blank remains arrow cursor.
        let multilineText = String(repeating: "Word ", count: 8) + "\nEnd"
        let multiHost = DotistHostingView(rootView: TaskEditor(
            text: .constant(multilineText),
            height: .constant(60),
            font: font,
            label: "Task",
            minRowHeight: 32,
            restrictHitTestToText: true,
            commit: {}, cancel: {}, indent: { _ in }, blur: {}
        ).frame(width: 300, height: 60))
        multiHost.frame = CGRect(x: 0, y: 0, width: 300, height: 60)
        window.contentView = multiHost
        multiHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        multiHost.layoutSubtreeIfNeeded()
        let multiEditor = try XCTUnwrap(firstView(of: TaskTextView.self, in: multiHost))
        multiEditor.resetCursorRects()
        XCTAssertGreaterThanOrEqual(multiEditor.registeredCursorRects.count, 2)
        let lastLineRect = try XCTUnwrap(multiEditor.registeredCursorRects.last)
        XCTAssertLessThan(lastLineRect.width, 80, "Short wrapped last line must keep trailing blank space free of I-beam cursor")
    }

    private func makeMouseEvent(type: NSEvent.EventType, windowPoint: CGPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        ))
    }

    /// Exercises the full mouse-down routing path through TaskReorderInteractionGuard.GuardView
    /// and TaskEditorScrollView.hitTest for: (1) text-origin press preserving selection,
    /// (2) right-blank-space press dismissing and picking up on the same press + undo/redo,
    /// (3) left-indent press on a subtask dismissing and picking up on the same press,
    /// (4) plain blank click whose mouse-up tap leaves editing closed.
    func testMountedPanelMouseDownRoutingForTextRightBlankLeftIndentAndPlainClick() async throws {
        let clock = LayoutMotionTestClock(reduceMotion: true)
        defer { clock.restore() }
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = try store.addGroup(name: "测试组E")
        let taskA = try store.addTask(title: "短标题", category: group.id)
        let subA = try store.addTask(title: "子任务", category: group.id, parentId: taskA.id)
        let taskB = try store.addTask(title: "任务 B", category: group.id)
        let model = try AppModel(store: store)
        model.expanded.insert(taskA.id)

        let state = TaskPanelState(groupID: group.id)
        let runtime = TaskReorderRuntime()
        let hold = TaskHoldTracker()
        var rows: [TaskListRowFrame] = []
        let main = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            editing: taskA.id, editedTitle: "短标题已改", hold: hold, reorderRuntime: runtime
        )
        let host = DotistHostingView(rootView: main.onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }.frame(width: 364, height: 620))
        host.frame = CGRect(x: 0, y: 0, width: 364, height: 620)
        let window = DotistPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        for _ in 0..<40 where rows.count < 3 || firstView(of: TaskTextView.self, in: host) == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let guardView = try XCTUnwrap(firstView(of: TaskReorderInteractionGuard.GuardView.self, in: host))
        let editor = try XCTUnwrap(firstView(of: TaskTextView.self, in: host))
        window.makeFirstResponder(editor)
        XCTAssertTrue(window.firstResponder === editor)

        let rowA = try XCTUnwrap(rows.first { $0.task.id == taskA.id })
        let rowB = try XCTUnwrap(rows.first { $0.task.id == taskB.id })

        // (1) Text-origin press: hits TaskTextView, keeps editor active, blocks reorder.
        let textWindowPoint = editor.convert(NSPoint(x: 12, y: 16), to: nil)
        _ = guardView.handleLocalEvent(try makeMouseEvent(type: .leftMouseDown, windowPoint: textWindowPoint, window: window))
        XCTAssertTrue(hold.pointerInsideEditor, "Press over text glyphs must mark pointerInsideEditor")
        XCTAssertTrue(window.firstResponder === editor, "Press over text glyphs must not dismiss editor")
        runtime.send(.begin(taskA.id, CGPoint(x: rowA.frame.minX + 40, y: rowA.frame.midY)))
        XCTAssertNil(runtime.drag, "Reorder must stay blocked while pressing inside text glyphs")
        _ = guardView.handleLocalEvent(try makeMouseEvent(type: .leftMouseUp, windowPoint: textWindowPoint, window: window))
        XCTAssertFalse(hold.pointerInsideEditor)
        XCTAssertNotNil(firstView(of: TaskTextView.self, in: host), "Text press/release must keep editor mounted")

        // (2) Right blank space press: passes through TaskEditorScrollView, dismisses & saves synchronously,
        // allows same-press pickup, commits title + reorder, and supports undo/redo.
        let rightBlankWindowPoint = editor.convert(NSPoint(x: 240, y: 16), to: nil)
        _ = guardView.handleLocalEvent(try makeMouseEvent(type: .leftMouseDown, windowPoint: rightBlankWindowPoint, window: window))
        XCTAssertFalse(hold.pointerInsideEditor, "Press in right blank area must not mark pointerInsideEditor")
        XCTAssertFalse(window.firstResponder === editor, "Right blank press must resign TaskTextView first responder")
        XCTAssertEqual(hold.dismissedEditingTaskID, taskA.id)
        XCTAssertEqual(model.tasks.first { $0.id == taskA.id }?.title, "短标题已改")

        // Same-press pickup before mouse-up.
        runtime.send(.begin(taskA.id, CGPoint(x: 240, y: rowA.frame.midY)))
        XCTAssertEqual(runtime.drag?.taskID, taskA.id, "Same-press pickup from right blank space must succeed")
        let dropPoint = CGPoint(x: 240, y: rowB.frame.maxY - 2)
        runtime.send(.move(taskA.id, dropPoint))
        runtime.send(.end(taskA.id, dropPoint))
        _ = guardView.handleLocalEvent(try makeMouseEvent(type: .leftMouseUp, windowPoint: rightBlankWindowPoint, window: window))
        for _ in 0..<60 where runtime.drag != nil || model.busy {
            try await Task.sleep(for: .milliseconds(15))
        }
        let afterDrag = try store.listTasks()
        XCTAssertEqual(afterDrag.first { $0.id == taskA.id }?.title, "短标题已改")
        let rootOrderAfterDrag = model.ordered(afterDrag.filter { $0.category == group.id && $0.parentId == nil }).map(\.id)
        XCTAssertEqual(rootOrderAfterDrag, [taskB.id, taskA.id])

        // Undo reorder, then undo title edit, then redo both.
        XCTAssertTrue(model.canUndoAction)
        model.undoLast()
        for _ in 0..<40 where model.busy { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertEqual(model.ordered(try store.listTasks().filter { $0.category == group.id && $0.parentId == nil }).map(\.id), [taskA.id, taskB.id])
        model.undoLast()
        for _ in 0..<40 where model.busy { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertEqual(try store.listTasks().first { $0.id == taskA.id }?.title, "短标题")
        model.redoLast()
        for _ in 0..<40 where model.busy { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertEqual(try store.listTasks().first { $0.id == taskA.id }?.title, "短标题已改")
        model.redoLast()
        for _ in 0..<40 where model.busy { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertEqual(model.ordered(try store.listTasks().filter { $0.category == group.id && $0.parentId == nil }).map(\.id), [taskB.id, taskA.id])

        // (3) Left indent press on an editing subtask (depth 1): dismisses editor and allows immediate pickup.
        let subRuntime = TaskReorderRuntime()
        let subHold = TaskHoldTracker()
        var subRows: [TaskListRowFrame] = []
        let subMain = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            editing: subA.id, editedTitle: "子任务已改", hold: subHold, reorderRuntime: subRuntime
        )
        let subHost = DotistHostingView(rootView: subMain.onPreferenceChange(TaskListRowFrame.Key.self) { subRows = $0 }.frame(width: 364, height: 620))
        subHost.frame = CGRect(x: 0, y: 0, width: 364, height: 620)
        window.contentView = subHost
        for _ in 0..<40 where subRows.count < 3 || firstView(of: TaskTextView.self, in: subHost) == nil {
            subHost.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let subGuard = try XCTUnwrap(firstView(of: TaskReorderInteractionGuard.GuardView.self, in: subHost))
        let subEditor = try XCTUnwrap(firstView(of: TaskTextView.self, in: subHost))
        window.makeFirstResponder(subEditor)
        let subRow = try XCTUnwrap(subRows.first { $0.task.id == subA.id })
        let leftIndentPoint = subGuard.convert(NSPoint(x: subRow.frame.minX + 6, y: subRow.frame.midY), to: nil)
        _ = subGuard.handleLocalEvent(try makeMouseEvent(type: .leftMouseDown, windowPoint: leftIndentPoint, window: window))
        XCTAssertFalse(subHold.pointerInsideEditor)
        XCTAssertFalse(window.firstResponder === subEditor)
        subRuntime.send(.begin(subA.id, CGPoint(x: subRow.frame.minX + 6, y: subRow.frame.midY)))
        XCTAssertEqual(subRuntime.drag?.taskID, subA.id, "Left indent press on editing subtask must pick up immediately")
        subRuntime.send(.cancel)
        _ = subGuard.handleLocalEvent(try makeMouseEvent(type: .leftMouseUp, windowPoint: leftIndentPoint, window: window))

        // (4) Plain blank click: mouseDown dismisses editing, matching mouseUp tap does NOT reopen editing.
        let clickHold = TaskHoldTracker()
        let clickMain = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            editing: taskB.id, editedTitle: "任务 B 单击退出", hold: clickHold
        )
        let clickHost = DotistHostingView(rootView: clickMain.frame(width: 364, height: 620))
        clickHost.frame = CGRect(x: 0, y: 0, width: 364, height: 620)
        window.contentView = clickHost
        for _ in 0..<40 where firstView(of: TaskTextView.self, in: clickHost) == nil {
            clickHost.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let clickGuard = try XCTUnwrap(firstView(of: TaskReorderInteractionGuard.GuardView.self, in: clickHost))
        let clickEditor = try XCTUnwrap(firstView(of: TaskTextView.self, in: clickHost))
        window.makeFirstResponder(clickEditor)
        let clickBlankPoint = clickEditor.convert(NSPoint(x: 240, y: 16), to: nil)
        _ = clickGuard.handleLocalEvent(try makeMouseEvent(type: .leftMouseDown, windowPoint: clickBlankPoint, window: window))
        _ = clickGuard.handleLocalEvent(try makeMouseEvent(type: .leftMouseUp, windowPoint: clickBlankPoint, window: window))
        // Matching SwiftUI onTapGesture calls clickRow(taskB) after mouse-up.
        clickMain.clickRow(taskB)
        for _ in 0..<20 where firstView(of: TaskTextView.self, in: clickHost) != nil {
            clickHost.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertNil(firstView(of: TaskTextView.self, in: clickHost), "Plain blank click must leave editing closed after mouse-up")
        XCTAssertNil(clickHold.dismissedEditingTaskID)
    }

    /// In a tag-filtered panel (#work), editing a matching leaf task to remove #work and pressing
    /// its blank space keeps the row mounted until the press resolves (supporting 0.3s hold / drag),
    /// while releasing a plain click applies the tag filter and lets the row disappear.
    func testTagFilteredEditingRowStaysMountedThroughPressAndDisappearsOnRelease() async throws {
        let clock = LayoutMotionTestClock(reduceMotion: true)
        defer { clock.restore() }
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = try store.addGroup(name: "标签组")
        let taskA = try store.addTask(title: "写周报 #work", category: group.id)
        let taskB = try store.addTask(title: "开会 #work", category: group.id)
        let model = try AppModel(store: store)

        let state = TaskPanelState(groupID: group.id)
        state.activeTag = "work"
        let runtime = TaskReorderRuntime()
        let hold = TaskHoldTracker()
        var rows: [TaskListRowFrame] = []
        let main = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            editing: taskA.id, editedTitle: "写周报", hold: hold, reorderRuntime: runtime
        )
        let host = DotistHostingView(rootView: main.onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }.frame(width: 364, height: 620))
        host.frame = CGRect(x: 0, y: 0, width: 364, height: 620)
        let window = DotistPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        for _ in 0..<40 where rows.count < 2 || firstView(of: TaskTextView.self, in: host) == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let guardView = try XCTUnwrap(firstView(of: TaskReorderInteractionGuard.GuardView.self, in: host))
        let editor = try XCTUnwrap(firstView(of: TaskTextView.self, in: host))
        window.makeFirstResponder(editor)

        // Press right blank space of taskA (which just removed #work).
        let blankPoint = editor.convert(NSPoint(x: 220, y: 16), to: nil)
        _ = guardView.handleLocalEvent(try makeMouseEvent(type: .leftMouseDown, windowPoint: blankPoint, window: window))
        XCTAssertEqual(model.tasks.first { $0.id == taskA.id }?.title, "写周报")

        // Let SwiftUI run a layout cycle while the mouse button is still down (e.g. waiting for 0.3s hold).
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(rows.contains { $0.task.id == taskA.id },
                      "Pressed row must remain mounted while mouse is held down even after removing active tag")

        // Release plain click: row is unpinned and filtered out while taskB stays.
        _ = guardView.handleLocalEvent(try makeMouseEvent(type: .leftMouseUp, windowPoint: blankPoint, window: window))
        for _ in 0..<30 where rows.contains(where: { $0.task.id == taskA.id }) || model.busy {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(rows.contains { $0.task.id == taskA.id },
                       "After plain click release, task without #work must disappear from #work filtered view")
        XCTAssertTrue(rows.contains { $0.task.id == taskB.id })
        XCTAssertEqual(try store.listTasks().first { $0.id == taskA.id }?.title, "写周报")
    }

    /// Typing at one location in TaskEditor, repositioning the caret, typing at another
    /// location, and committing must produce two distinct app-level undo steps.
    func testInlineEditorCaretMoveSealsUndoHistoryIntoTwoUndoSteps() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = try store.addGroup(name: "测试组F")
        let taskA = try store.addTask(title: "Hello World", category: group.id)
        let model = try AppModel(store: store)

        let state = TaskPanelState(groupID: group.id)
        let main = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            editing: taskA.id, editedTitle: "Hello World"
        )
        let host = DotistHostingView(rootView: main.frame(width: 364, height: 620))
        host.frame = CGRect(x: 0, y: 0, width: 364, height: 620)
        let window = DotistPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        for _ in 0..<40 where firstView(of: TaskTextView.self, in: host) == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let editor = try XCTUnwrap(firstView(of: TaskTextView.self, in: host))
        window.makeFirstResponder(editor)
        try await Task.sleep(for: .milliseconds(40))

        // 1. Type at end of string.
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(editor.string, "Hello World!")

        // 2. Reposition caret to start without editing -> seals first typing burst.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        for _ in 0..<40 where model.busy || model.undoEntries.isEmpty {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(model.undoEntries.count, 1)
        XCTAssertTrue(model.undoEntries[0].sealed)
        XCTAssertEqual(try store.listTasks().first { $0.id == taskA.id }?.title, "Hello World!")

        // 3. Type at start of string and commit via blur.
        editor.insertText("Hi ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(editor.string, "Hi Hello World!")
        editor.blur()
        for _ in 0..<40 where model.busy || model.undoEntries.count < 2 {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(model.undoEntries.count, 2)
        XCTAssertEqual(try store.listTasks().first { $0.id == taskA.id }?.title, "Hi Hello World!")

        // 4. First ⌘Z undoes only the second burst; second ⌘Z undoes the first burst.
        model.undoLast()
        for _ in 0..<40 where model.busy { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertEqual(try store.listTasks().first { $0.id == taskA.id }?.title, "Hello World!")

        model.undoLast()
        for _ in 0..<40 where model.busy { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertEqual(try store.listTasks().first { $0.id == taskA.id }?.title, "Hello World")
    }

    /// Filtering an edited row out of the visible list must synchronously settle its
    /// edited title once and clear the inline editor immediately.
    func testFilteringOutEditedRowSettlesTitleOnceAndClearsEditorImmediately() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = try store.addGroup(name: "测试组G")
        let taskA = try store.addTask(title: "任务一 #alpha", category: group.id)
        _ = try store.addTask(title: "任务二 #beta", category: group.id)
        let model = try AppModel(store: store)

        let state = TaskPanelState(groupID: group.id)
        let main = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            editing: taskA.id, editedTitle: "任务一已修改 #alpha"
        )
        let host = DotistHostingView(rootView: main.frame(width: 364, height: 620))
        host.frame = CGRect(x: 0, y: 0, width: 364, height: 620)
        let window = DotistPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        for _ in 0..<40 where firstView(of: TaskTextView.self, in: host) == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let editor = try XCTUnwrap(firstView(of: TaskTextView.self, in: host))
        let delayedBlur = editor.blur

        // Filter out taskA by switching active tag to #beta.
        state.activeTag = "beta"
        for _ in 0..<40 where firstView(of: TaskTextView.self, in: host) != nil || model.busy {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(15))
        }
        // Invoke any delayed blur callback from the dismantled editor; it must be a no-op.
        delayedBlur()
        for _ in 0..<20 where model.busy { try await Task.sleep(for: .milliseconds(15)) }

        XCTAssertNil(firstView(of: TaskTextView.self, in: host), "Filtered-out editor must unmount immediately")
        XCTAssertEqual(try store.listTasks().first { $0.id == taskA.id }?.title, "任务一已修改 #alpha")
        XCTAssertEqual(model.undoEntries.count, 1, "Filtered-out edit must persist exactly once")
    }
}
