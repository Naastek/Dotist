import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class TaskEmptyStateTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))! }

    func testEveryPresetCopyAndCreationDefault() {
        let cases: [(String, String, String?, Bool)] = [
            ("all", "这里什么都没有", nil, true),
            ("today", "今天没有安排", "2026-11-04", true),
            ("tomorrow", "明天没有任务", "2026-11-05", true),
            ("week", "本周没有任务", "2026-11-02", true),
            ("nextweek", "下周没有任务", "2026-11-09", true),
            ("next7", "未来 7 天没有任务", "2026-11-04", true),
            ("overdue", "没有已逾期的任务", nil, false),
            ("undated", "没有无日期的任务", nil, true),
            ("done", "还没有已完成的任务", nil, false),
        ]
        for (scope, title, due, adding) in cases {
            for groupID in [nil, "project"] as [String?] {
                let state = TaskEmptyState(scope: scope, groupID: groupID, now: now, calendar: calendar)
                XCTAssertEqual(state.title, scope == "all" && groupID != nil ? "这个分组还没有任务" : title, scope)
                XCTAssertEqual(state.dueDate, due, scope)
                XCTAssertEqual(state.groupID, groupID ?? DotistGroup.inboxID)
                XCTAssertEqual(state.allowsAdding, adding)
                XCTAssertEqual(state.hint, adding ? "写下一件小事，或在下方输入栏添加。" : nil)
            }
        }
        XCTAssertEqual(TaskEmptyState.addTitle, "添加任务")
        XCTAssertEqual(TaskEmptyState.addAccessibilityLabel, "在这里添加任务")
    }

    func testCustomRangeOverridesPresetAndKeepsGroup() {
        for scope in ["all", "today", "done", "overdue"] {
            let state = TaskEmptyState(scope: scope, groupID: "project", customRange: TaskDateRange("2026-12-12", "2026-12-03"), now: now, calendar: calendar)
            XCTAssertEqual(state.title, "这个日期范围内没有任务")
            XCTAssertEqual(state.dueDate, "2026-12-03")
            XCTAssertEqual(state.groupID, "project")
            XCTAssertTrue(state.allowsAdding)
            XCTAssertNotNil(state.hint)
        }
        var sunday = calendar
        sunday.firstWeekday = 1
        XCTAssertEqual(TaskEmptyState(scope: "week", groupID: nil, now: now, calendar: sunday).dueDate, "2026-11-01")
    }

    func testCreationDefaultsProduceTasksThatMatchTheirFilter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wN2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let group = try store.addGroup(name: "Project")
        for scope in ["today", "tomorrow", "week", "nextweek", "next7", "undated", "all"] {
            for groupID in [nil, group.id] as [String?] {
                let state = TaskEmptyState(scope: scope, groupID: groupID, now: now, calendar: calendar)
                let task = try store.addTask(title: TaskDraftFlow.titleToSave("  A small task  ")!, category: state.groupID, dueDate: state.dueDate)
                XCTAssertNil(task.parentId)
                XCTAssertFalse(task.completed)
                XCTAssertEqual(task.title, "A small task")
                let result = TaskFiltering([task], now: now, calendar: calendar).filter(scope: scope, groupID: groupID)
                XCTAssertEqual(result.matches.map(\.id), [task.id], scope)
            }
        }
        XCTAssertNil(TaskDraftFlow.titleToSave("  \n  "))
    }

    func testOnlyComposerRenamesImplicitInboxInEveryLanguage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wN2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let group = try store.addGroup(name: "Project")
        for language in ["zh-CN", "en", "ja", "zh-TW"] {
            var patch = DotistSettingsPatch()
            patch.language = language
            _ = try store.updateSettings(patch)
            let model = try AppModel(store: store)
            XCTAssertEqual(model.composerGroupDisplayName(nil), model.text("全部"))
            XCTAssertEqual(model.composerGroupDisplayName(DotistGroup.inboxID), model.text("全部"))
            XCTAssertEqual(model.groupDisplayName(DotistGroup.inboxID), model.text("无分组"))
            XCTAssertEqual(model.composerGroupDisplayName(group.id), "Project")
        }
    }

    func testDistanceFadingHoverFocusAndAccessibility() {
        XCTAssertEqual(TaskDateFilterMetrics.rowHeight, 34)
        let expected = [1.0, 0.78, 0.58, 0.42, 0.32, 0.32]
        for distance in expected.indices {
            XCTAssertEqual(TaskDateFilterMetrics.opacity(distance: distance), expected[distance])
            XCTAssertGreaterThanOrEqual(TaskDateFilterMetrics.opacity(distance: distance, hovered: true), 0.9)
            XCTAssertEqual(TaskDateFilterMetrics.opacity(distance: distance, focused: true), 1)
            XCTAssertEqual(TaskDateFilterMetrics.opacity(distance: distance, increasedContrast: true), 1)
            XCTAssertEqual(TaskDateFilterMetrics.opacity(distance: distance, voiceOver: true), 1)
        }
        let filters = ["done", "all", "today", "week", "undated"]
        XCTAssertEqual(filters.map { TaskDateFilterMetrics.distance(of: $0, selected: "today", in: filters) }, [2, 1, 0, 1, 2])
        XCTAssertEqual(TaskDateFilterMetrics.distance(of: "week", selected: nil, in: filters), 0)
        XCTAssertEqual(TaskDateFilterMetrics.distance(of: "week", selected: "hidden", in: filters), 0)
    }

    func testEmptyStateCopyUsesFullwidthPunctuation() throws {
        let scopes = ["all", "today", "tomorrow", "week", "nextweek", "next7", "overdue", "undated", "done"]
        var copy = scopes.map { TaskEmptyState(scope: $0, groupID: nil, now: now, calendar: calendar).title }
        copy += [TaskEmptyState(scope: "all", groupID: "project").title,
                 TaskEmptyState(scope: "today", groupID: nil, customRange: TaskDateRange("2026-11-01", "2026-11-02")).title,
                 TaskEmptyState.addTitle, TaskEmptyState.addAccessibilityLabel]
        let hint = try XCTUnwrap(TaskEmptyState(scope: "today", groupID: nil).hint)
        copy.append(hint)
        XCTAssertTrue(hint.hasSuffix("。"))
        let halfwidth = try NSRegularExpression(pattern: #"[,.:;!?()]|\.\.\.|--|[0-9][\p{Han}]|[\p{Han}][A-Za-z]"#)
        for value in copy {
            XCTAssertNil(halfwidth.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), value)
        }
    }

    func testEmptyStatePlacementAndTranslationsFitLightDarkAndShortWindows() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
        let samples = [
            ("zh-CN", "这个日期范围内没有任务", "写下一件小事，或在下方输入栏添加。", "添加任务"),
            ("en", "No tasks in this date range", "Write down one small thing, or use the input below.", "Add task"),
            ("ja", "この期間のタスクはありません", "小さなことを書き留めるか、下の入力欄から追加してください。", "タスクを追加"),
            ("zh-Hant", "這個日期範圍內沒有任務", "寫下一件小事，或在下方輸入欄新增。", "新增任務"),
        ]
        _ = NSApplication.shared
        for (language, title, hint, add) in samples {
            for scheme in [ColorScheme.light, .dark] {
                for height: CGFloat in [160, 480] {
                    let view = TaskEmptyStateLayout {
                        TaskEmptyStateContent(title: title, hint: hint, language: language) {
                            TaskEmptyAddLabel(title: add, language: language)
                        }
                    }.padding(.horizontal, 16).frame(width: 364, height: height).environment(\.colorScheme, scheme)
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: 364, height: height)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.fittingSize.width, 364, accuracy: 0.5)
                    XCTAssertEqual(host.fittingSize.height, height, accuracy: 0.5)
                    let renderer = ImageRenderer(content: view.background(scheme == .light ? Color.white : Color.black))
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.cgImage)
                    XCTAssertEqual(image.width, 728)
                    XCTAssertEqual(image.height, Int(height * 2))
                    if height == 480 {
                        let rep = NSBitmapImageRep(cgImage: image)
                        let path = "/private/tmp/dotist-wN2-empty-\(language)-\(scheme == .light ? "light" : "dark").png"
                        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
                    }
                }
            }
        }
        XCTAssertEqual(TaskEmptyStateLayout.top(height: 480, contentHeight: 80) + 40, 480 * 0.38, accuracy: 0.01)
        XCTAssertEqual(TaskEmptyStateLayout.top(height: 60, contentHeight: 80), 0)
        XCTAssertGreaterThanOrEqual(TaskEmptyStateLayout.top(height: 160, contentHeight: 92, minimumTop: 92), 92,
                                   "Folded auxiliary section hit boxes must remain unobstructed")
    }
}
