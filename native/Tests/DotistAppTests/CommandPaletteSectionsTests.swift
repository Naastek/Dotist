import AppKit
import SwiftUI
import XCTest
import DotistCore
@testable import DotistApp

final class CommandPaletteSectionsTests: XCTestCase {
    func testSectionsLimitAndFilterResults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        for index in 0..<8 { _ = try store.addTask(title: "Task \(index)", category: DotistGroup.inboxID) }
        let group = try store.addGroup(name: "Projects")
        let tasks = try store.listTasks()
        let sections = CommandPaletteSections.build(query: "", tasks: tasks, groups: [], viewsTitle: "Views")
        XCTAssertEqual(sections.map(\.title), ["任务", "视图"])
        XCTAssertEqual(sections[0].items.count, 6)
        let grouped = CommandPaletteSections.build(query: "", tasks: tasks, groups: [group], viewsTitle: "Views")
        XCTAssertEqual(grouped.map(\.title), ["任务", "分组", "视图"])
        let groupMatch = CommandPaletteSections.build(query: "project", tasks: tasks, groups: [group], viewsTitle: "Views")
        XCTAssertEqual(groupMatch.map(\.title), ["分组"])
        let filtered = CommandPaletteSections.build(query: "Task 1", tasks: tasks, groups: [], viewsTitle: "Views")
        XCTAssertEqual(filtered.map(\.title), ["任务"])
        XCTAssertEqual(filtered[0].items.count, 1)
        XCTAssertTrue(CommandPaletteSections.build(query: "no matches", tasks: tasks, groups: [], viewsTitle: "Views").isEmpty)
    }

    func testPaletteHeightFollowsVisibleContent() {
        let empty = PaletteMetrics.height(sectionCounts: [])
        let single = PaletteMetrics.height(sectionCounts: [1])
        let several = PaletteMetrics.height(sectionCounts: [3, 2, 1])
        // A short result set should not leave a mostly empty panel behind.
        XCTAssertEqual(empty, PaletteMetrics.searchRow + PaletteMetrics.emptyContent)
        XCTAssertEqual(single, 52 + 18 + 14 + 4 + 38 + 10)
        XCTAssertGreaterThan(several, single)
        XCTAssertLessThan(several, PaletteMetrics.maxHeight)
        // Long lists stay bounded; the list scrolls beyond that.
        XCTAssertEqual(PaletteMetrics.height(sectionCounts: [30, 10, 1]), PaletteMetrics.maxHeight)
    }

    @MainActor func testPaletteRendersAtItsComputedHeight() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-palette-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addTask(title: "写周报")
        _ = try store.addTask(title: "整理会议记录")
        _ = try store.addGroup(name: "Palette A")
        let model = try AppModel(store: store)
        XCTAssertFalse(model.visibleGroups.contains { $0.id == DotistGroup.inboxID })
        let sections = CommandPaletteSections.build(query: "", tasks: model.ordered(model.tasks), groups: model.visibleGroups, viewsTitle: "任务视图")
        XCTAssertEqual(sections.first(where: { $0.title == "分组" })?.items.count, model.visibleGroups.count)
        let height = PaletteMetrics.height(sectionCounts: sections.map(\.items.count))
        XCTAssertLessThan(height, PaletteMetrics.maxHeight)
        let host = NSHostingView(rootView: CommandPalette(model: model, close: {}, reveal: { _ in }, revealGroup: { _ in }, showViews: {})
            .frame(width: PaletteMetrics.width, height: height)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        host.frame = CGRect(x: 0, y: 0, width: PaletteMetrics.width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw XCTSkip("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw XCTSkip("no png") }
        try png.write(to: URL(fileURLWithPath: "/private/tmp/dotist-palette-compact.png"))
    }
}
