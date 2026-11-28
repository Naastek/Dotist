import AppKit
import DotistCore
import GRDB
import XCTest
@testable import DotistApp

@MainActor
final class BubbleContentTests: XCTestCase {
    private func store() throws -> TaskStore {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-bubble-wJ3-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
    }

    func testOneOverdueTaskCountsAsOneOnPanelMenuBarAndHoverStrip() throws {
        let store = try store()
        let task = try store.addTask(title: "Overdue task", dueDate: "2026-11-19")
        let model = try AppModel(store: store)
        let state = TaskPanelState(scope: "today")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12))!
        let panel = try XCTUnwrap(state.todayAgenda(in: model, now: now, calendar: calendar))
        let menu = MenuBarImage.todayCount(tasks: model.tasks, groupID: nil, now: now, calendar: calendar)
        let strip = BubbleContent(model: model, state: state, now: now, calendar: calendar)

        XCTAssertEqual(panel.overdue.matches.map(\.id), [task.id])
        XCTAssertTrue(panel.today.matches.isEmpty)
        XCTAssertEqual(panel.openCount, 1)
        XCTAssertEqual(MenuBarImage.countLabel(menu), "1")
        XCTAssertEqual(strip.remaining, 1)
        XCTAssertEqual(strip.title, task.title)

        state.customStart = "2026-11-20"
        XCTAssertNil(state.todayAgenda(in: model, now: now, calendar: calendar))
        XCTAssertEqual(BubbleContent(model: model, state: state, now: now, calendar: calendar).remaining, 0)
    }

    func testMainBubbleSelectsAndCountsOnlyOpenRoots() throws {
        let store = try store()
        let parent = try store.addTask(title: "Parent", category: DotistGroup.inboxID)
        _ = try store.addTask(title: "Child", category: DotistGroup.inboxID, parentId: parent.id, dueDate: "2026-11-01")
        let other = try store.addTask(title: "Completed parent", category: "work")
        let child = try store.addTask(title: "Open child of completed parent", category: "work", parentId: other.id)
        _ = try store.patchTask(id: other.id, completed: true)
        _ = try store.patchTask(id: child.id, completed: false)
        let model = try AppModel(store: store)
        XCTAssertEqual(model.nextTask?.id, parent.id)
        XCTAssertEqual(model.bubbleTitle, parent.title)
        XCTAssertEqual(model.remainingCount, 1)
        let strip = BubbleContent(model: model)
        XCTAssertEqual(strip.task?.id, parent.id)
        XCTAssertEqual(strip.title, parent.title)
        XCTAssertEqual(strip.remaining, 1)
        XCTAssertNil(strip.due, "A child's due date must never leak into the parent's strip")
    }

    func testGroupBubbleTitleIsTheParentTitleAndCountExcludesChildren() throws {
        let store = try store()
        let parent = try store.addTask(title: "Group parent", category: "work")
        _ = try store.addTask(title: "Child", category: "work", parentId: parent.id)
        _ = try store.addTask(title: "Other group", category: "life")
        let model = try AppModel(store: store)
        let panel = GroupPanelController(model: model, groupID: "work", near: .zero,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, didClose: { _ in })
        defer { panel.close() }
        XCTAssertEqual(panel.bubbleTitle, parent.title)
        XCTAssertEqual(panel.remaining, 1)
    }

    func testMainStripUsesTheSameInboxPriorityAsItsMeasuredTitle() throws {
        let store = try store()
        let finished = try store.addTask(title: "Completed", category: DotistGroup.inboxID)
        _ = try store.patchTask(id: finished.id, completed: true)
        _ = try store.addTask(title: "Work position zero", category: "work")
        let inbox = try store.addTask(title: "Inbox position one", category: DotistGroup.inboxID)
        let model = try AppModel(store: store)
        let strip = BubbleContent(model: model)
        XCTAssertEqual(strip.task?.id, inbox.id)
        XCTAssertEqual(strip.title, model.bubbleTitle)
        XCTAssertEqual(strip.remaining, 2)
    }

    func testSelectedPreviewPersistsAndRespectsGroupTagAndDateFilters() async throws {
        let store = try store()
        let first = try store.addTask(title: "First #other", dueDate: "2027-02-13")
        let selected = try store.addTask(title: "Selected #focus", category: "work", dueDate: "2027-02-12")
        let settingsFile = URL(fileURLWithPath: try store.databasePath()).deletingLastPathComponent()
            .appendingPathComponent("settings.json")
        try Data(#"{"hover_expand":true,"opacity":60}"#.utf8).write(to: settingsFile)
        let legacyStore = try TaskStore(databasePath: store.databasePath())
        let model = try AppModel(store: legacyStore)
        XCTAssertNil(model.settings.hoverPreviewTaskId)
        XCTAssertEqual(BubbleContent(model: model).task?.id, first.id)

        var patch = DotistSettingsPatch()
        patch.hoverPreviewTaskId = selected.id
        let saved = await withCheckedContinuation { continuation in
            model.updateSettings(patch) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(saved)
        let strip = BubbleContent(model: model)
        XCTAssertEqual(strip.task?.id, selected.id)
        XCTAssertEqual(strip.remaining, 2)
        XCTAssertEqual(model.nextTask?.id, first.id)
        XCTAssertEqual(try store.snapshot().tasks.first(where: { $0.id == selected.id }), selected)

        let reopened = try TaskStore(databasePath: store.databasePath())
        let reopenedModel = try AppModel(store: reopened)
        XCTAssertEqual(reopenedModel.settings.resolvedPanelMaterial, .regular)
        XCTAssertEqual(BubbleContent(model: reopenedModel).task?.id, selected.id)
        XCTAssertEqual(BubbleContent(model: reopenedModel, groupID: "work").task?.id, selected.id)
        XCTAssertEqual(BubbleContent(model: reopenedModel, groupID: DotistGroup.inboxID).task?.id, first.id)
        let state = TaskPanelState()
        state.activeTag = "other"
        XCTAssertEqual(BubbleContent(model: reopenedModel, state: state).task?.id, first.id)
        state.activeTag = nil
        state.customStart = "2027-02-13"
        XCTAssertEqual(BubbleContent(model: reopenedModel, state: state).task?.id, first.id)
        state.customStart = "2027-02-12"
        XCTAssertEqual(BubbleContent(model: reopenedModel, state: state).task?.id, selected.id)

        patch.hoverPreviewTaskId = first.id
        XCTAssertEqual(try reopened.updateSettings(patch).hoverPreviewTaskId, first.id)
        patch.hoverPreviewTaskId = ""
        XCTAssertNil(try reopened.updateSettings(patch).hoverPreviewTaskId)
        XCTAssertNil(try TaskStore(databasePath: reopened.databasePath()).settings().hoverPreviewTaskId)
    }

    func testPreviewUsesCurrentTitleAndFallsBackWhenTaskBecomesIneligible() throws {
        let store = try store()
        let first = try store.addTask(title: "First", dueDate: "2027-02-12")
        let selected = try store.addTask(title: "Selected", dueDate: "2027-02-12")
        var patch = DotistSettingsPatch()
        patch.hoverPreviewTaskId = selected.id
        _ = try store.updateSettings(patch)

        _ = try store.patchTask(id: selected.id, title: "Updated title")
        XCTAssertEqual(BubbleContent(model: try AppModel(store: store)).title, "Updated title")
        _ = try store.patchTask(id: selected.id, completed: true)
        XCTAssertEqual(BubbleContent(model: try AppModel(store: store)).task?.id, first.id)
        _ = try store.patchTask(id: selected.id, completed: false)
        _ = try store.indent(ids: [selected.id])
        let state = TaskPanelState()
        state.customStart = "2027-02-12"
        let filtered = BubbleContent(model: try AppModel(store: store), state: state)
        XCTAssertEqual(filtered.task?.id, first.id)
        XCTAssertEqual(filtered.remaining, 2, "Filtering still counts matching subtasks")
        try store.deleteTask(selected.id)
        XCTAssertEqual(BubbleContent(model: try AppModel(store: store)).task?.id, first.id)
    }

    func testGroupIdentityDoesNotDependOnDuplicateDisplayNames() throws {
        let store = try store()
        let work = try store.addTask(title: "Work parent", category: "work")
        let life = try store.addTask(title: "Life parent", category: "life")
        let db = try DatabaseQueue(path: store.databasePath())
        try db.write { db in try db.execute(sql: "UPDATE task_groups SET name='Same name' WHERE id IN ('work','life')") }
        let model = try AppModel(store: store)
        XCTAssertEqual(BubbleContent(model: model, groupID: "work").task?.id, work.id)
        XCTAssertEqual(BubbleContent(model: model, groupID: "life").task?.id, life.id)
        XCTAssertEqual(BubbleContent(model: model, groupID: "life").remaining, 1)
    }

    func testMetadataOmitsSeparatorsForMissingAndBlankFields() throws {
        let store = try store()
        _ = try store.addTask(title: "No metadata", category: DotistGroup.inboxID)
        _ = try store.addTask(title: "Group only", category: "work")
        let due = "2026-11-12"
        _ = try store.addTask(title: "Due only", category: "life", dueDate: due)
        _ = try store.addTask(title: "Both fields", category: "study", dueDate: due)
        let db = try DatabaseQueue(path: store.databasePath())
        try db.write { db in try db.execute(sql: "UPDATE task_groups SET name='  ' WHERE id='life'") }
        let model = try AppModel(store: store)
        XCTAssertEqual(BubbleContent(model: model).subtitle, "")
        XCTAssertEqual(BubbleContent(model: model, groupID: "work").subtitle, model.groupDisplayName("work"))
        XCTAssertEqual(BubbleContent(model: model, groupID: "life").subtitle, model.dueLabel(due))
        XCTAssertEqual(BubbleContent(model: model, groupID: "study").subtitle, model.groupDisplayName("study") + " · " + model.dueLabel(due))
        for blank in ["", "  ", "\n\t"] { XCTAssertNil(BubbleContent.clean(blank)) }
    }

    func testLegacyBlankTitleHasALocalizedFallbackWithoutEllipses() throws {
        let store = try store()
        let task = try store.addTask(title: "Legacy title", category: DotistGroup.inboxID)
        let db = try DatabaseQueue(path: store.databasePath())
        try db.write { db in try db.execute(sql: "UPDATE tasks SET title='  ' WHERE id=?", arguments: [task.id]) }
        let model = try AppModel(store: store)
        XCTAssertEqual(model.bubbleTitle, model.text("未命名任务"))
        XCTAssertEqual(BubbleContent(model: model).title, model.bubbleTitle)
        XCTAssertEqual(BubbleContent(model: model).subtitle, "")
    }
}
