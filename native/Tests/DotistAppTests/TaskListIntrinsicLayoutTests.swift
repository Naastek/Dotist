import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class TaskListIntrinsicLayoutTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
    }

    func testMainWindowRowsStayIntrinsicAtEveryPanelHeight() async throws {
        _ = NSApplication.shared
        print("wQ1 WindowServer displays: \(NSScreen.screens.count); all offscreen layout assertions still execute")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wQ1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let work = try store.updateGroup("work", name: "work")
        _ = try store.updateGroup("life", name: "life")
        try store.deleteGroup("study")
        _ = try store.addGroup(name: "side project")
        let first = try store.addTask(title: "验收测试", category: work.id)
        for title in ["子任务一", "子任务二", "子任务三"] {
            _ = try store.addTask(title: title, category: work.id, parentId: first.id)
        }
        _ = try store.addTask(title: "的", category: work.id)
        let done = try store.addTask(title: "完成记录", category: work.id)
        _ = try store.patchTask(id: done.id, completed: true)
        let model = try AppModel(store: store)
        let state = TaskPanelState(scope: "all")
        state.folded.insert(work.id)
        var baseline: [String: CGRect] = [:]
        var baselineGroups: [String: CGRect] = [:]
        for height: CGFloat in [620, 900, 1400] {
            var rows: [TaskListRowFrame] = []
            var groups: [TaskListGroupFrame] = []
            let host = NSHostingView(rootView:
                MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {})
                    .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
                    .onPreferenceChange(TaskListGroupFrame.Key.self) { groups = $0 }
                    .frame(width: 364, height: height)
                    .background(Color.white).environment(\.colorScheme, .light)
            )
            host.frame = CGRect(x: 0, y: 0, width: 364, height: height)
            let window = offscreenWindow(host)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(rows.count, 6)
            let ordered = rows.sorted { $0.frame.minY < $1.frame.minY }
            for row in ordered {
                print("wQ1 panel=\(height) row=\(row.task.title) frame=\(row.frame)")
                XCTAssertEqual(row.frame.height, row.sub ? 28 : 32, accuracy: 0.5, row.task.title)
                if let original = baseline[row.task.id] {
                    XCTAssertEqual(row.frame.minY, original.minY, accuracy: 0.5, row.task.title)
                }
            }
            for (a, b) in zip(ordered.prefix(4), ordered.dropFirst()) {
                XCTAssertEqual(b.frame.minY - a.frame.maxY, 0, accuracy: 0.5, "Adjacent task rows")
            }
            let sections = groups.filter { $0.id != DotistGroup.inboxID }.sorted { $0.frame.minY < $1.frame.minY }
            XCTAssertEqual(sections.count, 3)
            for group in sections {
                print("wQ1 panel=\(height) group=\(group.id) frame=\(group.frame)")
                if let original = baselineGroups[group.id] { XCTAssertEqual(group.frame, original) }
            }
            // Flat group frames describe their header only. Include the real
            // member rows when measuring the section's complete extent.
            for (a, b) in zip(sections, sections.dropFirst()) {
                let lastMember = rows.filter { $0.task.category == a.id }.map(\.frame.maxY).max() ?? a.frame.maxY
                XCTAssertEqual(b.frame.minY, max(a.frame.maxY, lastMember), accuracy: 0.5,
                               "The next section follows the last row without surplus space")
                if b.id != work.id {
                    XCTAssertEqual(b.frame.height, 8 + 32, accuracy: 0.5, "Empty section = 8 pt gap + one 32 pt header row")
                }
            }
            if baseline.isEmpty { baseline = Dictionary(uniqueKeysWithValues: rows.map { ($0.task.id, $0.frame) }) }
            if baselineGroups.isEmpty { baselineGroups = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.frame) }) }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            rep.size = host.bounds.size
            for section in sections {
                // A 30 pt label is centered in the ordinary 32 pt header row.
                // Measure live ink, so a stretched header still fails even if
                // its published frame happens to have the right height.
                let top = section.frame.minY + (section.id == work.id ? 6 : 8) + 1
                let mask = CGRect(x: 16, y: top, width: 200, height: 30)
                let center = try inkCenter(rep, in: mask)
                print("wQ1 panel=\(height) header=\(section.id) mask=\(mask) inkCenterY=\(center)")
                XCTAssertEqual(center, top + 15, accuracy: 0.5, "Group-header ink stays on its intrinsic axis")
            }
            for row in ordered {
                let depth = model.depth(of: row.task)
                let circle = CGRect(x: TaskRowMetrics.circleX(depth), y: row.frame.minY, width: TaskRowMetrics.diameter(depth), height: row.frame.height)
                let text = CGRect(x: TaskRowMetrics.textX(depth), y: row.frame.minY, width: 70, height: row.frame.height)
                XCTAssertEqual(try inkCenter(rep, in: circle), try inkCenter(rep, in: text), accuracy: 0.5, "Circle/title ink: \(row.task.title)")
            }
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/private/tmp/dotist-wQ1-panel-\(Int(height)).png"))
        }
    }

    private func inkCenter(_ image: NSBitmapImageRep, in rect: CGRect) throws -> CGFloat {
        let scale = CGFloat(image.pixelsWide) / image.size.width
        var first = image.pixelsHigh, last = -1
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.1,
                      max(color.redComponent, color.greenComponent, color.blueComponent) < 0.8 else { continue }
                first = min(first, y); last = max(last, y)
            }
        }
        XCTAssertGreaterThanOrEqual(last, first, "No ink in \(rect)")
        return CGFloat(first + last + 1) / (2 * scale)
    }

    func testTallTextUsesItsIntrinsicHeightWithoutAddingSingleLinePadding() throws {
        for depth in 0...4 {
            for titleHeight: CGFloat in [20, 40, 60] {
                let row = TaskRowLayout(depth: depth) {
                    TaskCheckmark(depth: depth, completed: false, children: [], emphasized: false)
                    Color.blue.frame(height: titleHeight)
                    Color.clear.frame(width: 0, height: 0)
                }
                let host = NSHostingView(rootView: row.frame(width: 332))
                XCTAssertEqual(host.fittingSize.height, max(depth == 0 ? 32 : 28, titleHeight), accuracy: 0.5)
            }
        }
    }

    func testEmptyStateNeverAdoptsAnIncidentalParentHeightProposal() throws {
        for height: CGFloat in [620, 900, 1400] {
            var frame = CGRect.zero
            let content = TaskEmptyStateLayout {
                Color.blue.frame(height: 40)
            }.background(GeometryReader { geometry in
                Color.clear.preference(key: IntrinsicFrameKey.self, value: ["empty": geometry.frame(in: .global)])
            }).onPreferenceChange(IntrinsicFrameKey.self) { frame = $0["empty"] ?? .zero }
            let host = NSHostingView(rootView: content.frame(width: 332, height: height, alignment: .topLeading))
            host.frame = CGRect(x: 0, y: 0, width: 332, height: height)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(frame.height, 40, accuracy: 0.5)
        }
    }

    func testEmptyOverlayRemainsScrollableBelowAuxiliarySectionsInShortWindows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wQ1-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!.dotistDay
        _ = try store.addTask(title: "明天的辅助任务", dueDate: tomorrow)
        let done = try store.addTask(title: "今天的完成记录")
        _ = try store.patchTask(id: done.id, completed: true)
        let model = try AppModel(store: store)
        for height: CGFloat in [260, 620] {
            let state = TaskPanelState(scope: "today")
            var rows: [TaskListRowFrame] = []
            let host = NSHostingView(rootView:
                MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {})
                    .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
                    .frame(width: 364, height: height).background(Color.white).environment(\.colorScheme, .light)
            )
            host.frame = CGRect(x: 0, y: 0, width: 364, height: height)
            let window = offscreenWindow(host)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(rows.isEmpty, "Only folded auxiliary sections should be present")
            let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.max { $0.bounds.height < $1.bounds.height })
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/private/tmp/dotist-wQ1-empty-\(Int(height)).png"))
            if height == 260 {
                // Two 28 pt disclosures + their 20 pt gap + 16 pt safe area,
                // followed by the complete title/hint/add block.
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(scroll.documentView).bounds.height, 92 + 80)
                XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentView.bounds.height)
            }
        }
    }

    func testManagerAndCommandRowsDoNotMoveWhenTheirWindowsGrow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wQ1-secondary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addTask(title: "甲任务 #alpha")
        _ = try store.addTask(title: "乙任务 #beta")
        let model = try AppModel(store: store)
        let views: [(String, AnyView, [CGRect])] = [
            ("groups", AnyView(GroupManager(model: model, close: {}, tags: {})), [CGRect(x: 42, y: 44, width: 120, height: 40), CGRect(x: 42, y: 84, width: 120, height: 40)]),
            ("tags", AnyView(TagManager(model: model, close: {}, groups: {}, select: { _ in })), [CGRect(x: 42, y: 44, width: 120, height: 40), CGRect(x: 42, y: 84, width: 120, height: 40)]),
            ("command", AnyView(CommandPalette(model: model, close: {}, reveal: { _ in }, revealGroup: { _ in }, showViews: {})), [CGRect(x: 18, y: 60, width: 220, height: 44), CGRect(x: 18, y: 104, width: 220, height: 44)]),
        ]
        for (name, view, masks) in views {
            var baseline: [CGFloat] = []
            for height: CGFloat in [620, 900, 1400] {
                let host = NSHostingView(rootView: view.frame(width: 364, height: height).background(Color.white).environment(\.colorScheme, .light))
                host.frame = CGRect(x: 0, y: 0, width: 364, height: height)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                rep.size = host.bounds.size
                let centers = try masks.map { try inkCenter(rep, in: $0) }
                if baseline.isEmpty { baseline = centers }
                for (a, b) in zip(centers, baseline) { XCTAssertEqual(a, b, accuracy: 0.5, name) }
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/private/tmp/dotist-wQ1-\(name)-\(Int(height)).png"))
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func offscreenWindow(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: host.frame.width, height: host.frame.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        return window
    }

    func testSettingsControlsAndGanttRowsKeepTheirIntrinsicHeight() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wQ1-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let updater = NativeUpdater(model: model)
        var baseline: [CGRect] = []
        for height: CGFloat in [620, 900, 1400] {
            let view = SettingsWindow(model: model, updater: updater, beginShortcutCapture: {}, endShortcutCapture: { _, _ in }, resetWindowSize: {})
            let host = NSHostingView(rootView: view.frame(width: 800, height: height))
            host.frame = CGRect(x: 0, y: 0, width: 800, height: height)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let frames = descendants(host).compactMap { $0 as? NSSegmentedControl }.map { host.convert($0.bounds, from: $0) }.sorted { $0.minY < $1.minY }
            XCTAssertFalse(frames.isEmpty, "Inspect real settings controls")
            if baseline.isEmpty { baseline = frames }
            XCTAssertEqual(frames.count, baseline.count)
            for (frame, original) in zip(frames, baseline) {
                XCTAssertEqual(frame.minY, original.minY, accuracy: 0.5)
                XCTAssertEqual(frame.height, original.height, accuracy: 0.5)
            }

            var rowFrames: [String: CGRect] = [:]
            let gantt = GanttRowLayout {
                OpticalText(title: "视图窗口任务", size: 14, language: "zh-CN").frame(width: 220)
                GeometryReader { _ in Color.clear }
            }.background(GeometryReader { geometry in
                Color.clear.preference(key: IntrinsicFrameKey.self, value: ["gantt": geometry.frame(in: .global)])
            }).onPreferenceChange(IntrinsicFrameKey.self) { rowFrames = $0 }
            let ganttHost = NSHostingView(rootView: gantt.frame(width: 600, height: height, alignment: .topLeading))
            ganttHost.frame = CGRect(x: 0, y: 0, width: 600, height: height)
            ganttHost.layoutSubtreeIfNeeded()
            XCTAssertEqual(try XCTUnwrap(rowFrames["gantt"]).height, 56, accuracy: 0.5,
                           "The view-window label sizes the Gantt row, even with a GeometryReader track")

            let header = GroupCollapseHeader(title: "work", language: "en", collapsed: false, hovered: false, empty: false, toggle: {})
                .padding(.top, 4)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: IntrinsicFrameKey.self, value: ["header": geometry.frame(in: .global)])
                }).onPreferenceChange(IntrinsicFrameKey.self) { rowFrames = $0 }
            let headerHost = NSHostingView(rootView: header.frame(width: 332, height: height, alignment: .topLeading))
            headerHost.frame = CGRect(x: 0, y: 0, width: 332, height: height)
            headerHost.layoutSubtreeIfNeeded()
            XCTAssertEqual(try XCTUnwrap(rowFrames["header"]).height, 34, accuracy: 0.5)
        }
    }
}

private struct IntrinsicFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}
