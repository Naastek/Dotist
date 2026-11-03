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
        for language in ["zh-CN", "en", "fr", "de", "zh-TW"] {
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

    func testEmptyAddGlyphIsCenteredInsteadOfATaskRow() throws {
        _ = NSApplication.shared
        let view = TaskEmptyAddLabel()
            .padding(.horizontal, 16).frame(width: 364, height: 32)
            .foregroundStyle(Color.black).background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        var left = bitmap.pixelsWide, right = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   max(c.redComponent, c.greenComponent, c.blueComponent) < 0.8 {
                    left = min(left, x); right = max(right, x)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(right, left)
        XCTAssertEqual(CGFloat(left + right + 1) / 4, 182, accuracy: 0.5, "Only a centered plus belongs below the empty-state copy")
        XCTAssertLessThanOrEqual(CGFloat(right - left + 1) / 2, 16, "The empty action is a plus, not a task row")
    }

    /// SwiftUI's virtual AccessibilityNode adopts NSAccessibilityElementProtocol,
    /// but neither the complete protocol nor NSAccessibilityButton. Its public
    /// label/children/press selectors still implement the native AX interface.
    private struct NativeAXElement {
        let object: NSObject
        let element: any NSAccessibilityElementProtocol
        func accessibilityFrame() -> CGRect { element.accessibilityFrame() }
        func accessibilityLabel() -> String? {
            let selector = #selector(NSAccessibilityProtocol.accessibilityLabel)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue() as? String
        }
        func accessibilityPerformPress() -> Bool {
            let selector = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
            guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
            // perform(_:) only supports object returns. AXPress returns BOOL;
            // invoke that public ObjC method with its actual scalar signature.
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(implementation, to: Press.self)(object, selector)
        }
    }

    private func accessibilityElement(_ node: Any, id: String) -> NativeAXElement? {
        guard let object = node as? NSObject else { return nil }
        if let element = object as? any NSAccessibilityElementProtocol,
           element.accessibilityIdentifier?() == id { return NativeAXElement(object: object, element: element) }
        let childrenSelector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        guard object.responds(to: childrenSelector) else { return nil }
        let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [Any] ?? []
        for child in children {
            if let found = accessibilityElement(child, id: id) { return found }
        }
        return nil
    }

    private struct HintLayoutFrameKey: PreferenceKey {
        static let defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
    }

    /// AX text frames follow OpticalText's visual correction rather than its
    /// outer layout box. Measure the difference in a known layout; it is not the
    /// VStack's spacing and must not be compared directly with the 12pt gap.
    private func hintAccessibilityInset(title: String, language: String) async throws -> CGFloat {
        var layoutFrame = CGRect.zero
        let hint = OpticalText(title: title, size: 12, language: language)
            .lineLimit(1).truncationMode(.tail).accessibilityIdentifier("hint-reference")
            .background(GeometryReader { geometry in
                Color.clear.preference(key: HintLayoutFrameKey.self, value: geometry.frame(in: .named("hint-layout")))
            })
            .frame(width: 332, height: 32).coordinateSpace(name: "hint-layout")
            .onPreferenceChange(HintLayoutFrameKey.self) { layoutFrame = $0 }
        let fixture = NativeRenderingFixture(hint, size: CGSize(width: 332, height: 32))
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(80))
        fixture.host.layoutSubtreeIfNeeded()
        XCTAssertFalse(layoutFrame.isEmpty)
        let element = try XCTUnwrap(accessibilityElement(fixture.host, id: "hint-reference"))
        let screenLayoutFrame = fixture.window.convertToScreen(fixture.host.convert(layoutFrame, to: nil))
        let inset = element.accessibilityFrame().minY - screenLayoutFrame.minY
        print("EMPTY HINT layout=\(screenLayoutFrame), AX=\(element.accessibilityFrame()), measuredInset=\(inset)")
        return inset
    }

    func testEmptyGroupPlusHandsOffToBottomFieldEditorAndPreservesDraftAndFilter() async throws {
        _ = NSApplication.shared
        // An un-ordered hosting window does not start SwiftUI's lazy AX tree.
        // This is an advertised, process-local AppKit attribute, not a system
        // preference or a request for assistive-access permissions. Restore it.
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhancedUI = try XCTUnwrap(NSApp.accessibilityAttributeValue(enhancedUI) as? NSNumber)
        XCTAssertTrue(NSApp.accessibilityIsAttributeSettable(enhancedUI))
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer {
            NSApp.accessibilitySetValue(previousEnhancedUI, forAttribute: enhancedUI)
            XCTAssertEqual((NSApp.accessibilityAttributeValue(enhancedUI) as? NSNumber)?.boolValue, previousEnhancedUI.boolValue)
        }
        XCTAssertEqual((NSApp.accessibilityAttributeValue(enhancedUI) as? NSNumber)?.boolValue, true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-empty-handoff-\(UUID().uuidString)")
        let suite = "dotist-empty-handoff-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let savedFonts = DotistDesign.fontPreferences
        defer {
            DotistDesign.fontPreferences = savedFonts
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let model = try AppModel(store: store)
        let hint = try XCTUnwrap(TaskEmptyState(scope: "all", groupID: "work").hint)
        let hintInset = try await hintAccessibilityInset(title: model.text(hint), language: model.language)
        for scope in ["all", "tomorrow", "week", "undated"] {
            let state = TaskPanelState(groupID: "work", scope: scope, collapseStore: TaskGroupCollapseStore(defaults: defaults))
            let fixture = NativeRenderingFixture(MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false)
                .background(Color.white).environment(\.colorScheme, .light), size: CGSize(width: 364, height: 620))
            defer { fixture.close() }
            fixture.host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first)
            if scope == "all" {
                let bitmap = try await fixture.capture(scale: fixture.window.backingScaleFactor)
                let path = "/private/tmp/dotist-feedback-empty-group.png"
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
                print("EMPTY GROUP artifact=\(path), screens=\(NSScreen.screens.count), backing=\(fixture.window.backingScaleFactor)x")
            }
            let button = try XCTUnwrap(accessibilityElement(fixture.host, id: "empty-state-add"),
                                       "Missing empty-state add AX button after enabling accessibility")
            print("EMPTY AX screens=\(NSScreen.screens.count), backing=\(fixture.window.backingScaleFactor)x, rootChildren=\(fixture.host.accessibilityChildren()?.count ?? 0), buttonType=\(type(of: button.object)), windowVisible=\(fixture.window.isVisible)")
            XCTAssertFalse(fixture.window.isVisible)
            XCTAssertEqual(button.accessibilityLabel(), model.text(TaskEmptyState.addAccessibilityLabel))
            let frame = button.accessibilityFrame()
            let content = fixture.window.convertToScreen(fixture.host.convert(fixture.host.bounds, to: nil))
            XCTAssertEqual(frame.midX, content.midX, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(frame.width, 32)
            XCTAssertGreaterThanOrEqual(frame.height, 32)
            let hint = try XCTUnwrap(accessibilityElement(fixture.host, id: "empty-state-hint"))
            XCTAssertEqual(hint.accessibilityFrame().minY - hintInset - frame.maxY, 12, accuracy: 0.5, "Plus follows the existing copy")
            print("EMPTY HANDOFF window backing=\(fixture.window.backingScaleFactor)x, screens=\(NSScreen.screens.count), button=\(frame)")
            XCTAssertTrue(button.accessibilityPerformPress())
            try await Task.sleep(for: .milliseconds(80))
            let editor = try XCTUnwrap(field.currentEditor() as? ComposerFieldEditor, "Empty add must focus the existing bottom composer, never an inline TaskEditor")
            XCTAssertTrue(fixture.window.firstResponder === editor)
            XCTAssertTrue(editor.composer === field)
            XCTAssertTrue(fixture.descendants(TaskTextView.self).isEmpty)
            XCTAssertTrue(try store.listTasks().isEmpty, "Focusing must never create an empty task")
            editor.insertText("Keep this draft", replacementRange: NSRange(location: 0, length: 0))
            editor.setSelectedRange(NSRange(location: 5, length: 4))
            let selected = editor.selectedRanges
            XCTAssertTrue(button.accessibilityPerformPress())
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(field.currentEditor() === editor)
            XCTAssertEqual(editor.string, "Keep this draft")
            XCTAssertEqual(editor.selectedRanges, selected, "A reentrant focus request must not reselect or erase the draft")
            XCTAssertTrue(try store.listTasks().isEmpty)
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            for _ in 0..<100 {
                if !model.busy && !model.tasks.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(try store.listTasks().count, 1)
            let created = try XCTUnwrap(try store.listTasks().first)
            XCTAssertEqual(created.title, "Keep this draft")
            XCTAssertEqual(created.category, "work")
            XCTAssertEqual(created.dueDate, TaskEmptyState(scope: scope, groupID: "work").dueDate)
            print("EMPTY COMMIT scope=\(scope), category=\(created.category), due=\(created.dueDate ?? "nil"), title=\(created.title)")
            try store.deleteTask(created.id)
            try await Task.sleep(for: .milliseconds(80))
        }
    }

    func testFocusedBindingAcquiresEditorAfterMountAndCanReenterAfterBlur() async throws {
        _ = NSApplication.shared
        var text = "existing draft"
        var focused = true
        func input() -> ComposerInput {
            ComposerInput(text: Binding(get: { text }, set: { text = $0 }), focused: Binding(get: { focused }, set: { focused = $0 }),
                          placeholder: "Write a task", label: "New task", font: .systemFont(ofSize: 13), commit: {}, navigate: { _ in false }, complete: { _ in false })
        }
        let fixture = NativeRenderingFixture(input(), size: CGSize(width: 280, height: 24))
        defer { fixture.close() }
        let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first)
        try await Task.sleep(for: .milliseconds(80))
        let editor = try XCTUnwrap(field.currentEditor() as? ComposerFieldEditor)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertTrue(editor.composer === field)
        XCTAssertEqual(editor.string, text)
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        fixture.host.rootView = input()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3))
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))
        XCTAssertFalse(focused)
        // Request while detached, let that attempt expire, then attach again.
        let container = try XCTUnwrap(fixture.host.superview)
        fixture.host.removeFromSuperview()
        focused = true
        fixture.host.rootView = input()
        fixture.host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(field.window)
        container.addSubview(fixture.host)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(fixture.window.firstResponder === field.currentEditor())
        XCTAssertNotNil(field.currentEditor())
        XCTAssertEqual(field.stringValue, "existing draft")
        // A pending request must not revive focus once its binding is withdrawn.
        fixture.window.makeFirstResponder(nil)
        focused = true
        fixture.host.rootView = input()
        fixture.host.layoutSubtreeIfNeeded()
        focused = false
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(field.currentEditor())
    }

    func testEmptyStatePlacementAndTranslationsFitLightDarkAndShortWindows() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
        let samples = [
            ("zh-CN", "这个日期范围内没有任务", "写下一件小事，或在下方输入栏添加。"),
            ("en", "No tasks in this date range", "Write down one small thing, or use the input below."),
            ("fr", "Aucune tâche dans cette période", "Notez une petite chose, ou utilisez le champ ci-dessous."),
            ("zh-Hant", "這個日期範圍內沒有任務", "寫下一件小事，或在下方輸入欄新增。"),
        ]
        _ = NSApplication.shared
        for (language, title, hint) in samples {
            for scheme in [ColorScheme.light, .dark] {
                for height: CGFloat in [160, 480] {
                    let view = TaskEmptyStateLayout {
                        TaskEmptyStateContent(title: title, hint: hint, language: language) {
                            TaskEmptyAddLabel()
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
