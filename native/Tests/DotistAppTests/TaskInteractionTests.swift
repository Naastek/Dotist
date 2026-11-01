import AppKit
import Combine
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

final class TaskSelectionTests: XCTestCase {
    func testRangeUsesDisplayedOrderAndCommandTogglesIndividualRows() {
        let order = ["root", "deep", "sibling", "other-group"]
        var selection = TaskSelection()
        selection.click("deep", order: order, shift: false, command: false)
        XCTAssertTrue(selection.ids.isEmpty)
        selection.click("other-group", order: order, shift: true, command: false)
        XCTAssertEqual(selection.ids, ["deep", "sibling", "other-group"])
        selection.click("sibling", order: order, shift: false, command: true)
        XCTAssertEqual(selection.ids, ["deep", "other-group"])
        XCTAssertEqual(selection.last(in: order), "other-group")
        selection.click("root", order: order, shift: true, command: false)
        XCTAssertEqual(selection.ids, ["root", "deep", "sibling"])
        selection.clear()
        XCTAssertNil(selection.anchor)
        XCTAssertTrue(selection.ids.isEmpty)
    }

    func testShrinkingKeyboardRangeKeepsOriginalAnchor() {
        let order = ["a", "b", "c", "d"]
        var selection = TaskSelection(anchor: "b")
        selection.click("d", order: order, shift: true, command: false)
        selection.click("c", order: order, shift: true, command: false)
        XCTAssertEqual(selection.ids, ["b", "c"])
        XCTAssertEqual(selection.anchor, "b")
        selection.click("d", order: order, shift: false, command: false)
        XCTAssertTrue(selection.ids.isEmpty)
    }
}

