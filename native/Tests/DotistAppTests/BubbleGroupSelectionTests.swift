import AppKit
import DotistCore
import GRDB
import SwiftUI
import XCTest
@testable import DotistApp

/// Exercise the content property consumed by FloatingPanelView's actual bubble,
/// with groupName == nil as in DotistApp's main panel, rather than supplying an ID.
@MainActor
final class BubbleGroupSelectionTests: XCTestCase {
    private let area = NSRect(x: 0, y: 0, width: 1600, height: 1000)

    private func fixture() throws -> (AppModel, DotistTask, DotistTask) {
        _ = NSApplication.shared
        let root = ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("bubble-selection-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let work = try store.addTask(title: "Work first #focus", category: "work", dueDate: "2027-02-12")
        _ = try store.addTask(title: "Work second #focus", category: "work", dueDate: "2027-02-12")
        let life = try store.addTask(title: "Life has a distinctly longer title #focus", category: "life", dueDate: "2027-02-12")
        _ = try store.addTask(title: "Life second #other", category: "life", dueDate: "2027-02-13")
        _ = try store.addTask(title: "Child", category: "life", parentId: life.id)
        let done = try store.addTask(title: "Done life", category: "life")
        _ = try store.patchTask(id: done.id, completed: true)
        let db = store.database
        try db.write { db in
            try db.execute(sql: "UPDATE tasks SET position=100 WHERE category='life'")
            try db.execute(sql: "UPDATE tasks SET position=50 WHERE category='life' AND id<>?", arguments: [life.id])
            try db.execute(sql: "UPDATE tasks SET position=0 WHERE id=?", arguments: [work.id])
            try db.execute(sql: "UPDATE tasks SET position=10 WHERE id=?", arguments: [life.id])
        }
        return (try AppModel(store: store), work, life)
    }

    private func state(_ groupID: String? = "life") -> TaskPanelState {
        TaskPanelState(groupID: groupID, collapseStore: TaskGroupCollapseStore(defaults: MemoryDefaults()))
    }

    private func view(_ model: AppModel, _ state: TaskPanelState, groupName: String? = nil) -> FloatingPanelView<EmptyView> {
        let panel = DotistPanel(contentRect: NSRect(x: 100, y: 100, width: 364, height: 620),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let input = PanelMotionTestEnvironment(area: area)
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size,
                                 title: { model.bubbleTitle }, environment: input.environment)
        // Same binding installed by FloatingPanelView.onAppear, without desktop input.
        motion.filterState = state
        motion.filterLines = state.filterParts(in: model, includeGroup: groupName == nil)
        addTeardownBlock { motion.stop(); panel.close() }
        return FloatingPanelView(model: model, motion: motion, colorState: state,
            title: model.bubbleTitle, remaining: model.remainingCount, total: model.topLevelTasks.count,
            groupName: groupName, contextMenu: { _, _ in }, content: EmptyView())
    }

    func testMainPanelSelectionDrivesTaskMetadataCountFilterAndMeasuredWidth() throws {
        let (model, work, life) = try fixture()
        XCTAssertEqual(model.nextTask?.id, work.id, "Work must precede life globally to reproduce the bug")
        let view = view(model, state())
        XCTAssertEqual(view.bubbleContent.task?.id, life.id)
        XCTAssertEqual(view.bubbleContent.title, life.title)
        XCTAssertEqual(view.bubbleContent.group, model.groupDisplayName("life"))
        XCTAssertEqual(view.bubbleContent.remaining, 2, "Only open roots in life count")
        XCTAssertEqual(view.filter, [model.groupDisplayName("life")])
        view.motion.toggleBubble(in: area, animated: false)
        view.motion.setHover(true, in: area)
        let expected = min(ceil(86 + view.bubbleContent.textWidth(language: model.language)) + view.motion.filterExtra, 440)
        XCTAssertEqual(view.motion.panel.frame.width, expected, accuracy: 0.01,
                       "Hover geometry and rendered content must use the same selection")
    }

    func testSwitchingMainSelectionUpdatesImmediatelyAndAllRemainsCrossGroup() throws {
        let (model, work, life) = try fixture()
        let state = state()
        let view = view(model, state)
        XCTAssertEqual(view.bubbleContent.task?.id, life.id)
        state.groupID = "work"
        XCTAssertEqual(view.bubbleContent.task?.id, work.id)
        XCTAssertEqual(view.filter, [model.groupDisplayName("work")])
        state.groupID = nil
        XCTAssertEqual(view.bubbleContent.task?.id, work.id)
        XCTAssertEqual(view.bubbleContent.remaining, 4)
        XCTAssertTrue(view.filter.isEmpty)
        state.groupID = "life"
        XCTAssertEqual(view.bubbleContent.task?.id, life.id)
    }

    func testEmptySelectedGroupNeverFallsBackToGlobalWorkTaskOrTitle() throws {
        let (initial, work, _) = try fixture()
        let db = initial.core.database
        try db.write { db in try db.execute(sql: "DELETE FROM tasks WHERE category='life'") }
        let model = try AppModel(store: initial.core)
        let view = view(model, state())
        XCTAssertEqual(model.nextTask?.id, work.id)
        XCTAssertNil(view.bubbleContent.task)
        XCTAssertNil(view.bubbleContent.group)
        XCTAssertNil(view.bubbleContent.due)
        XCTAssertEqual(view.bubbleContent.remaining, 0)
        XCTAssertEqual(view.bubbleContent.title, model.groupDisplayName("life"))
        XCTAssertEqual(view.filter, [model.groupDisplayName("life")])
    }

    func testMainDateAndTagFiltersStayWithinSelectedGroupIncludingEmptyResults() throws {
        let (model, work, life) = try fixture()
        let state = state()
        state.customStart = "2027-02-12"
        state.activeTag = "focus"
        model.selectTag("other")
        let view = view(model, state)
        XCTAssertEqual(view.bubbleContent.task?.id, life.id)
        XCTAssertEqual(view.bubbleContent.remaining, 1)
        XCTAssertEqual(view.filter, [model.groupDisplayName("life"), model.dueLabel("2027-02-12"), "#focus"])
        state.groupID = "work"
        XCTAssertEqual(view.bubbleContent.task?.id, work.id)
        XCTAssertEqual(view.bubbleContent.remaining, 2)
        state.groupID = "life"
        state.scope = "undated"
        state.activeTag = "missing"
        state.customStart = nil
        XCTAssertNil(view.bubbleContent.task)
        XCTAssertEqual(view.bubbleContent.remaining, 0)
        XCTAssertEqual(view.bubbleContent.title, model.text("没有符合筛选的任务"))
    }

    func testDoneKeepsExistingOpenRootBubbleSemanticsWithinSelectedGroup() throws {
        let (model, _, life) = try fixture()
        let state = state()
        state.scope = "done"
        state.activeTag = "no-match"
        let view = view(model, state)
        XCTAssertEqual(view.bubbleContent.task?.id, life.id)
        XCTAssertEqual(view.bubbleContent.remaining, 2)
    }

    func testBlankAndDuplicateGroupNamesNeverDetermineIdentity() throws {
        let (initial, work, life) = try fixture()
        let db = initial.core.database
        for name in ["", "Same name"] {
            try db.write { db in
                try db.execute(sql: "UPDATE task_groups SET name=? WHERE id IN ('work','life')", arguments: [name])
            }
            let model = try AppModel(store: initial.core)
            let state = state()
            let view = view(model, state)
            XCTAssertEqual(view.bubbleContent.task?.id, life.id)
            XCTAssertEqual(view.filter, [name])
            XCTAssertEqual(view.bubbleContent.group, BubbleContent.clean(name))
            state.groupID = "work"
            XCTAssertEqual(view.bubbleContent.task?.id, work.id)
        }
    }

    func testIndependentPanelOwnStateControlsContentAndHoverWithoutMainState() throws {
        let (model, work, life) = try fixture()
        let mainState = state("work")
        let controller = GroupPanelController(model: model, groupID: "life", near: .zero,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, didClose: { _ in })
        defer { controller.close() }
        controller.motion.environment = PanelMotionTestEnvironment(area: area).environment
        let view = view(model, controller.state, groupName: controller.groupName)
        XCTAssertEqual(view.bubbleContent.task?.id, life.id)
        XCTAssertEqual(controller.bubbleContent.task?.id, life.id)
        XCTAssertEqual(controller.remaining, 2)
        mainState.groupID = nil
        XCTAssertEqual(controller.bubbleContent.task?.id, life.id)
        controller.state.groupID = "work"
        XCTAssertEqual(controller.bubbleContent.task?.id, work.id)
        controller.state.groupID = "life"
        controller.motion.toggleBubble(in: area, animated: false)
        controller.motion.setHover(true, in: area)
        let expected = min(ceil(86 + view.bubbleContent.textWidth(language: model.language)) + controller.motion.filterExtra, 440)
        XCTAssertEqual(controller.motion.panel.frame.width, expected, accuracy: 0.01)
        controller.state.groupID = "study"
        XCTAssertNil(controller.bubbleContent.task)
        XCTAssertEqual(controller.remaining, 0)
    }

    private final class MemoryDefaults: UserDefaults {
        override func stringArray(forKey defaultName: String) -> [String]? { [] }
        override func set(_ value: Any?, forKey defaultName: String) {}
    }
}
