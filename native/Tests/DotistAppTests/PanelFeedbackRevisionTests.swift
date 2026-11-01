import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class PanelFeedbackRevisionTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "dotist-wL1-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    private func store() throws -> TaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wL1-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
    }
    private func settle<V: View>(_ host: NSHostingView<V>) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(220))
        host.layoutSubtreeIfNeeded()
    }

    func testRenderedActionColumnStaysFixedAndMissingActionsShrinkLeft() throws {
        // Pixel bounds exercise the live Layout, including its fourth action
        // subview, rather than merely checking the placement helper.
        for metadataWidth: CGFloat in [0, 18, 24, 63, 88, 104, 132] {
            for count in 1...3 {
                let actionWidth = TaskRowActionMetrics.width(count: count)
                let renderer = ImageRenderer(content: TaskRowLayout(depth: 0) {
                    Color.clear
                    Color.clear.frame(height: 20)
                    Color.green.frame(width: metadataWidth, height: 20)
                    Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1).frame(width: actionWidth, height: 22)
                }.padding(.horizontal, 16).frame(width: 364).background(Color.white))
                renderer.scale = 2
                let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                if metadataWidth == 18 && count == 3 {
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/dotist-wL1-action-layout.png")) }
                var xs: [CGFloat] = []
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        guard let color = rep.colorAt(x: x, y: y) else { continue }
                        if color.redComponent > 0.9 && color.greenComponent < 0.1 { xs.append(CGFloat(x) / 2) }
                    }
                }
                let expectedRight = 348 - (metadataWidth <= 88 ? 88 : metadataWidth + 8)
                XCTAssertEqual(try XCTUnwrap(xs.max()) + 0.5, expectedRight, accuracy: 0.5)
                XCTAssertEqual(try XCTUnwrap(xs.min()), expectedRight - actionWidth, accuracy: 0.5)
                XCTAssertLessThanOrEqual(expectedRight, 348 - metadataWidth)
            }
        }
    }

    func testSelectedFilterFontAndReservedSlotsAreStableInEveryLanguage() async throws {
        _ = NSApplication.shared
        XCTAssertEqual(TaskDateFilterMetrics.size(selected: true), 17)
        XCTAssertEqual(TaskDateFilterMetrics.size(selected: false), 14)
        XCTAssertEqual(TaskDateFilterMetrics.weight(selected: true), .medium)
        XCTAssertEqual(TaskDateFilterMetrics.weight(selected: false), .regular)
        for (language, title) in [("zh-CN", "已逾期"), ("en", "Tomorrow"), ("ja", "すべて"), ("zh-Hant", "今天")] {
            let expected = ceil((title as NSString).size(withAttributes: [.font: DotistDesign.nativeFont(17, weight: .medium, language: language)]).width)
            XCTAssertEqual(TaskDateFilterMetrics.slotWidth(title: title, language: language), expected)
            var widths: [CGFloat] = []
            for selected in [false, true] {
                let host = NSHostingView(rootView: DraggableFilterButton(title: title, selected: selected, language: language, choose: {}))
                widths.append(host.fittingSize.width)
            }
            XCTAssertEqual(widths[0], expected, accuracy: 0.5)
            XCTAssertEqual(widths[1], expected, accuracy: 0.5)
        }
    }

    func testHoverBackgroundPriorityAndDragSuppression() {
        func state(_ hovered: Bool = false, _ selected: Bool = false, _ editing: Bool = false, _ dragging: Bool = false) -> TaskRowBackgroundState {
            .init(hovered: hovered, selected: selected, editing: editing, dragging: dragging)
        }
        XCTAssertEqual(state().opacity, 0)
        XCTAssertEqual(state(true).opacity, 0.10)
        XCTAssertEqual(state(true, true).opacity, 0.16)
        XCTAssertEqual(state(true, true, true).opacity, 0.18)
        XCTAssertEqual(state(true, false, false, true).opacity, 0)
        XCTAssertEqual(state(false, true, false, true).opacity, 0.16)
        XCTAssertEqual(state(false, false, true, true).opacity, 0.18)
        // Leaving a row and ending a drag both return to the current state.
        XCTAssertEqual(TaskRowBackgroundState(hovered: true, selected: true, editing: false, dragging: true, carried: true), .idle)
        XCTAssertEqual(state(), .idle)
        XCTAssertEqual(state(true), .hovered)
    }

    func testCollapsePersistsAndSharesChangesWithoutHidingHeaderlessInbox() {
        let defaults = defaults()
        let collapse = TaskGroupCollapseStore(defaults: defaults)
        let all = TaskPanelState(collapseStore: collapse)
        let panel = TaskPanelState(groupID: "work", scope: "today", collapseStore: collapse)
        all.setGroupCollapsed(true, id: "work")
        all.setGroupCollapsed(true, id: "life")
        XCTAssertEqual(panel.collapsedGroups, ["work", "life"])
        XCTAssertEqual(defaults.stringArray(forKey: "dotist.collapsedGroups"), ["life", "work"])
        XCTAssertEqual(TaskGroupCollapseStore(defaults: defaults).ids, ["work", "life"])
        XCTAssertFalse(panel.showsGroupContents("work"))
        XCTAssertTrue(panel.showsGroupContents("work", hasHeader: false))
        all.setGroupCollapsed(true, id: DotistGroup.inboxID)
        XCTAssertTrue(all.showsGroupContents(DotistGroup.inboxID))
        panel.setGroupCollapsed(false, id: "work")
        XCTAssertEqual(all.collapsedGroups, ["life"])
        XCTAssertEqual(TaskGroupCollapseStore(defaults: defaults).ids, ["life"])
    }

    func testTodayHasNoRepeatedHeadingAndRetainsOtherSections() async throws {
        _ = NSApplication.shared
        let store = try store()
        let today = Date().dotistDay
        let task = try store.addTask(title: "today", category: DotistGroup.inboxID, dueDate: today)
        _ = try store.addTask(title: "late", category: DotistGroup.inboxID, dueDate: "2000-01-01")
        let model = try AppModel(store: store)
        let state = TaskPanelState(scope: "today", collapseStore: TaskGroupCollapseStore(defaults: defaults()))
        var headings: [String] = []
        var rows: [TaskListRowFrame] = []
        let host = NSHostingView(rootView: MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false)
            .onPreferenceChange(TaskSectionHeadingKey.self) { headings = $0 }
            .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
            .frame(width: 364, height: 620))
        try await settle(host)
        XCTAssertFalse(headings.contains("今天"))
        XCTAssertEqual(headings, ["已逾期"])
        XCTAssertTrue(rows.contains { $0.task.id == task.id })
        state.scope = "overdue"
        try await settle(host)
        XCTAssertEqual(headings, ["已逾期"])
    }

    func testCollapseFiltersWholeTreesCompletedSectionAndDateTagResults() async throws {
        _ = NSApplication.shared
        let store = try store()
        let group = try store.addGroup(name: "Collapsible")
        let root = try store.addTask(title: "root #focus", category: group.id, dueDate: Date().dotistDay)
        let child = try store.addTask(title: "child #focus", category: group.id, parentId: root.id, dueDate: Date().dotistDay)
        let completed = try store.addTask(title: "done", category: group.id)
        _ = try store.patchTask(id: completed.id, completed: true)
        let inbox = try store.addTask(title: "ungrouped #focus", category: DotistGroup.inboxID, dueDate: Date().dotistDay)
        let model = try AppModel(store: store)
        let collapse = TaskGroupCollapseStore(defaults: defaults())
        let state = TaskPanelState(collapseStore: collapse)
        state.folded.insert(group.id)
        var rows: [TaskListRowFrame] = []
        var groups: [TaskListGroupFrame] = []
        let host = NSHostingView(rootView: MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false)
            .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
            .onPreferenceChange(TaskListGroupFrame.Key.self) { groups = $0 }
            .frame(width: 364, height: 620))
        try await settle(host)
        XCTAssertEqual(Set(rows.map(\.task.id)), [root.id, child.id, completed.id, inbox.id])
        let expandedHeight = try XCTUnwrap(groups.first { $0.id == group.id }).frame.height
        state.setGroupCollapsed(true, id: group.id)
        try await settle(host)
        XCTAssertEqual(rows.map(\.task.id), [inbox.id])
        let collapsedHeight = try XCTUnwrap(groups.first { $0.id == group.id }).frame.height
        XCTAssertLessThan(collapsedHeight, expandedHeight)
        XCTAssertGreaterThanOrEqual(collapsedHeight, 30, "Header must remain available for expansion")
        state.scope = "today"; state.activeTag = "focus"
        try await settle(host)
        XCTAssertEqual(rows.map(\.task.id), [inbox.id])
        XCTAssertEqual(Set(model.todayTaskSections(tag: "focus").today.matches.map(\.id)), [root.id, child.id, inbox.id], "Collapse changes presentation, never the query or business data")
        state.setGroupCollapsed(false, id: group.id)
        try await settle(host)
        XCTAssertEqual(Set(rows.map(\.task.id)), [root.id, child.id, inbox.id])
        XCTAssertTrue(state.expanded.isEmpty, "Parent tasks continue to show their descendants")
    }

    func testCollapsedGroupAppendTargetMovesSubtreeAfterExistingRoots() throws {
        let store = try store()
        let group = try store.addGroup(name: "Destination")
        let existing = try store.addTask(title: "existing", category: group.id)
        let root = try store.addTask(title: "dragged", category: DotistGroup.inboxID)
        let child = try store.addTask(title: "child", category: root.category, parentId: root.id)
        let state = TaskPanelState(collapseStore: TaskGroupCollapseStore(defaults: defaults()))
        state.setGroupCollapsed(true, id: group.id)
        state.setGroupCollapsed(false, id: group.id)
        let target = TaskCollapsedGroupDrop.target(groupID: group.id)
        XCTAssertNil(target.parentID)
        XCTAssertNil(target.beforeID)
        try TaskDragBatch.commit(ids: [root.id], target: target, store: store)
        let hierarchy = TaskHierarchy(try store.listTasks())
        XCTAssertEqual(hierarchy.outline().filter { $0.category == group.id && $0.parentId == nil }.map(\.id), [existing.id, root.id])
        XCTAssertEqual(hierarchy.children(of: root.id).map(\.id), [child.id])
        XCTAssertFalse(state.collapsedGroups.contains(group.id))
        XCTAssertEqual(TaskCollapsedGroupDrop.removingGap(CGRect(x: 16, y: 80, width: 332, height: 40), gap: CGRect(x: 16, y: 60, width: 332, height: 32)), CGRect(x: 16, y: 60, width: 332, height: 28))
    }
    func testSelectedFilterAndGroupDisclosureKeepOpticalCenterWithinHalfPoint() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
        func render<V: View>(_ view: V, width: CGFloat, height: CGFloat = 30) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: view.frame(width: width, height: height).environment(\.colorScheme, .light).background(Color.white))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        }
        func center(_ rep: NSBitmapImageRep, xRange: Range<CGFloat>) throws -> CGFloat {
            var first = rep.pixelsHigh, last = -1
            for y in 0..<rep.pixelsHigh {
                for x in Int(xRange.lowerBound * 2)..<min(rep.pixelsWide, Int(xRange.upperBound * 2)) {
                    guard let color = rep.colorAt(x: x, y: y) else { continue }
                    if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.8 {
                        first = min(first, y); last = max(last, y)
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(last, first)
            return CGFloat(first + last + 1) / 4
        }
        for (language, title) in [("zh-CN", "工作"), ("en", "Work"), ("ja", "仕事"), ("zh-Hant", "工作")] {
            for selected in [false, true] {
                let rep = try render(DraggableFilterButton(title: title, selected: selected, language: language, choose: {}), width: 100, height: 34)
                XCTAssertEqual(try center(rep, xRange: 0..<100), 17, accuracy: 0.5)
            }
            for collapsed in [true, false] {
                // ImageRenderer omits NSViewRepresentable content. Capture the
                // production header in its actual AppKit window instead.
                let header = GroupCollapseHeader(title: title, language: language, collapsed: collapsed, hovered: true, toggle: {})
                    .environment(\.colorScheme, .light).background(Color.white)
                let fixture = NativeRenderingFixture(header, size: CGSize(width: 200, height: 30))
                defer { fixture.close() }
                let rep = try await fixture.capture(scale: 2)
                let label = try XCTUnwrap(fixture.descendants(GroupHeaderInkView.self).first)
                let frame = fixture.host.convert(label.bounds, from: label)
                let textCenter = try center(rep, xRange: (frame.minX + label.titleInkFrame.minX)..<(frame.minX + label.titleInkFrame.maxX))
                let arrowCenter = try center(rep, xRange: (frame.minX + label.symbolInkFrame.minX)..<(frame.minX + label.symbolInkFrame.maxX))
                XCTAssertEqual(textCenter, 15, accuracy: 0.5)
                XCTAssertEqual(arrowCenter, 15, accuracy: 0.5)
                XCTAssertEqual(textCenter, arrowCenter, accuracy: 0.5)
            }
        }
    }

    func testLiftedBlockFollowsVerticalMotionAndKeepsItsHorizontalColumn() throws {
        let task = try store().addTask(title: "lifted", category: DotistGroup.inboxID)
        let frame = CGRect(x: 16, y: 100, width: 332, height: 32)
        let row = TaskListRowFrame(task: task, frame: frame)
        let drag = TaskListDrag(taskID: task.id, blockIDs: [task.id], visibleBlock: [row], startFrame: frame, startLocation: CGPoint(x: 80, y: 110))
        let motion = TaskDragMotion()
        for point in [CGPoint(x: 80, y: 110), CGPoint(x: 240, y: 140)] {
            motion.location = point
            let renderer = ImageRenderer(content: TaskLiftedBlock(drag: drag, motion: motion) { _ in Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1) }
                .frame(width: 364, height: 620, alignment: .topLeading).background(Color.white))
            renderer.scale = 1
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            var minX = rep.pixelsWide, minY = rep.pixelsHigh
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y) else { continue }
                    if color.redComponent > 0.9 && color.greenComponent < 0.1 { minX = min(minX, x); minY = min(minY, y) }
                }
            }
            XCTAssertEqual(minX, 16)
            XCTAssertEqual(CGFloat(minY), 100 + point.y - 110, accuracy: 0.5)
        }
    }

}
