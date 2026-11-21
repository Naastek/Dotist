import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class TaskContentPresentationTests: XCTestCase {
    private struct Swatch: View {
        @ObservedObject var state: TaskPanelState
        var body: some View {
            TaskContentPresentation(state: state, dragging: false) {
                (state.groupID == "life" ? Color.green : state.scope == "today" ? Color.blue : Color.red)
            }.background(Color.white)
        }
    }
    private final class MotionControls: ObservableObject {
        @Published var dragging = false
    }
    private struct ControlledSwatch: View {
        @ObservedObject var state: TaskPanelState
        @ObservedObject var controls: MotionControls
        var body: some View {
            TaskContentPresentation(state: state, dragging: controls.dragging) {
                (state.groupID == "life" ? Color.green : state.scope == "today" ? Color.blue : Color.red)
            }.background(Color.white)
        }
    }

    func testLogicalMotionOverrideControlsBothSwiftUIAccessibilityValues() async throws {
        // SwiftUI's public getter is read-only. Its backing environment key lets
        // this fixture exercise either value without changing desktop settings.
        for reduced in [false, true] {
            let clock = LayoutMotionTestClock(reduceMotion: reduced)
            defer { clock.restore() }
            for environment in [false, true] {
                let state = TaskPanelState(scope: "all")
                let fixture = NativeRenderingFixture(Swatch(state: state)
                    .environment(\._accessibilityReduceMotion, environment), size: CGSize(width: 240, height: 160))
                defer { fixture.close() }
                _ = try await fixture.capture(scale: 2)
                let surface = try XCTUnwrap(fixture.descendants(TaskContentTransitionView.self).first)
                state.scope = "today"
                _ = try await fixture.capture(scale: 2)
                XCTAssertEqual(surface.outgoingOpacity, reduced ? 0 : 1)
                try await clock.advance(by: 0.06)
                let image = try await fixture.capture(scale: 2)
                if reduced { XCTAssertEqual(surface.outgoingOpacity, 0) }
                else {
                    XCTAssertGreaterThan(surface.outgoingOpacity, 0.5)
                    XCTAssertLessThan(surface.outgoingOpacity, 1)
                    let pixel = try XCTUnwrap(image.colorAt(x: 120, y: 100)?.usingColorSpace(.deviceRGB))
                    XCTAssertGreaterThan(pixel.redComponent, 0.1, "Outgoing pixels remain visible")
                    XCTAssertGreaterThan(pixel.blueComponent, 0.05, "Incoming pixels are visible too")
                }
                try await clock.advance(by: 0.2)
                _ = try await fixture.capture(scale: 2)
                XCTAssertEqual(surface.outgoingOpacity, 0)
            }
        }
    }

    private struct EnvironmentReport: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let report: (Bool) -> Void
        var body: some View { Color.clear.onAppear { report(reduceMotion) } }
    }

    func testLiveReduceMotionIsRespectedAndFixtureOverridesAreRestored() async throws {
        XCTAssertNil(LayoutMotionInputs.testOverride, "A previous test leaked its motion override")
        let state = TaskPanelState(scope: "all")
        let report = NativeRenderingFixture(EnvironmentReport { environment in
            print("NATIVE_MOTION_ENV system=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) swiftUI=\(environment) override=\(LayoutMotionInputs.testOverride != nil) screens=\(NSScreen.screens.count) backing=\(NSScreen.main?.backingScaleFactor ?? 0)")
        }, size: CGSize(width: 40, height: 40))
        defer { report.close() }
        _ = try await report.capture(scale: 1)
        do {
            let reduced = LayoutMotionTestClock(reduceMotion: true)
            defer { reduced.restore() }
            do {
                let normal = LayoutMotionTestClock()
                defer { normal.restore() }
                XCTAssertFalse(LayoutMotionInputs.shouldReduceMotion(true))
            }
            XCTAssertTrue(LayoutMotionInputs.shouldReduceMotion(false))
        }
        XCTAssertNil(LayoutMotionInputs.testOverride)
        // With no test override, a true SwiftUI accessibility value must still
        // suppress motion, irrespective of the host's system preference.
        let fixture = NativeRenderingFixture(Swatch(state: state)
            .environment(\._accessibilityReduceMotion, true), size: CGSize(width: 240, height: 160))
        defer { fixture.close() }
        _ = try await fixture.capture(scale: 2)
        state.scope = "today"
        _ = try await fixture.capture(scale: 2)
        let surface = try XCTUnwrap(fixture.descendants(TaskContentTransitionView.self).first)
        XCTAssertEqual(surface.outgoingOpacity, 0)
        XCTAssertEqual(surface.opacity?.value, 1)
    }

    func testOutgoingPixelsCrossfadeWithIncomingAndRapidChangeRetargetsComposite() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let state = TaskPanelState(scope: "all")
        let fixture = NativeRenderingFixture(Swatch(state: state), size: CGSize(width: 240, height: 160))
        defer { fixture.close() }
        func pixel() async throws -> NSColor {
            try await fixture.capture(scale: 2).colorAt(x: 120, y: 100)!.usingColorSpace(.deviceRGB)!
        }
        let before = try await pixel()
        state.scope = "today"
        let start = try await pixel()
        let surface = try XCTUnwrap(fixture.descendants(TaskContentTransitionView.self).first)
        XCTAssertEqual(surface.outgoingOpacity, 1)
        XCTAssertEqual(start.redComponent, before.redComponent, accuracy: 0.02)
        XCTAssertEqual(start.blueComponent, before.blueComponent, accuracy: 0.02)
        try await clock.advance(by: 0.06)
        let middle = try await pixel()
        XCTAssertGreaterThan(middle.redComponent, 0.1, "Outgoing red pixels must still be drawn")
        XCTAssertGreaterThan(middle.blueComponent, 0.05, "Incoming blue pixels must be drawn too")
        XCTAssertLessThan(surface.outgoingOpacity, 1)
        state.groupID = "life"
        let retarget = try await pixel()
        XCTAssertEqual(retarget.redComponent, middle.redComponent, accuracy: 0.02)
        XCTAssertEqual(retarget.blueComponent, middle.blueComponent, accuracy: 0.02)
        try await clock.advance(by: 0.2)
        let after = try await pixel()
        XCTAssertGreaterThan(after.greenComponent, 0.4)
        XCTAssertEqual(surface.outgoingOpacity, 0)
        XCTAssertNil(surface.hitTest(.zero))
        XCTAssertFalse(surface.isAccessibilityElement())
        state.groupID = nil; state.groupID = "life" // Reverse before a render.
        _ = try await fixture.capture(scale: 2)
        try await clock.advance(by: 0.2)
        _ = try await fixture.capture(scale: 2)
        XCTAssertEqual(surface.outgoingOpacity, 0, "An out-and-back must not retain a pending bitmap forever")
        XCTAssertFalse(fixture.window.isVisible)
    }

    private struct TransparentInk: View {
        @ObservedObject var state: TaskPanelState
        var body: some View {
            TaskContentPresentation(state: state, dragging: false) {
                HStack(spacing: 40) {
                    (state.scope == "all" ? Color.red : Color.clear).frame(width: 60, height: 60)
                    (state.scope == "all" ? Color.clear : Color.blue).frame(width: 60, height: 60)
                }.frame(width: 240, height: 160)
            }
        }
    }

    func testTransparentViewportFadesIncomingInkInsteadOfShowingItImmediately() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let state = TaskPanelState(scope: "all")
        let fixture = NativeRenderingFixture(TransparentInk(state: state), size: CGSize(width: 240, height: 160))
        defer { fixture.close() }
        let before = try await fixture.capture(scale: 2)
        try before.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/dotist-transparent-before-20261104.png"))
        state.scope = "today"
        let start = try await fixture.capture(scale: 2)
        try start.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/dotist-transparent-start-20261104.png"))
        // AppKit's layer capture can include the window's white backing even
        // when the SwiftUI content is transparent. Compare ink to that backing.
        let incoming = try XCTUnwrap(start.colorAt(x: 320, y: 160))
        let background = try XCTUnwrap(start.colorAt(x: 440, y: 40))
        XCTAssertEqual(incoming.redComponent, background.redComponent, accuracy: 0.01)
        XCTAssertEqual(incoming.greenComponent, background.greenComponent, accuracy: 0.01)
        XCTAssertEqual(incoming.blueComponent, background.blueComponent, accuracy: 0.01,
                       "Incoming ink must be invisible at the start even with no opaque SwiftUI backdrop")
        try await clock.advance(by: 0.09)
        let middle = try await fixture.capture(scale: 2)
        try middle.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/dotist-transparent-middle-20261104.png"))
        for x in [120, 320] {
            let alpha = middle.colorAt(x: x, y: 160)!.alphaComponent
            XCTAssertGreaterThan(alpha, 0.2)
            XCTAssertLessThan(alpha, 0.8, "Both outgoing and incoming ink must have intermediate alpha")
        }
        try await clock.advance(by: 0.12)
        let after = try await fixture.capture(scale: 2)
        XCTAssertEqual(after.colorAt(x: 320, y: 160)!.alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(after.colorAt(x: 120, y: 160)!.alphaComponent, 0, accuracy: 0.01)
        XCTAssertFalse(fixture.window.isVisible)
    }

    private func region(_ image: NSBitmapImageRep, height: CGFloat) -> Data {
        // Main task viewport only: exclude the summary/toolbar and composer.
        var data = Data()
        let left = 32, top = 180
        let right = image.pixelsWide - 32
        let bottom = Int((height - 80) * 2)
        for y in top..<bottom {
            data.append(image.bitmapData! + y * image.bytesPerRow + left * 4, count: (right - left) * 4)
        }
        return data
    }

    func testAllSwitchRendersAnIntermediateMainListAppearance() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-content-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addTask(title: "Today sample", category: "work", dueDate: Date().dotistDay)
        _ = try store.addTask(title: "Tomorrow sample", category: "work",
            dueDate: Calendar.current.date(byAdding: .day, value: 1, to: Date())!.dotistDay)
        let model = try AppModel(store: store)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "dotist-content-" + UUID().uuidString))
        let state = TaskPanelState(groupID: "work", scope: "today", collapseStore: TaskGroupCollapseStore(defaults: defaults))
        let fixture = NativeRenderingFixture(MainWindow(model: model, state: state, showViews: {}, showSearch: {},
            showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false,
            toolbarConfig: ToolbarConfig(defaults: defaults)).environment(\.colorScheme, .light).background(Color.white),
            size: CGSize(width: 520, height: 620))
        defer { fixture.close() }
        let before = region(try await fixture.capture(scale: 2), height: 620)
        state.scope = "all"
        _ = try await fixture.capture(scale: 2)
        try await clock.advance(by: 0.06)
        let middle = region(try await fixture.capture(scale: 2), height: 620)
        try await clock.advance(by: 0.14)
        let after = region(try await fixture.capture(scale: 2), height: 620)
        XCTAssertNotEqual(before, after)
        XCTAssertNotEqual(middle, before)
        XCTAssertNotEqual(middle, after, "All must render a real intermediate list appearance, not replace content instantly")
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testEverySelectionDimensionUsesOneRenderedTransitionAtBothSizes() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-content-matrix-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.updateGroup("work", name: "Work")
        _ = try store.updateGroup("life", name: "Life")
        let today = Date().dotistDay
        let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let tomorrow = tomorrowDate.dotistDay
        let sameWeek = Calendar.current.isDate(Date(), equalTo: tomorrowDate, toGranularity: .weekOfYear)
        let a = try store.addTask(title: "Prepare proposal #alpha", category: "work", dueDate: today)
        let b = try store.addTask(title: "Review release #beta", category: "work", dueDate: tomorrow)
        let c = try store.addTask(title: "Undated research #alpha", category: "work")
        let d = try store.addTask(title: "Buy groceries #alpha", category: "life", dueDate: today)
        let e = try store.addTask(title: "Plan weekend #beta", category: "life", dueDate: tomorrow)
        let done = try store.addTask(title: "Completed note", category: "work", dueDate: today)
        _ = try store.patchTask(id: done.id, completed: true)
        var patch = DotistSettingsPatch(); patch.language = "en"
        _ = try store.updateSettings(patch)
        let model = try AppModel(store: store)
        var records = ["viewport\tselection\trowCount\tmiddleDiffersFromBefore\tmiddleDiffersFromAfter"]

        for size in [CGSize(width: 520, height: 620), CGSize(width: 364, height: 440)] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "dotist-content-matrix-" + UUID().uuidString))
            let state = TaskPanelState(groupID: "work", scope: "today", collapseStore: TaskGroupCollapseStore(defaults: defaults))
            var rows: [TaskListRowFrame] = []
            let fixture = NativeRenderingFixture(MainWindow(model: model, state: state, showViews: {}, showSearch: {},
                showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false, toolbarConfig: ToolbarConfig(defaults: defaults))
                .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
                .environment(\.colorScheme, .light).background(Color.white), size: size)
            defer { fixture.close() }
            _ = try await fixture.capture(scale: 2)
            let scroll = try XCTUnwrap(fixture.descendants(NSScrollView.self).first { $0.bounds.height > 100 })
            let window = fixture.window.frame
            let steps: [(String, () -> Void, Set<String>)] = [
                ("all", { state.scope = "all" }, [a.id, b.id, c.id, done.id]),
                ("tomorrow", { state.scope = "tomorrow" }, [b.id]),
                ("today", { state.scope = "today" }, [a.id]),
                ("week", { state.scope = "week" }, sameWeek ? [a.id, b.id] : [a.id]),
                ("nextweek", { state.scope = "nextweek" }, sameWeek ? [] : [b.id]),
                ("next7", { state.scope = "next7" }, [a.id, b.id]),
                ("range-start", { state.customStart = today; state.customEnd = today }, [a.id]),
                ("range-end", { state.customEnd = tomorrow }, [a.id, b.id]),
                ("group-life", { state.groupID = "life" }, [d.id, e.id]),
                ("tag-alpha", { state.activeTag = "alpha" }, [d.id]),
                ("empty", { state.activeTag = "missing" }, []),
                ("nonempty", { state.activeTag = nil }, [d.id, e.id]),
                ("all-groups", { state.groupID = nil }, [a.id, b.id, d.id, e.id]),
                ("clear-range", { state.scope = "all"; state.customStart = nil; state.customEnd = nil }, [a.id, b.id, c.id, d.id, e.id, done.id]),
                ("overdue-empty", { state.scope = "overdue" }, []),
                ("undated", { state.scope = "undated" }, [c.id]),
                ("done", { state.scope = "done" }, [done.id])
            ]
            for (name, select, expected) in steps {
                let beforeImage = try await fixture.capture(scale: 2)
                let before = region(beforeImage, height: size.height)
                select()
                _ = try await fixture.capture(scale: 2)
                try await clock.advance(by: 0.06)
                let middleImage = try await fixture.capture(scale: 2)
                let middle = region(middleImage, height: size.height)
                let middleFrames = Dictionary(rows.map { ($0.task.id, $0.frame) }, uniquingKeysWith: { _, latest in latest })
                let surface = try XCTUnwrap(fixture.descendants(TaskContentTransitionView.self).first)
                XCTAssertGreaterThan(surface.outgoingOpacity, 0.5, name + " outgoing midpoint")
                try await clock.advance(by: 0.06)
                let incomingImage = try await fixture.capture(scale: 2)
                let incoming = region(incomingImage, height: size.height)
                XCTAssertGreaterThan(surface.outgoingOpacity, 0)
                XCTAssertLessThan(surface.outgoingOpacity, 0.5, name + " incoming midpoint")
                try await clock.advance(by: 0.08)
                // The shared list clock is logical; the pre-existing summary
                // crossfade uses SwiftUI wall time. Save a fully settled endpoint.
                try await Task.sleep(for: .milliseconds(180))
                let afterImage = try await fixture.capture(scale: 2)
                let after = region(afterImage, height: size.height)
                let context = "\(Int(size.width))x\(Int(size.height)): \(name)"
                XCTAssertNotEqual(middle, before, context)
                XCTAssertNotEqual(middle, after, context + " must render a middle frame")
                XCTAssertNotEqual(incoming, before, context + " incoming midpoint")
                XCTAssertNotEqual(incoming, after, context + " incoming midpoint")
                XCTAssertEqual(surface.outgoingOpacity, 0, context + " must release outgoing pixels")
                XCTAssertEqual(Set(rows.map { $0.task.id }), expected, context + " must expose only the latest rows")
                XCTAssertEqual(rows.count, expected.count, context + " must not duplicate preference frames")
                XCTAssertTrue(rows.allSatisfy { abs($0.frame.height - 32) <= 0.5 }, context)
                XCTAssertEqual(Dictionary(rows.map { ($0.task.id, $0.frame) }, uniquingKeysWith: { _, latest in latest }), middleFrames,
                               context + " opacity must not move interactive geometry")
                XCTAssertTrue(fixture.descendants(NSScrollView.self).contains { $0 === scroll })
                XCTAssertEqual(scroll.contentView.bounds.origin, .zero, context + " must retain native scroll position")
                XCTAssertEqual(fixture.window.frame, window)
                XCTAssertFalse(fixture.window.isVisible)
                records.append("\(Int(size.width))x\(Int(size.height))\t\(name)\t\(rows.count)\t\(middle != before)\t\(middle != after)")
                if ["all", "group-life", "empty", "done"].contains(name) {
                    for (stage, image) in [("before", beforeImage), ("middle", middleImage), ("incoming", incomingImage), ("after", afterImage)] {
                        try image.representation(using: .png, properties: [:])?.write(to:
                            URL(fileURLWithPath: "/tmp/dotist-unified-\(name)-\(Int(size.height))-\(stage)-20261104.png"))
                    }
                }
            }
        }
        try records.joined(separator: "\n").write(toFile: "/tmp/dotist-unified-content-frames-20261104.tsv", atomically: true, encoding: .utf8)
    }

    func testReduceMotionAndDragDiscardOutgoingPixelsImmediately() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let state = TaskPanelState(scope: "all")
        let controls = MotionControls()
        let fixture = NativeRenderingFixture(ControlledSwatch(state: state, controls: controls), size: CGSize(width: 240, height: 160))
        defer { fixture.close() }
        _ = try await fixture.capture(scale: 2)
        let surface = try XCTUnwrap(fixture.descendants(TaskContentTransitionView.self).first)
        state.scope = "today"
        _ = try await fixture.capture(scale: 2)
        try await clock.advance(by: 0.04)
        XCTAssertGreaterThan(surface.outgoingOpacity, 0)
        controls.dragging = true
        _ = try await fixture.capture(scale: 2)
        XCTAssertEqual(surface.outgoingOpacity, 0, "A drag/Reduce Motion change must remove outgoing pixels immediately")
        XCTAssertEqual(surface.opacity?.value, 1)
        controls.dragging = false
        _ = try await fixture.capture(scale: 2)
        state.groupID = "life"
        _ = try await fixture.capture(scale: 2)
        XCTAssertEqual(surface.outgoingOpacity, 1)
        LayoutMotionInputs.testOverride?.reduceMotion = true
        try await clock.advance(by: 0.02)
        XCTAssertEqual(surface.outgoingOpacity, 0, "Enabling system Reduce Motion must cancel an active fade")
        XCTAssertEqual(surface.opacity?.value, 1)
    }

    func testFastModelDateAndPanelGroupSwitchesKeepLatestRowsScrollDraftAndSelection() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-content-fast-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        var lifeIDs: [String] = []
        for group in ["work", "life"] {
            for index in 0..<24 {
                let task = try store.addTask(title: "\(group) task \(index)", category: group, dueDate: Date().dotistDay)
                if group == "life" { lifeIDs.append(task.id) }
            }
        }
        let model = try AppModel(store: store)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "dotist-content-fast-" + UUID().uuidString))
        let state = TaskPanelState(groupID: "work", scope: "all", collapseStore: TaskGroupCollapseStore(defaults: defaults))
        let selection = TaskSelectionController()
        var rows: [TaskListRowFrame] = []
        let fixture = NativeRenderingFixture(MainWindow(model: model, state: state, showViews: {}, showSearch: {},
            showSettings: {}, showGroupPanel: { _ in }, collapse: {}, toolbarConfig: ToolbarConfig(defaults: defaults), selection: selection)
            .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
            .environment(\.colorScheme, .light).background(Color.white), size: CGSize(width: 364, height: 440))
        defer { fixture.close() }
        _ = try await fixture.capture(scale: 2)
        let scroll = try XCTUnwrap(fixture.descendants(NSScrollView.self).first { $0.bounds.height > 100 })
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 64))
        scroll.reflectScrolledClipView(scroll.contentView)
        let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first)
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("Keep this draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        let window = fixture.window.frame
        model.scope = "today" // Menu/keyboard routes are bridged into panel state.
        _ = try await fixture.capture(scale: 2)
        XCTAssertEqual(state.scope, "today")
        try await clock.advance(by: 0.04)
        for index in 0..<20 {
            state.groupID = index.isMultiple(of: 2) ? "work" : "life"
            state.scope = index.isMultiple(of: 2) ? "today" : "all"
        }
        state.groupID = "life"; state.scope = "all"
        _ = try await fixture.capture(scale: 2)
        XCTAssertEqual(Set(rows.map { $0.task.id }), Set(lifeIDs))
        XCTAssertEqual(rows.count, 24)
        selection.update { $0.click(lifeIDs[0], order: lifeIDs, shift: false, command: true) }
        try await clock.advance(by: 0.04)
        let middle = region(try await fixture.capture(scale: 2), height: 440)
        try await clock.advance(by: 0.13)
        let after = region(try await fixture.capture(scale: 2), height: 440)
        XCTAssertNotEqual(middle, after)
        XCTAssertEqual(Set(rows.map { $0.task.id }), Set(lifeIDs))
        XCTAssertTrue(rows.allSatisfy { abs($0.frame.height - 32) <= 0.5 })
        XCTAssertEqual(selection.value.ids, [lifeIDs[0]], "Presentation ticks must not reset row selection")
        XCTAssertEqual(scroll.contentView.bounds.minY, 64, accuracy: 0.5)
        XCTAssertTrue(fixture.descendants(NSScrollView.self).contains { $0 === scroll })
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertEqual(editor.string, "Keep this draft")
        XCTAssertEqual(fixture.window.frame, window)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testReducedMotionHasNoIntermediateDateGroupOrEmptyAppearance() async throws {
        let clock = LayoutMotionTestClock(reduceMotion: true)
        defer { clock.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-content-reduced-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addTask(title: "Work today", category: "work", dueDate: Date().dotistDay)
        _ = try store.addTask(title: "Life today", category: "life", dueDate: Date().dotistDay)
        let model = try AppModel(store: store)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "dotist-content-reduced-" + UUID().uuidString))
        let state = TaskPanelState(groupID: "work", scope: "today", collapseStore: TaskGroupCollapseStore(defaults: defaults))
        var rows: [TaskListRowFrame] = []
        let fixture = NativeRenderingFixture(MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {},
            showGroupPanel: { _ in }, collapse: {}, primary: false, toolbarConfig: ToolbarConfig(defaults: defaults))
            .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
            .environment(\.colorScheme, .light).background(Color.white), size: CGSize(width: 364, height: 440))
        defer { fixture.close() }
        _ = try await fixture.capture(scale: 2)
        for change in [{ state.scope = "all" }, { state.groupID = "life" }, { state.activeTag = "missing" }] {
            change()
            let immediate = region(try await fixture.capture(scale: 2), height: 440)
            try await clock.advance(by: 0.2)
            let later = region(try await fixture.capture(scale: 2), height: 440)
            XCTAssertEqual(immediate, later, "Reduce Motion must paint the final query immediately")
        }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(fixture.window.isVisible)
    }
}
