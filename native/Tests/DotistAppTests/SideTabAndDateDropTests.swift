import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class SideTabAndDateDropTests: XCTestCase {
    private func makeStore() throws -> (URL, TaskStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-sidetab-date-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try TaskStore(databasePath: dir.appendingPathComponent("tasks.sqlite").path)
        return (dir, store)
    }

    private func waitUntil(_ timeout: TimeInterval = 2.0, _ predicate: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func testKeepExpandedNamingLocalizationAndSettingsSearch() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let keys = ["保持展开", "取消保持展开", "展开与收起", "开启「保持展开」时不会自动收起，也不会失焦淡出。"]
        for language in ["en", "zh-TW", "fr", "de"] {
            var patch = DotistSettingsPatch()
            patch.language = language
            _ = try store.updateSettings(patch)
            let model = try AppModel(store: store)
            for key in keys {
                let translated = model.text(key)
                XCTAssertFalse(translated.isEmpty, "\(language) missing \(key)")
                if language != "zh-TW" {
                    XCTAssertNotEqual(translated, key, "\(language) untranslated \(key)")
                }
            }
        }

        for query in ["保持展开", "Keep expanded", "Garder déployé", "Ausgeklappt lassen", "固定窗口"] {
            let targets = Set(SettingsSearchIndex.matches(query).map(\.target))
            XCTAssertTrue(targets.contains("general.保持展开"), "query '\(query)' should match general.保持展开")
            XCTAssertTrue(targets.contains("toolbar.保持展开"), "query '\(query)' should match toolbar.保持展开")
        }
        XCTAssertFalse(SettingsSearchIndex.entries.contains { $0.title == "固定窗口" })
    }

    func testSideTabTaskDropOutwardInwardAndRestingNarrowEdge() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = try store.listGroups().filter { $0.id != DotistGroup.inboxID }
        let work = try XCTUnwrap(groups.first)
        let life = try XCTUnwrap(groups.dropFirst().first)
        let model = try AppModel(store: store)
        let suiteName = "dotist-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = TaskPanelState(groupID: work.id, collapseStore: TaskGroupCollapseStore(defaults: defaults))

        // 1. Outward mode (ample left space: panel at x = 400, visibleMinX = 0)
        var now: TimeInterval = 10
        let outwardPanel = DotistPanel(contentRect: CGRect(x: 400, y: 100, width: 364, height: 620),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        outwardPanel.isReleasedWhenClosed = false
        let outwardMotion = PanelMotion(model: model, panel: outwardPanel, size: outwardPanel.frame.size, title: { "" })
        let outwardEnv = SideTabsController.Environment(
            time: { now },
            mouse: { CGPoint(x: 500, y: 300) },
            mouseButtons: { 1 }, // Simulates left mouse button held during task drag
            visible: { _ in true },
            visibleMinX: { _ in 0 },
            reduceMotion: { false },
            desktopEvents: false,
            inputMonitors: false
        )
        let outwardTabs = SideTabsController(parent: outwardPanel, model: model, state: state, motion: outwardMotion, environment: outwardEnv)
        defer { outwardTabs.stop(); outwardMotion.stop(); outwardPanel.close() }

        // Advance past entrance animation so all tabs are interactive in 10pt resting narrow-edge state.
        now += 1.0
        outwardTabs.synchronize()
        XCTAssertFalse(outwardTabs.expanded)
        XCTAssertEqual(outwardTabs.renderedRows.count, groups.count + 1)

        // Resting 10pt narrow edge hit on "life" (index 2):
        let lifeY = outwardPanel.frame.maxY - SideTabGeometry.topInset - 2 * SideTabGeometry.stride - SideTabGeometry.height / 2
        let restingLifePoint = CGPoint(x: outwardPanel.frame.minX - 5, y: lifeY)
        let restingHit = outwardTabs.updateTaskDrop(at: restingLifePoint)
        XCTAssertEqual(restingHit, life.id, "Dragging onto 10pt resting narrow edge must hit life tab immediately")
        XCTAssertTrue(outwardTabs.expanded, "Task drag over side tab must expand even with mouse button held")
        XCTAssertEqual(outwardTabs.dropTargetID, life.id)

        // Advance 160ms on the same animation clock to reach full outward expansion.
        now += SideTabGeometry.expansionDuration
        let expandedLifePoint = CGPoint(x: outwardPanel.frame.minX - 30, y: lifeY)
        XCTAssertEqual(outwardTabs.updateTaskDrop(at: expandedLifePoint), life.id)

        // Dragging onto "全部" (index 0) maps to implicit ungrouped inbox.
        let allY = outwardPanel.frame.maxY - SideTabGeometry.topInset - SideTabGeometry.height / 2
        let allPoint = CGPoint(x: outwardPanel.frame.minX - 24, y: allY)
        XCTAssertEqual(outwardTabs.updateTaskDrop(at: allPoint), DotistGroup.inboxID)
        XCTAssertEqual(outwardTabs.dropTargetID, "all")

        outwardTabs.endTaskDrop()
        XCTAssertNil(outwardTabs.dropTargetID)

        // 2. Inward mode (panel flush with screen left edge: x = 0, visibleMinX = 0)
        var inwardNow: TimeInterval = 20
        let inwardPanel = DotistPanel(contentRect: CGRect(x: 0, y: 100, width: 364, height: 620),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        inwardPanel.isReleasedWhenClosed = false
        let inwardMotion = PanelMotion(model: model, panel: inwardPanel, size: inwardPanel.frame.size, title: { "" })
        let inwardEnv = SideTabsController.Environment(
            time: { inwardNow },
            mouse: { CGPoint(x: 200, y: 300) },
            mouseButtons: { 1 },
            visible: { _ in true },
            visibleMinX: { _ in 0 },
            reduceMotion: { false },
            desktopEvents: false,
            inputMonitors: false
        )
        let inwardTabs = SideTabsController(parent: inwardPanel, model: model, state: state, motion: inwardMotion, environment: inwardEnv)
        defer { inwardTabs.stop(); inwardMotion.stop(); inwardPanel.close() }

        inwardNow += 1.0
        inwardTabs.synchronize()
        XCTAssertFalse(inwardTabs.expanded)

        // Hit resting narrow edge inside left border (x = 4) at "life" row:
        let inwardRestingPoint = CGPoint(x: 4, y: lifeY)
        XCTAssertEqual(inwardTabs.updateTaskDrop(at: inwardRestingPoint), life.id)
        XCTAssertTrue(inwardTabs.expanded)

        // Advance 160ms to full inward expansion and hit inside expanded width (x = 32):
        inwardNow += SideTabGeometry.expansionDuration
        XCTAssertEqual(inwardTabs.updateTaskDrop(at: CGPoint(x: 32, y: allY)), DotistGroup.inboxID)
        inwardTabs.endTaskDrop()
        XCTAssertNil(inwardTabs.dropTargetID)
    }

    func testMainWindowDragTaskAndSubtreeOntoSideTabAndUndoRedo() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = try store.listGroups().filter { $0.id != DotistGroup.inboxID }
        let work = try XCTUnwrap(groups.first)
        let life = try XCTUnwrap(groups.dropFirst().first)
        let parent = try store.addTask(title: "父任务", category: work.id)
        let child = try store.addTask(title: "子任务", category: work.id, parentId: parent.id)
        let model = try AppModel(store: store)
        let suiteName = "dotist-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = TaskPanelState(groupID: work.id, scope: "all", collapseStore: TaskGroupCollapseStore(defaults: defaults))

        let panelRect = CGRect(x: 400, y: 100, width: 364, height: 620)
        let panel = DotistPanel(contentRect: panelRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let motion = PanelMotion(model: model, panel: panel, size: panelRect.size, title: { "" })
        var now: TimeInterval = 50
        let sideTabs = SideTabsController(
            parent: panel, model: model, state: state, motion: motion,
            environment: .init(
                time: { now },
                mouse: { CGPoint(x: 500, y: 300) },
                mouseButtons: { 1 },
                visible: { _ in true },
                visibleMinX: { _ in 0 },
                reduceMotion: { true },
                desktopEvents: false,
                inputMonitors: false
            )
        )
        now += 1.0
        sideTabs.synchronize()

        var capturedRuntime: TaskReorderRuntime?
        let main = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            sideTabDropTarget: { sideTabs.updateTaskDrop(at: $0) },
            endSideTabDrop: { sideTabs.endTaskDrop() }
        )
        let host = DotistHostingView(rootView: main.frame(width: panelRect.width, height: panelRect.height))
        host.frame = CGRect(origin: .zero, size: panelRect.size)
        panel.contentView = host
        defer { sideTabs.stop(); motion.stop(); panel.close() }

        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()

        // Locate TaskReorderRuntime through TaskReorderScrollBridge.ScrollProbe.
        func findRuntime(in view: NSView) -> TaskReorderRuntime? {
            if let probe = view as? TaskReorderScrollBridge.ScrollProbe { return probe.runtime }
            for sub in view.subviews {
                if let found = findRuntime(in: sub) { return found }
            }
            return nil
        }
        capturedRuntime = findRuntime(in: host)
        let runtime = try XCTUnwrap(capturedRuntime)

        // Start drag on parent task and move leftward onto "life" side tab (index 2).
        let startListPoint = CGPoint(x: 100, y: 90)
        runtime.send(.begin(parent.id, startListPoint))
        let lifeListY = SideTabGeometry.topInset + 2 * SideTabGeometry.stride + SideTabGeometry.height / 2
        let lifeListPoint = CGPoint(x: -5, y: lifeListY)
        runtime.send(.move(parent.id, lifeListPoint))
        XCTAssertEqual(sideTabs.dropTargetID, life.id)
        XCTAssertEqual(runtime.drag?.target?.groupID, life.id)

        runtime.send(.end(parent.id, lifeListPoint))
        await waitUntil {
            model.tasks.first(where: { $0.id == parent.id })?.category == life.id
                && model.tasks.first(where: { $0.id == child.id })?.category == life.id
        }
        XCTAssertEqual(model.tasks.first(where: { $0.id == parent.id })?.category, life.id)
        XCTAssertEqual(model.tasks.first(where: { $0.id == child.id })?.category, life.id)
        XCTAssertNil(sideTabs.dropTargetID)

        // Undo restores both parent and subtask to "work" in one step.
        model.undoLast()
        await waitUntil {
            model.tasks.first(where: { $0.id == parent.id })?.category == work.id
                && model.tasks.first(where: { $0.id == child.id })?.category == work.id
        }
        XCTAssertEqual(model.tasks.first(where: { $0.id == parent.id })?.category, work.id)
        XCTAssertEqual(model.tasks.first(where: { $0.id == child.id })?.category, work.id)

        // Redo moves both back to "life".
        model.redoLast()
        await waitUntil {
            model.tasks.first(where: { $0.id == parent.id })?.category == life.id
        }
        XCTAssertEqual(model.tasks.first(where: { $0.id == parent.id })?.category, life.id)
        XCTAssertEqual(model.tasks.first(where: { $0.id == child.id })?.category, life.id)

        // Switch panel to "life" and drag parent onto "全部" tab -> moves to implicit inbox.
        state.groupID = life.id
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(220))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        let lifeFrames = runtime.pickupFrames([
            TaskListRowFrame(task: parent, frame: CGRect(x: 16, y: 80, width: 332, height: 32), sub: false, allTasks: false, hideDue: false, region: life.id, date: nil, depth: 0)
        ])
        let lifeParentFrame = try XCTUnwrap(lifeFrames.first?.frame, "parent row must be mounted in life group")
        runtime.send(.begin(parent.id, CGPoint(x: lifeParentFrame.midX, y: lifeParentFrame.midY)))
        XCTAssertNotNil(runtime.drag, "drag must start for parent in life group")
        let allListY = SideTabGeometry.topInset + SideTabGeometry.height / 2
        let allListPoint = CGPoint(x: -5, y: allListY)
        runtime.send(.move(parent.id, allListPoint))
        XCTAssertEqual(sideTabs.dropTargetID, "all")
        XCTAssertEqual(runtime.drag?.target?.groupID, DotistGroup.inboxID)
        runtime.send(.end(parent.id, allListPoint))
        await waitUntil {
            model.tasks.first(where: { $0.id == parent.id })?.category == DotistGroup.inboxID
        }
        XCTAssertEqual(model.tasks.first(where: { $0.id == parent.id })?.category, DotistGroup.inboxID)
        XCTAssertEqual(model.tasks.first(where: { $0.id == child.id })?.category, DotistGroup.inboxID)
    }

    func testTaskDropSectionBoundaryRules() {
        // Non-sectioned "all" view: always allowed, never mutates dueDate.
        let allMove = TaskDropSection.resolve(sourceRegion: "work", destinationRegion: "life", destinationDate: nil)
        XCTAssertTrue(allMove.allowed)
        XCTAssertNil(allMove.dueDate)

        // Overdue -> Today (concrete date): allowed, writes today.
        let overdueToToday = TaskDropSection.resolve(sourceRegion: "overdue:work", destinationRegion: "today:work", destinationDate: "2026-11-24")
        XCTAssertTrue(overdueToToday.allowed)
        XCTAssertEqual(overdueToToday.dueDate, "2026-11-24")

        // Upcoming -> Today: allowed, writes today.
        let upcomingToToday = TaskDropSection.resolve(sourceRegion: "upcoming:work", destinationRegion: "today:life", destinationDate: "2026-11-24")
        XCTAssertTrue(upcomingToToday.allowed)
        XCTAssertEqual(upcomingToToday.dueDate, "2026-11-24")

        // Today -> Overdue (no single date): rejected.
        XCTAssertFalse(TaskDropSection.resolve(sourceRegion: "today:work", destinationRegion: "overdue:work", destinationDate: nil).allowed)
        // Today -> Upcoming (multi-day bucket): rejected.
        XCTAssertFalse(TaskDropSection.resolve(sourceRegion: "today:work", destinationRegion: "upcoming:work", destinationDate: nil).allowed)
        // Open <-> Completed boundary: rejected both ways.
        XCTAssertFalse(TaskDropSection.resolve(sourceRegion: "today:work", destinationRegion: "completed:work", destinationDate: nil).allowed)
        XCTAssertFalse(TaskDropSection.resolve(sourceRegion: "completed:work", destinationRegion: "today:work", destinationDate: "2026-11-24").allowed)

        // Next 7 days: cross-day allowed, same-day keeps nil dueDate (no redundant date write).
        let crossDay = TaskDropSection.resolve(sourceRegion: "2026-11-24:work", destinationRegion: "2026-11-26:life", destinationDate: "2026-11-26")
        XCTAssertTrue(crossDay.allowed)
        XCTAssertEqual(crossDay.dueDate, "2026-11-26")

        let sameDay = TaskDropSection.resolve(sourceRegion: "2026-11-24:work", destinationRegion: "2026-11-24:life", destinationDate: "2026-11-24")
        XCTAssertTrue(sameDay.allowed)
        XCTAssertNil(sameDay.dueDate)

        // Multi-selection spanning dates: even when the topmost row is already in the destination day,
        // the batch resolves to the destination date so every selected root updates consistently.
        let spanningBatch = TaskDropSection.resolve(
            sourceRegions: ["2026-11-24:work", "2026-11-25:work"],
            destinationRegion: "2026-11-24:work",
            destinationDate: "2026-11-24"
        )
        XCTAssertTrue(spanningBatch.allowed)
        XCTAssertEqual(spanningBatch.dueDate, "2026-11-24")

        // Mixed completed + open selection is rejected when targeting an open date section.
        let mixedCompletedBatch = TaskDropSection.resolve(
            sourceRegions: ["today:work", "completed:work"],
            destinationRegion: "today:work",
            destinationDate: "2026-11-24"
        )
        XCTAssertFalse(mixedCompletedBatch.allowed)
    }

    func testCrossDateSectionDragInTodayAndNext7ViewsWithUndoRedoAndStartDateClamp() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = try XCTUnwrap(store.listGroups().first { $0.id != DotistGroup.inboxID })
        let today = Date().dotistDay
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!.dotistDay
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!.dotistDay
        let dayAfter = Calendar.current.date(byAdding: .day, value: 2, to: Date())!.dotistDay

        let overdueTask = try store.addTask(title: "逾期任务", category: work.id, dueDate: yesterday)
        let todayTask = try store.addTask(title: "今日任务", category: work.id, dueDate: today)
        let rangedTask = try store.addTask(title: "跨天任务", category: work.id, dueDate: dayAfter)
        _ = try store.setDateRange(rangedTask.id, start: tomorrow, due: dayAfter)

        let model = try AppModel(store: store)
        let suiteName = "dotist-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = TaskPanelState(groupID: nil, scope: "today", collapseStore: TaskGroupCollapseStore(defaults: defaults))

        let panelRect = CGRect(x: 400, y: 100, width: 364, height: 620)
        let panel = DotistPanel(contentRect: panelRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let main = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}
        )
        let host = DotistHostingView(rootView: main.frame(width: panelRect.width, height: panelRect.height))
        host.frame = CGRect(origin: .zero, size: panelRect.size)
        panel.contentView = host
        defer { panel.close() }

        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(140))
        host.layoutSubtreeIfNeeded()

        func findRuntime(in view: NSView) -> TaskReorderRuntime? {
            if let probe = view as? TaskReorderScrollBridge.ScrollProbe { return probe.runtime }
            for sub in view.subviews {
                if let found = findRuntime(in: sub) { return found }
            }
            return nil
        }
        let runtime = try XCTUnwrap(findRuntime(in: host))

        // Capture live pickup frames for overdueTask and todayTask in "today" view.
        let frames = runtime.pickupFrames([
            TaskListRowFrame(task: overdueTask, frame: CGRect(x: 16, y: 100, width: 332, height: 32), sub: false, allTasks: true, hideDue: false, region: "overdue:\(work.id)", date: nil, depth: 0),
            TaskListRowFrame(task: todayTask, frame: CGRect(x: 16, y: 200, width: 332, height: 32), sub: false, allTasks: true, hideDue: true, region: "today:\(work.id)", date: today, depth: 0)
        ])
        let overdueFrame = try XCTUnwrap(frames.first { $0.task.id == overdueTask.id }?.frame)
        let todayFrame = try XCTUnwrap(frames.first { $0.task.id == todayTask.id }?.frame)

        // 1. Drag overdue task onto today section -> reschedules to today!
        let dragStart = CGPoint(x: overdueFrame.midX, y: overdueFrame.midY)
        let dropInToday = CGPoint(x: todayFrame.midX, y: todayFrame.maxY - 2)
        runtime.send(.begin(overdueTask.id, dragStart))
        runtime.send(.move(overdueTask.id, dropInToday))
        XCTAssertEqual(runtime.drag?.destination?.date, today)
        runtime.send(.end(overdueTask.id, dropInToday))
        await waitUntil { model.tasks.first(where: { $0.id == overdueTask.id })?.dueDate == today }
        XCTAssertEqual(model.tasks.first(where: { $0.id == overdueTask.id })?.dueDate, today)

        // Undo restores original overdue dueDate.
        model.undoLast()
        await waitUntil { model.tasks.first(where: { $0.id == overdueTask.id })?.dueDate == yesterday }
        XCTAssertEqual(model.tasks.first(where: { $0.id == overdueTask.id })?.dueDate, yesterday)

        // Redo reapplies today.
        model.redoLast()
        await waitUntil { model.tasks.first(where: { $0.id == overdueTask.id })?.dueDate == today }
        XCTAssertEqual(model.tasks.first(where: { $0.id == overdueTask.id })?.dueDate, today)

        // 2. Switch to "next7" view and drag rangedTask (start=tomorrow, due=dayAfter) onto today section:
        // dueDate becomes today AND startDate clamps to today atomically, with single-step undo!
        state.scope = "next7"
        try await Task.sleep(for: .milliseconds(160))
        host.layoutSubtreeIfNeeded()

        let next7Frames = runtime.pickupFrames([
            TaskListRowFrame(task: todayTask, frame: CGRect(x: 16, y: 100, width: 332, height: 32), sub: false, allTasks: true, hideDue: true, region: "\(today):\(work.id)", date: today, depth: 0),
            TaskListRowFrame(task: rangedTask, frame: CGRect(x: 16, y: 200, width: 332, height: 32), sub: false, allTasks: true, hideDue: true, region: "\(dayAfter):\(work.id)", date: dayAfter, depth: 0)
        ])
        let next7TodayFrame = try XCTUnwrap(next7Frames.first { $0.task.id == todayTask.id }?.frame)
        let next7RangedFrame = try XCTUnwrap(next7Frames.first { $0.task.id == rangedTask.id }?.frame)

        runtime.send(.begin(rangedTask.id, CGPoint(x: next7RangedFrame.midX, y: next7RangedFrame.midY)))
        let dropOnTodayInNext7 = CGPoint(x: next7TodayFrame.midX, y: next7TodayFrame.midY)
        runtime.send(.move(rangedTask.id, dropOnTodayInNext7))
        XCTAssertEqual(runtime.drag?.destination?.date, today)
        runtime.send(.end(rangedTask.id, dropOnTodayInNext7))

        await waitUntil {
            let t = model.tasks.first(where: { $0.id == rangedTask.id })
            return t?.dueDate == today && t?.startDate == today
        }
        let updatedRanged = try XCTUnwrap(model.tasks.first(where: { $0.id == rangedTask.id }))
        XCTAssertEqual(updatedRanged.dueDate, today)
        XCTAssertEqual(updatedRanged.startDate, today)

        // Undo restores BOTH original startDate and dueDate in one step.
        model.undoLast()
        await waitUntil {
            let t = model.tasks.first(where: { $0.id == rangedTask.id })
            return t?.dueDate == dayAfter && t?.startDate == tomorrow
        }
        let restoredRanged = try XCTUnwrap(model.tasks.first(where: { $0.id == rangedTask.id }))
        XCTAssertEqual(restoredRanged.dueDate, dayAfter)
        XCTAssertEqual(restoredRanged.startDate, tomorrow)
    }

    func testReleasingOverRejectedSectionAfterPassingThroughTodayDoesNotCommitOrRecordUndo() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = try XCTUnwrap(store.listGroups().first { $0.id != DotistGroup.inboxID })
        let today = Date().dotistDay
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!.dotistDay
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!.dotistDay

        let overdueTask = try store.addTask(title: "逾期任务", category: work.id, dueDate: yesterday)
        let todayTask = try store.addTask(title: "今日任务", category: work.id, dueDate: today)
        let upcomingTask = try store.addTask(title: "未来任务", category: work.id, dueDate: tomorrow)

        let model = try AppModel(store: store)
        let suiteName = "dotist-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = TaskPanelState(groupID: nil, scope: "today", collapseStore: TaskGroupCollapseStore(defaults: defaults))
        let runtime = TaskReorderRuntime()

        let panelRect = CGRect(x: 400, y: 100, width: 364, height: 620)
        let panel = DotistPanel(contentRect: panelRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let main = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            initialUpcomingOpen: true, reorderRuntime: runtime
        )
        let host = DotistHostingView(rootView: main.frame(width: panelRect.width, height: panelRect.height))
        host.frame = CGRect(origin: .zero, size: panelRect.size)
        panel.contentView = host
        defer { panel.close() }

        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(160))
        host.layoutSubtreeIfNeeded()

        let frames = runtime.pickupFrames([
            TaskListRowFrame(task: overdueTask, frame: CGRect(x: 16, y: 100, width: 332, height: 32), sub: false, allTasks: true, hideDue: false, region: "overdue:\(work.id)", date: nil, depth: 0),
            TaskListRowFrame(task: todayTask, frame: CGRect(x: 16, y: 200, width: 332, height: 32), sub: false, allTasks: true, hideDue: true, region: "today:\(work.id)", date: today, depth: 0),
            TaskListRowFrame(task: upcomingTask, frame: CGRect(x: 16, y: 300, width: 332, height: 32), sub: false, allTasks: true, hideDue: false, region: "upcoming:\(work.id)", date: nil, depth: 0)
        ])
        let overdueFrame = try XCTUnwrap(frames.first { $0.task.id == overdueTask.id }?.frame)
        let todayFrame = try XCTUnwrap(frames.first { $0.task.id == todayTask.id }?.frame)
        let upcomingFrame = try XCTUnwrap(frames.first { $0.task.id == upcomingTask.id }?.frame)

        // Drag overdue task through Today (valid), then into Upcoming (rejected), then release.
        runtime.send(.begin(overdueTask.id, CGPoint(x: overdueFrame.midX, y: overdueFrame.midY)))
        runtime.send(.move(overdueTask.id, CGPoint(x: todayFrame.midX, y: todayFrame.maxY - 2)))
        XCTAssertEqual(runtime.drag?.destination?.date, today)

        let dropInUpcoming = CGPoint(x: upcomingFrame.midX, y: upcomingFrame.maxY - 2)
        runtime.send(.move(overdueTask.id, dropInUpcoming))
        XCTAssertNil(runtime.drag?.destination, "Entering rejected Upcoming section must clear pending Today destination")

        runtime.send(.end(overdueTask.id, dropInUpcoming))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(model.tasks.first(where: { $0.id == overdueTask.id })?.dueDate, yesterday)
        XCTAssertFalse(model.canUndoAction, "Cancelled release over rejected section must not record undo history")
    }

    func testMultiSelectionSpanningDatesReschedulesAllRootsAndUndoesInOneStep() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = try XCTUnwrap(store.listGroups().first { $0.id != DotistGroup.inboxID })
        let day1 = Date().dotistDay
        let day2 = Calendar.current.date(byAdding: .day, value: 1, to: Date())!.dotistDay

        let tue1 = try store.addTask(title: "周二任务一", category: work.id, dueDate: day1)
        let tue2 = try store.addTask(title: "周二任务二", category: work.id, dueDate: day1)
        let wed1 = try store.addTask(title: "周三任务一", category: work.id, dueDate: day2)

        let model = try AppModel(store: store)
        let suiteName = "dotist-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = TaskPanelState(groupID: nil, scope: "next7", collapseStore: TaskGroupCollapseStore(defaults: defaults))
        let runtime = TaskReorderRuntime()
        let selection = TaskSelectionController()

        let panelRect = CGRect(x: 400, y: 100, width: 364, height: 620)
        let panel = DotistPanel(contentRect: panelRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let main = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            reorderRuntime: runtime, selection: selection
        )
        let host = DotistHostingView(rootView: main.frame(width: panelRect.width, height: panelRect.height))
        host.frame = CGRect(origin: .zero, size: panelRect.size)
        panel.contentView = host
        defer { panel.close() }

        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(160))
        host.layoutSubtreeIfNeeded()

        let frames = runtime.pickupFrames([
            TaskListRowFrame(task: tue1, frame: CGRect(x: 16, y: 100, width: 332, height: 32), sub: false, allTasks: true, hideDue: true, region: "\(day1):\(work.id)", date: day1, depth: 0),
            TaskListRowFrame(task: tue2, frame: CGRect(x: 16, y: 140, width: 332, height: 32), sub: false, allTasks: true, hideDue: true, region: "\(day1):\(work.id)", date: day1, depth: 0),
            TaskListRowFrame(task: wed1, frame: CGRect(x: 16, y: 220, width: 332, height: 32), sub: false, allTasks: true, hideDue: true, region: "\(day2):\(work.id)", date: day2, depth: 0)
        ])
        let tue1Frame = try XCTUnwrap(frames.first { $0.task.id == tue1.id }?.frame)
        let tue2Frame = try XCTUnwrap(frames.first { $0.task.id == tue2.id }?.frame)

        // Select tue1 (day1) + wed1 (day2), then drag onto tue2 (day1).
        selection.update { $0.ids = [tue1.id, wed1.id] }
        runtime.send(.begin(tue1.id, CGPoint(x: tue1Frame.midX, y: tue1Frame.midY)))
        let dropOnTue2 = CGPoint(x: tue2Frame.midX, y: tue2Frame.maxY - 2)
        runtime.send(.move(tue1.id, dropOnTue2))
        XCTAssertEqual(runtime.drag?.destination?.date, day1, "Spanning selection dragged into day1 must resolve dueDate = day1")

        runtime.send(.end(tue1.id, dropOnTue2))
        await waitUntil {
            model.tasks.first(where: { $0.id == tue1.id })?.dueDate == day1
                && model.tasks.first(where: { $0.id == wed1.id })?.dueDate == day1
        }
        XCTAssertEqual(model.tasks.first(where: { $0.id == tue1.id })?.dueDate, day1)
        XCTAssertEqual(model.tasks.first(where: { $0.id == wed1.id })?.dueDate, day1)

        // One undo restores original dates for the entire batch.
        model.undoLast()
        await waitUntil {
            model.tasks.first(where: { $0.id == wed1.id })?.dueDate == day2
        }
        XCTAssertEqual(model.tasks.first(where: { $0.id == tue1.id })?.dueDate, day1)
        XCTAssertEqual(model.tasks.first(where: { $0.id == wed1.id })?.dueDate, day2)
    }

    func testReleasingDirectlyOnEmptyTodayHeadingReschedulesOverdueTask() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = try XCTUnwrap(store.listGroups().first { $0.id != DotistGroup.inboxID })
        let today = Date().dotistDay
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!.dotistDay

        let overdue1 = try store.addTask(title: "逾期一", category: work.id, dueDate: yesterday)
        let overdue2 = try store.addTask(title: "逾期二", category: work.id, dueDate: yesterday)

        let model = try AppModel(store: store)
        let suiteName = "dotist-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = TaskPanelState(groupID: nil, scope: "today", collapseStore: TaskGroupCollapseStore(defaults: defaults))
        let runtime = TaskReorderRuntime()

        let panelRect = CGRect(x: 400, y: 100, width: 364, height: 620)
        let panel = DotistPanel(contentRect: panelRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let main = MainWindow(
            model: model, state: state,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {},
            reorderRuntime: runtime
        )
        let host = DotistHostingView(rootView: main.frame(width: panelRect.width, height: panelRect.height))
        host.frame = CGRect(origin: .zero, size: panelRect.size)
        panel.contentView = host
        defer { panel.close() }

        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(160))
        host.layoutSubtreeIfNeeded()

        let frames = runtime.pickupFrames([
            TaskListRowFrame(task: overdue1, frame: CGRect(x: 16, y: 100, width: 332, height: 32), sub: false, allTasks: true, hideDue: false, region: "overdue:\(work.id)", date: nil, depth: 0)
        ])
        let overdue1Frame = try XCTUnwrap(frames.first?.frame)

        // Start dragging overdue1 so the empty Today drop heading mounts.
        runtime.send(.begin(overdue1.id, CGPoint(x: overdue1Frame.midX, y: overdue1Frame.midY)))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()

        let groupFrames = runtime.pickupGroupFrames([])
        let todayDropHeading = try XCTUnwrap(
            groupFrames.first { $0.region == "today-drop:\(work.id)" },
            "Visible empty Today heading must carry measured today-drop group geometry"
        )
        XCTAssertGreaterThanOrEqual(todayDropHeading.frame.height, 30)

        // Center the dragged row directly on the visible "今天" heading label and release.
        let dropOnHeading = CGPoint(x: todayDropHeading.frame.midX, y: todayDropHeading.frame.midY)
        runtime.send(.move(overdue1.id, dropOnHeading))
        XCTAssertEqual(runtime.drag?.destination?.region, "today-drop:\(work.id)")
        XCTAssertEqual(runtime.drag?.destination?.date, today)

        runtime.send(.end(overdue1.id, dropOnHeading))
        await waitUntil { model.tasks.first(where: { $0.id == overdue1.id })?.dueDate == today }
        XCTAssertEqual(model.tasks.first(where: { $0.id == overdue1.id })?.dueDate, today)
        XCTAssertEqual(model.tasks.first(where: { $0.id == overdue2.id })?.dueDate, yesterday)

        model.undoLast()
        await waitUntil { model.tasks.first(where: { $0.id == overdue1.id })?.dueDate == yesterday }
        XCTAssertEqual(model.tasks.first(where: { $0.id == overdue1.id })?.dueDate, yesterday)
    }
}
