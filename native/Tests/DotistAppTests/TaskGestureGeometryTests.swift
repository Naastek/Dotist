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

    private final class RowSize: ObservableObject { @Published var height: CGFloat = 32 }
    private struct SizedRow: View {
        @ObservedObject var size: RowSize
        let task: DotistTask
        let runtime: TaskReorderRuntime
        var body: some View {
            CollapsibleTaskSection(expanded: true) {
                Text(task.title).frame(width: 200, height: size.height).clipped()
                    .accessibilityElement(children: .ignore).accessibilityLabel(task.title)
                    .accessibilityIdentifier("sized-row")
                    .background(TaskPickupFrameProbe(runtime: runtime, role: .row(.before(task.id)), row: .init(task: task, frame: .zero)))
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: TaskListRowFrame.Key.self,
                            value: [.init(task: task, frame: geometry.frame(in: .named("sized-list")))])
                    })
            }
            .coordinateSpace(name: "sized-list")
            .background(TaskPickupFrameProbe(runtime: runtime, role: .panel))
        }
    }

    func testZeroHeightRowLeavesGeometryNativePickupAndAccessibilityTogether() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-zero-row-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path).addTask(title: "Sized task")
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let saved = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(saved, forAttribute: enhanced) }
        let size = RowSize(), runtime = TaskReorderRuntime()
        var rows: [TaskListRowFrame] = []
        let fixture = NativeRenderingFixture(SizedRow(size: size, task: task, runtime: runtime)
            .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }, size: CGSize(width: 240, height: 80))
        defer { fixture.close() }
        func rowAX(_ node: NSObject) -> NSObject? {
            if let element = node as? any NSAccessibilityElementProtocol, element.accessibilityIdentifier?() == "sized-row" { return node }
            let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
            guard node.responds(to: selector) else { return nil }
            for child in node.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] {
                if let found = rowAX(child) { return found }
            }
            return nil
        }
        for _ in 0..<3 { _ = try await fixture.capture(scale: 1) }
        let stale = rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(runtime.pickupFrames(rows).count, 1)
        XCTAssertNotNil(rowAX(fixture.host))
        size.height = 0
        for _ in 0..<3 { _ = try await fixture.capture(scale: 1) }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(runtime.pickupFrames(stale).isEmpty)
        XCTAssertNil(rowAX(fixture.host))
        size.height = 32
        for _ in 0..<3 { _ = try await fixture.capture(scale: 1) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(runtime.pickupFrames(rows).count, 1)
        XCTAssertNotNil(rowAX(fixture.host))
        XCTAssertFalse(fixture.window.isVisible)
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
        runtime.send(.begin(source.task.id, CGPoint(x: 200, y: source.frame.midY)))
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin, offset)
        XCTAssertEqual(scroll.documentView?.bounds.height, documentHeight)
        for row in rows {
            if row.task.id == source.task.id { XCTAssertEqual(row.frame.height, 32) }
            else { XCTAssertEqual(row.frame, before[row.task.id], "One gap replaces only the carried source height") }
        }
        XCTAssertEqual(ghost.height, source.frame.height)
        let sourceIndex = try XCTUnwrap(ordered.firstIndex(of: source))
        let destination = ordered[sourceIndex + 3]
        runtime.send(.move(source.task.id, CGPoint(x: 200, y: destination.frame.midY)))
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(ghost.height, source.frame.height)
        XCTAssertEqual(rows.first { $0.task.id == source.task.id }?.frame.height, 32, "The source itself is the single mounted placeholder")
        XCTAssertEqual(scroll.contentView.bounds.origin, offset)
        XCTAssertEqual(Set(model.tasks.map(\.id)), Set(tasks.map(\.id)))
        runtime.send(.cancel)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        // In an unordered host, drawing flushes SwiftUI's pending layout into
        // AppKit. Measure the restored native document, not its previous frame.
        _ = try await fixture.capture(scale: 1)
        _ = try await fixture.capture(scale: 1)
        XCTAssertEqual(scroll.documentView?.bounds.height, documentHeight)
        XCTAssertEqual(scroll.contentView.bounds.origin, offset)
    }
}
