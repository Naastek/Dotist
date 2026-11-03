import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class TaskGestureGeometryTests: XCTestCase {
    func testDragPresentationPreservesInitialRowsAndScrolledDocument() async throws {
        try await checkDragPresentation(scope: "all")
    }

    func testFilteredDragDoesNotAppendEmptyGroupsOrMoveExistingRows() async throws {
        try await checkDragPresentation(scope: "today")
    }

    private func checkDragPresentation(scope: String) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wJ2-gesture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let tasks = try (0..<24).map { try store.addTask(title: "Task \($0)", category: DotistGroup.inboxID, dueDate: Date().dotistDay) }
        let model = try AppModel(store: store)
        let state = TaskPanelState(scope: scope)
        let runtime = TaskReorderRuntime()
        let motion = TaskDragMotion()
        var rows: [TaskListRowFrame] = []
        var ghost = CGRect.zero
        let fixture = NativeRenderingFixture(
            MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, reorderRuntime: runtime, dragMotion: motion)
                .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
                .onPreferenceChange(TaskGhostFrameKey.self) { ghost = $0 }
                .frame(width: 364, height: 620), size: CGSize(width: 364, height: 620)
        )
        let host = fixture.host
        defer { fixture.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first { ($0.documentView?.frame.height ?? 0) > 620 })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 96))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let ordered = rows.sorted { $0.frame.minY < $1.frame.minY }
        let source = try XCTUnwrap(ordered.first { $0.frame.minY > 150 && $0.frame.maxY < 450 })
        let before = Dictionary(uniqueKeysWithValues: rows.map { ($0.task.id, $0.frame) })
        let offset = scroll.contentView.bounds.origin
        let documentHeight = try XCTUnwrap(scroll.documentView).bounds.height
        let target = TaskReorderEngine.Target(groupID: source.task.category, slot: ordered.firstIndex(of: source) ?? 0, level: 0, parentID: nil, beforeID: ordered.first { $0.frame.minY > source.frame.minY }?.task.id)
        motion.location = CGPoint(x: 200, y: source.frame.midY)
        model.beginDrag(source.task.id, scope: "list:\(scope)")
        runtime.drag = TaskListDrag(taskID: source.task.id, blockIDs: [source.task.id], visibleBlock: [source], startFrame: source.frame,
            startLocation: motion.location, target: target, rootIDs: [source.task.id], initialTarget: target, baselineRows: rows,
            scrollOriginY: offset.y)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin, offset)
        XCTAssertEqual(scroll.documentView?.bounds.height, documentHeight)
        for row in rows {
            XCTAssertEqual(row.frame, before[row.task.id], "Starting a drag must not move or collapse any source/sibling row")
        }
        XCTAssertEqual(ghost, .zero, "The initial source already occupies its slot; do not insert a second gap")
        let sourceIndex = try XCTUnwrap(ordered.firstIndex(of: source))
        let destination = ordered[sourceIndex + 3]
        runtime.drag?.target = .init(groupID: source.task.category, slot: sourceIndex + 2, level: 0, parentID: nil, beforeID: destination.task.id)
        runtime.drag?.ghostBeforeID = destination.task.id
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(ghost.height, source.frame.height)
        XCTAssertEqual(rows.first { $0.task.id == source.task.id }?.frame, source.frame, "The transparent source keeps its original gesture slot")
        XCTAssertEqual(scroll.contentView.bounds.origin, offset)
        XCTAssertEqual(Set(model.tasks.map(\.id)), Set(tasks.map(\.id)))
        runtime.drag = nil
        model.endDrag()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.documentView?.bounds.height, documentHeight)
        XCTAssertEqual(scroll.contentView.bounds.origin, offset)
    }
}