@MainActor
final class TaskInteractionTests: XCTestCase {
    private func store() throws -> TaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-interaction-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
    }

    func testDraftTabChangesOnlyParentClampsDepthAndNeverRevivesText() throws {
        let store = try store()
        var chain: [DotistTask] = []
        for depth in 0...4 {
            chain.append(try store.addTask(title: "level \(depth)", category: "work", parentId: chain.last?.id))
        }
        let tasks = try store.listTasks()
        var parent: String? = nil
        for expectedDepth in 1...4 {
            parent = TaskDraftFlow.parent(reverse: false, current: parent, after: chain[4], tasks: tasks)
            XCTAssertEqual(parent, chain[expectedDepth - 1].id)
        }
        XCTAssertEqual(TaskDraftFlow.parent(reverse: false, current: parent, after: chain[4], tasks: tasks), chain[3].id)
        XCTAssertEqual(TaskDraftFlow.parent(reverse: true, current: parent, after: chain[4], tasks: tasks), chain[2].id)
        XCTAssertNil(TaskDraftFlow.parent(reverse: true, current: chain[0].id, after: chain[1], tasks: tasks))
        XCTAssertEqual(TaskDraftFlow.parent(reverse: false, current: nil, after: chain[0], tasks: tasks), chain[0].id)
        XCTAssertNil(TaskDraftFlow.titleToSave(" \n\t "))
        XCTAssertEqual(TaskDraftFlow.titleToSave(" fresh \n"), "fresh")
        XCTAssertEqual(try store.listTasks(), tasks, "Tab on an empty or populated draft never writes to the database")
    }

    func testSelectionPublishesOnlyChangedRowBitsAndPointerHasSeparatePublisher() {
        let controller = TaskSelectionController()
        let a = controller.row("a"), b = controller.row("b"), c = controller.row("c")
        var aChanges = 0, bChanges = 0, cChanges = 0, listChanges = 0
        let tokens = [a.objectWillChange.sink { aChanges += 1 }, b.objectWillChange.sink { bChanges += 1 }, c.objectWillChange.sink { cChanges += 1 }, controller.objectWillChange.sink { listChanges += 1 }]
        controller.update { $0.click("b", order: ["a", "b", "c"], shift: false, command: true) }
        XCTAssertEqual([aChanges, bChanges, cChanges, listChanges], [0, 1, 0, 0])
        let motion = TaskDragMotion()
        var motionChanges = 0
        let motionToken = motion.objectWillChange.sink { motionChanges += 1 }
        for value in 0..<1000 { motion.location = CGPoint(x: value, y: value) }
        XCTAssertEqual(motionChanges, 1000)
        XCTAssertEqual(listChanges, 0)
        withExtendedLifetime((tokens, motionToken)) {}
    }

    func testMainWindowRendersAllFiveLevelsInAllAndTodayAndTagContext() async throws {
        let store = try store()
        var chain: [DotistTask] = []
        for depth in 0...4 {
            chain.append(try store.addTask(title: depth == 4 ? "deep #leaf" : "level \(depth)", category: DotistGroup.inboxID, parentId: chain.last?.id, dueDate: Date().dotistDay))
        }
        let model = try AppModel(store: store)
        let state = TaskPanelState()
        state.expanded = Set(chain.map(\.id))
        var rows: [TaskListRowFrame] = []
        let view = MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false)
            .frame(width: 364, height: 620)
            .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
        let host = NSHostingView(rootView: view)
        for scope in ["all", "today"] {
            state.scope = scope
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(Set(rows.map { $0.task.id }), Set(chain.map(\.id)), "Deep tasks must remain visible in \(scope)")
        }
        state.scope = "all"; state.activeTag = "leaf"
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(Set(rows.map { $0.task.id }), Set(chain.map(\.id)), "A matching deep tag keeps the full ancestor context")
    }

    func testMainWindowDoesNotRebuildListForPointerFrames() async throws {
        let store = try store()
        for index in 0..<100 { _ = try store.addTask(title: "row \(index)", category: DotistGroup.inboxID) }
        let model = try AppModel(store: store)
        let motion = TaskDragMotion()
        let panelState = TaskPanelState()
        let selection = TaskSelectionController()
        let view = MainWindow(model: model, state: panelState, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, dragMotion: motion, selection: selection)
        let host = NSHostingView(rootView: view.frame(width: 364, height: 620))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let before = MainWindow.taskListRenders
        let start = ContinuousClock.now
        for index in 0..<1000 { motion.location = CGPoint(x: 100, y: index) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(MainWindow.taskListRenders, before, "Only the lifted layer may subscribe to pointer-frame changes")
        print("wD2 pointer benchmark: 1000 updates, list rebuilds=\(MainWindow.taskListRenders - before), elapsed=\(start.duration(to: .now))")
        let order = model.tasks.map(\.id)
        for index in 0..<1000 {
            let id = order[index % order.count]
            selection.update { $0.click(id, order: order, shift: false, command: true) }
            selection.row(id).focusRequest.send()
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(MainWindow.taskListRenders, before, "Selection and focus belong to each row, not the outline")
        print("wD2 selection benchmark: 1000 selection/focus updates, list rebuilds=\(MainWindow.taskListRenders - before)")
    }

    func testDelayedEditorBlurKeepsTheOriginalSessionCallback() async {
        let editor = TaskTextView(frame: .zero)
        var calls: [String] = []
        editor.blur = { calls.append("original") }
        XCTAssertTrue(editor.resignFirstResponder())
        editor.blur = { calls.append("reused") }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(calls, ["original"])
    }

    func testBatchDragMovesAllSelectedRootsAndTheirHiddenDescendantsInOrder() throws {
        let store = try store()
        let parent = try store.addTask(title: "target", category: "work")
        let a = try store.addTask(title: "a", category: "work")
        let child = try store.addTask(title: "hidden", category: "work", parentId: a.id)
        let b = try store.addTask(title: "b", category: "work")
        let end = try store.addTask(title: "end", category: "work", parentId: parent.id)
        try TaskDragBatch.commit(ids: [a.id, b.id], target: .init(groupID: "work", slot: 1, level: 1, parentID: parent.id, beforeID: end.id), store: store)
        let hierarchy = TaskHierarchy(try store.listTasks())
        XCTAssertEqual(hierarchy.children(of: parent.id).map(\.id), [a.id, b.id, end.id])
        XCTAssertEqual(hierarchy.depth(of: child.id), 2)
        let before = try store.snapshot()
        XCTAssertThrowsError(try TaskDragBatch.commit(ids: [a.id, b.id], target: .init(groupID: "work", slot: 0, level: 3, parentID: child.id, beforeID: nil), store: store))
        XCTAssertEqual(try store.snapshot(), before)
    }

    func testProgressUsesDirectChildOrderAndCapsLargeFamiliesAtTwelve() {
        XCTAssertEqual(TaskProgressSegments.values(completed: [true]), [true])
        XCTAssertEqual(TaskProgressSegments.values(completed: [true, false, true]), [true, false, true])
        let large = TaskProgressSegments.values(completed: Array(repeating: true, count: 13) + Array(repeating: false, count: 13))
        XCTAssertEqual(large.count, 12)
        XCTAssertEqual(large.filter { $0 }.count, 6)
    }
}

@MainActor
final class TaskRowAlignmentTests: XCTestCase {
    func testAllFiveLevelsAndCircleCenterMatchWholeTextBlock() {
        XCTAssertEqual((0...4).map(TaskRowMetrics.textX), [42, 64, 86, 108, 130])
        XCTAssertEqual((0...4).map(TaskRowMetrics.circleX), [16, 42, 64, 86, 108])
        for depth in 0...4 {
            for titleHeight: CGFloat in [20, 40, 60] {
                let circle = TaskRowMetrics.circleFrame(depth, titleHeight: titleHeight)
                let rowHeight = TaskRowMetrics.height(depth, titleHeight: titleHeight)
                let textTop = (rowHeight - titleHeight) / 2
                XCTAssertEqual(circle.midY, textTop + titleHeight / 2, accuracy: 0.001)
                XCTAssertEqual(circle.width, depth == 0 ? 16 : 13)
            }
        }
    }

    func testImageRendererMeasuresActualLayoutColumnsAndVerticalCenters() throws {
        // Colored primitives avoid NSTextView/WindowServer placeholders. This
        // exercises the SAME Layout that places live titles and their circles.
        for depth in 0...4 {
            for titleHeight: CGFloat in [20, 40, 60] {
                let renderer = ImageRenderer(content:
                    TaskRowLayout(depth: depth) {
                        Rectangle().fill(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1))
                        Rectangle().fill(Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1)).frame(height: titleHeight)
                        Rectangle().fill(Color.green).frame(width: 18, height: 20)
                    }.padding(.horizontal, 16).frame(width: 364).background(Color.white)
                )
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                let rep = NSBitmapImageRep(cgImage: image)
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wD2-layout-d\(depth)-h\(Int(titleHeight)).png")
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: path)
                var red: [CGPoint] = [], blue: [CGPoint] = []
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        guard let color = rep.colorAt(x: x, y: y) else { continue }
                        if color.redComponent > 0.9 && color.blueComponent < 0.1 && color.greenComponent < 0.1 { red.append(CGPoint(x: CGFloat(x) / 2, y: CGFloat(y) / 2)) }
                        if color.blueComponent > 0.9 && color.redComponent < 0.1 && color.greenComponent < 0.1 { blue.append(CGPoint(x: CGFloat(x) / 2, y: CGFloat(y) / 2)) }
                    }
                }
                let redX = try XCTUnwrap(red.map(\.x).min()), blueX = try XCTUnwrap(blue.map(\.x).min())
                let redY = (try XCTUnwrap(red.map(\.y).min()) + XCTUnwrap(red.map(\.y).max()) + 0.5) / 2
                let blueY = (try XCTUnwrap(blue.map(\.y).min()) + XCTUnwrap(blue.map(\.y).max()) + 0.5) / 2
                XCTAssertEqual(redX, TaskRowMetrics.circleX(depth), accuracy: 0.5)
                XCTAssertEqual(blueX, TaskRowMetrics.textX(depth), accuracy: 0.5)
                XCTAssertEqual(redY, blueY, accuracy: 0.5)
                print("wD2 measured depth=\(depth) titleHeight=\(titleHeight) circleX=\(redX) textX=\(blueX) circleCenterY=\(redY) textCenterY=\(blueY) png=\(path.path)")
            }
        }
    }
}
