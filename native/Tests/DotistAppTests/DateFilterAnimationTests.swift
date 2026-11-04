import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class DateFilterAnimationTests: XCTestCase {
    func testSelectingDateKeepsFirstRowYBeforeTimedStripReturn() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-selection-y-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addTask(title: "Survives the date selection")
        let model = try AppModel(store: store)
        let state = TaskPanelState(scope: "all")
        let presentation = DateFilterPresentation(schedule: { _, _ in })
        var rows: [TaskListRowFrame] = []
        let fixture = NativeRenderingFixture(MainWindow(model: model, state: state, showViews: {}, showSearch: {},
            showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false, filterPresentation: presentation)
            .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
            .environment(\.colorScheme, .light).background(Color.white), size: CGSize(width: 520, height: 620))
        defer { fixture.close() }
        _ = try await fixture.capture(scale: 1)
        presentation.toggle()
        _ = try await fixture.capture(scale: 1)
        try await clock.advance(by: 0.2)
        _ = try await fixture.capture(scale: 1)
        let baseline = try XCTUnwrap(rows.first).frame.minY
        state.scope = "undated"
        var samples = ["frame\tfirstRowY"]
        for frame in 0..<14 {
            let image = try await fixture.capture(scale: 1)
            let y = try XCTUnwrap(rows.first).frame.minY
            samples.append("\(frame)\t\(y)")
            // All has a 6pt first-section inset; Undated has none. That
            // intentional content difference must not acquire another 22pt.
            XCTAssertLessThanOrEqual(abs(y - baseline), 6.5, "Selection must not insert a 22pt layout jump before the independent strip return")
            if frame == 7 { try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/dotist-date-selection-y.png")) }
            try await clock.advance(by: 1.0 / 60)
        }
        try samples.joined(separator: "\n").write(toFile: "/tmp/dotist-date-selection-y.tsv", atomically: true, encoding: .utf8)
        XCTAssertFalse(fixture.window.isVisible)
    }
    @MainActor private final class DismissalClock {
        struct Work {
            let deadline: TimeInterval
            let action: @MainActor @Sendable () -> Void
        }
        private var now: TimeInterval = 100
        private(set) var work: [Work] = []
        func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
            work.append(Work(deadline: now + delay, action: action))
        }
        func advance(by interval: TimeInterval) {
            now += interval
            let due = work.filter { $0.deadline <= now }
            work.removeAll { $0.deadline <= now }
            for item in due { item.action() }
        }
    }
    private final class VisibleFilterDefaults: UserDefaults {
        // Read-only fixture configuration; never write a preferences domain.
        override func data(forKey key: String) -> Data? {
            guard key == "dotist.toolbar.v1" else { return nil }
            return Data(#"{"order":["filter","collapse"],"visibility":{"filter":"always"}}"#.utf8)
        }
    }
    private final class Selection: ObservableObject {
        @Published var selected = false
    }
    private struct ButtonFixture: View {
        @ObservedObject var selection: Selection
        var body: some View {
            DraggableFilterButton(title: "Tomorrow", selected: selection.selected, language: "en", choose: {})
                .environment(\.colorScheme, .light).background(Color.white)
        }
    }
    private final class ClickReceiver: NSView {
        var downs: [NSEvent] = []
        var ups: [NSEvent] = []
        override func mouseDown(with event: NSEvent) { downs.append(event) }
        override func mouseUp(with event: NSEvent) { ups.append(event) }
    }
    private struct ReceiverHost: NSViewRepresentable {
        let view: ClickReceiver
        func makeNSView(context: Context) -> ClickReceiver { view }
        func updateNSView(_ nsView: ClickReceiver, context: Context) {}
    }
    private func pixels(_ image: NSBitmapImageRep) -> Data {
        Data(bytes: image.bitmapData!, count: image.bytesPerRow * image.pixelsHigh)
    }

    func testEdgeMaskNativePixelsReachZeroBeforeBothBorders() async throws {
        var measurements = ["scale\tx\talpha"]
        for scale: CGFloat in [1, 2] {
            let fixture = NativeRenderingFixture(Color.black.mask { DateFilterEdgeMask() },
                size: CGSize(width: 240, height: 34))
            defer { fixture.close() }
            let image = try await fixture.capture(scale: scale)
            func alpha(_ x: CGFloat) -> CGFloat {
                image.colorAt(x: Int(x * scale), y: Int(17 * scale))!.alphaComponent
            }
            for x: CGFloat in [0, 2, 3, 5, 10, 16, 23, 30, 120, 209, 216, 223, 229, 234, 236, 237, 239] {
                measurements.append("\(scale)\t\(x)\t\(alpha(x))")
            }
            for x: CGFloat in [0, 2, 3, 236, 237, 239] { XCTAssertEqual(alpha(x), 0, accuracy: 0.005) }
            XCTAssertGreaterThan(alpha(16), alpha(10))
            XCTAssertGreaterThan(alpha(10), alpha(5))
            XCTAssertGreaterThan(alpha(223), alpha(229))
            XCTAssertGreaterThan(alpha(229), alpha(234))
            XCTAssertEqual(alpha(30), 1, accuracy: 0.005)
            XCTAssertEqual(alpha(120), 1, accuracy: 0.005)
            try image.representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: "/tmp/dotist-filter-edge-alpha-\(Int(scale))x-20261104.png"))
            XCTAssertFalse(fixture.window.isVisible)
        }
        try measurements.joined(separator: "\n").write(toFile: "/tmp/dotist-filter-edge-alpha-20261104.tsv", atomically: true, encoding: .utf8)
    }

    func testFullPanelGroupHeaderStaysBelowStripThroughPushAndReturn() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-header-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.updateGroup("work", name: "Work")
        _ = try store.addTask(title: "Prepare the weekly review", category: "work")
        var patch = DotistSettingsPatch(); patch.language = "en"; patch.filters = ["today", "all", "tomorrow", "week", "next7", "overdue"]
        _ = try store.updateSettings(patch)
        let model = try AppModel(store: store)
        var records = ["viewport\tphase\theaderY\tstripBottom"]
        for size in [CGSize(width: 520, height: 620), CGSize(width: 364, height: 440)] {
            let presentation = DateFilterPresentation(schedule: { _, _ in })
            var groups: [TaskListGroupFrame] = []
            let fixture = NativeRenderingFixture(MainWindow(model: model, state: TaskPanelState(scope: "all"),
                showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false,
                filterPresentation: presentation).onPreferenceChange(TaskListGroupFrame.Key.self) { groups = $0 }
                .environment(\.colorScheme, .light).background(Color.white), size: size)
            defer { fixture.close() }
            var initialY: CGFloat = 0
            for (phase, open, elapsed) in [("before", false, 0.0), ("opening", true, 0.06), ("expanded", true, 0.14),
                                          ("returning", false, 0.06), ("after", false, 0.14)] {
                if open != presentation.isOpen { presentation.toggle() }
                _ = try await fixture.capture(scale: 2)
                try await clock.advance(by: elapsed)
                let image = try await fixture.capture(scale: 2)
                let headerY = try XCTUnwrap(groups.first { $0.id == "work" }).frame.minY
                let horizontal = try XCTUnwrap(fixture.descendants(NSScrollView.self).first { $0.bounds.height <= 34.5 })
                // The scroll view retains its full 34pt bounds while the
                // pushdown clips it to the currently reserved inline height.
                let bottom = fixture.host.convert(horizontal.visibleRect, from: horizontal).maxY
                XCTAssertGreaterThanOrEqual(headerY, bottom - 0.5, "The first group HEADER must clear the strip")
                if phase == "before" { initialY = headerY }
                if phase == "expanded" { XCTAssertEqual(headerY - initialY, 34, accuracy: 0.5) }
                if phase == "after" { XCTAssertEqual(headerY, initialY, accuracy: 0.5) }
                let frame = fixture.host.convert(horizontal.bounds, from: horizontal)
                XCTAssertEqual(frame.minX, 16, accuracy: 0.5)
                XCTAssertEqual(frame.maxX, size.width - 16, accuracy: 0.5)
                if phase == "expanded", let document = horizontal.documentView {
                    let maxX = max(0, document.bounds.width - horizontal.contentView.bounds.width)
                    XCTAssertGreaterThan(maxX, 0, "The fixture must exercise an overflowing filter strip")
                    for (name, x) in [("edge-middle", maxX / 2), ("edge-end", maxX)] {
                        horizontal.contentView.scroll(to: CGPoint(x: x, y: 0))
                        horizontal.reflectScrolledClipView(horizontal.contentView)
                        let scrolled = try await fixture.capture(scale: 2)
                        // In the clear safety bands, scrolling glyphs must add
                        // no dark ink, even when labels are cut by the viewport.
                        for edgeX in [frame.minX + 2, frame.maxX - 3] {
                            for y in stride(from: frame.midY - 6, through: frame.midY + 6, by: 1) {
                                let color = try XCTUnwrap(scrolled.colorAt(x: Int(edgeX * 2), y: Int(y * 2)))
                                XCTAssertGreaterThan(min(color.redComponent, color.greenComponent, color.blueComponent), 0.94)
                            }
                        }
                        try scrolled.representation(using: .png, properties: [:])?.write(to:
                            URL(fileURLWithPath: "/tmp/dotist-filter-header-\(Int(size.height))-\(name)-20261104.png"))
                    }
                    horizontal.contentView.scroll(to: .zero)
                    horizontal.reflectScrolledClipView(horizontal.contentView)
                }
                records.append("\(Int(size.width))x\(Int(size.height))\t\(phase)\t\(headerY)\t\(bottom)")
                try image.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: "/tmp/dotist-filter-header-\(Int(size.height))-\(phase)-20261104.png"))
            }
            XCTAssertFalse(fixture.window.isVisible)
        }
        try records.joined(separator: "\n").write(toFile: "/tmp/dotist-filter-header-20261104.tsv", atomically: true, encoding: .utf8)
    }

    private func element(_ node: Any, id: String? = nil, label: String? = nil) -> NSObject? {
        guard let object = node as? NSObject else { return nil }
        if let id, let ax = object as? any NSAccessibilityElementProtocol, ax.accessibilityIdentifier?() == id { return object }
        let labelSelector = #selector(NSAccessibilityProtocol.accessibilityLabel)
        if let label, object.responds(to: labelSelector),
           object.perform(labelSelector)?.takeUnretainedValue() as? String == label { return object }
        let children = #selector(NSAccessibilityProtocol.accessibilityChildren)
        guard object.responds(to: children) else { return nil }
        for child in object.perform(children)?.takeUnretainedValue() as? [Any] ?? [] {
            if let found = element(child, id: id, label: label) { return found }
        }
        return nil
    }
    private func press(_ object: NSObject) -> Bool {
        let selector = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
        guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Press.self)(object, selector)
    }
    private func describeAX(_ node: Any, depth: Int = 0) -> [String] {
        guard let object = node as? NSObject else { return [] }
        let ax = object as? any NSAccessibilityElementProtocol
        let entry = String(repeating: " ", count: depth) + "\(type(of: object)): \(ax?.accessibilityIdentifier?() ?? "-")"
        let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        guard object.responds(to: selector) else { return [entry] }
        let children = object.perform(selector)?.takeUnretainedValue() as? [Any] ?? []
        return [entry] + children.flatMap { describeAX($0, depth: depth + 1) }
    }

    func testExpansionPushesRealRowsBelowHeader() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-pushdown-red-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addTask(title: "Pushdown fixture")
        let model = try AppModel(store: store)
        let state = TaskPanelState(scope: "all")
        let presentation = DateFilterPresentation(schedule: { _, _ in })
        var rows: [TaskListRowFrame] = []
        let fixture = NativeRenderingFixture(
            MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {},
                showGroupPanel: { _ in }, collapse: {}, primary: false, filterPresentation: presentation)
                .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
                .environment(\.colorScheme, .light).background(Color.white), size: CGSize(width: 520, height: 620))
        defer { fixture.close() }
        _ = try await fixture.capture(scale: 2)
        let before = try XCTUnwrap(rows.first).frame
        let window = fixture.window.frame
        presentation.toggle()
        _ = try await fixture.capture(scale: 2)
        try await clock.advance(by: 0.2)
        try await Task.sleep(for: .milliseconds(200))
        _ = try await fixture.capture(scale: 2)
        let expanded = try XCTUnwrap(rows.first).frame
        print("PUSHDOWN regression before=\(before) expanded=\(expanded)")
        XCTAssertEqual(expanded.minY - before.minY, 34, accuracy: 0.5,
                       "Expansion must reserve a real row and move content, rather than cover it")
        XCTAssertEqual(expanded.height, before.height)
        XCTAssertEqual(fixture.window.frame, window)
    }

    func testPushdownGeometryScrollComposerAndInterruptedReturnAtBothViewportSizes() async throws {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = try XCTUnwrap(NSApp.accessibilityAttributeValue(enhanced) as? NSNumber)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-pushdown-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        for index in 0..<24 { _ = try store.addTask(title: "Task \(index) #focus", category: "work") }
        var patch = DotistSettingsPatch(); patch.language = "en"
        _ = try store.updateSettings(patch)
        let model = try AppModel(store: store)
        var records = ["viewport\tphase\trowY\tsummaryY\ttagY\tscrollOffsetY\tcomposerY\trowHeight"]

        for height: CGFloat in [620, 440] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "dotist-pushdown-" + UUID().uuidString))
            let state = TaskPanelState(groupID: "work", scope: "all", collapseStore: TaskGroupCollapseStore(defaults: defaults))
            state.activeTag = "focus"
            let presentation = DateFilterPresentation(schedule: { _, _ in })
            var rows: [TaskListRowFrame] = []
            let fixture = NativeRenderingFixture(
                MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {},
                    showGroupPanel: { _ in }, collapse: {}, primary: false, toolbarConfig: ToolbarConfig(defaults: defaults),
                    filterPresentation: presentation)
                    .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
                    .environment(\.colorScheme, .light).background(Color.white),
                size: CGSize(width: height == 440 ? 364 : 520, height: height))
            defer { fixture.close() }
            try await clock.advance(by: 0)
            _ = try await fixture.capture(scale: 2)
            let scroll = try XCTUnwrap(fixture.descendants(NSScrollView.self).first { $0.bounds.height > 100 })
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 64))
            scroll.reflectScrolledClipView(scroll.contentView)
            let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first)
            let window = fixture.window.frame
            var rendered: [String: Data] = [:]

            func snapshot(_ phase: String, save: Bool = true) async throws -> [CGFloat] {
                let image = try await fixture.capture(scale: 2)
                if ["collapsed", "opening-middle", "expanded", "return-middle", "returned"].contains(phase) {
                    rendered[phase] = pixels(image)
                }
                let first = try XCTUnwrap(rows.min { $0.frame.minY < $1.frame.minY }).frame
                func top(_ object: NSObject?) throws -> CGFloat {
                    let ax = try XCTUnwrap(try XCTUnwrap(object) as? any NSAccessibilityElementProtocol)
                    return fixture.host.convert(fixture.window.convertFromScreen(ax.accessibilityFrame()), from: nil).minY
                }
                let summary = try top(element(fixture.host, id: "active-filter-line"))
                let tag = try top(element(fixture.host, label: "#focus"))
                let composer = fixture.host.convert(field.bounds, from: field).minY
                let offset = scroll.contentView.bounds.minY
                records.append("\(height)\t\(phase)\t\(first.minY)\t\(summary)\t\(tag)\t\(offset)\t\(composer)\t\(first.height)")
                XCTAssertEqual(fixture.window.frame, window)
                XCTAssertEqual(rows.count, 24)
                XCTAssertTrue(rows.allSatisfy { abs($0.frame.height - 32) <= 0.5 })
                XCTAssertFalse(fixture.window.isVisible)
                if save {
                    try image.representation(using: .png, properties: [:])?.write(to:
                        URL(fileURLWithPath: "/tmp/dotist-filter-pushdown-\(Int(height))-\(phase)-20261103.png"))
                }
                return [first.minY, summary, tag, offset, composer, scroll.contentView.bounds.height]
            }
            let before = try await snapshot("collapsed")
            presentation.toggle()
            _ = try await snapshot("opening-start", save: false)
            try await clock.advance(by: 0.04)
            let middle = try await snapshot("opening-middle")
            try await clock.advance(by: 0.13)
            let expanded = try await snapshot("expanded")
            XCTAssertNotEqual(rendered["opening-middle"], rendered["collapsed"], "Opening must render a real middle frame")
            XCTAssertNotEqual(rendered["opening-middle"], rendered["expanded"])
            for index in 0...2 {
                XCTAssertGreaterThan(middle[index], before[index], "Content must move during expansion")
                XCTAssertLessThan(middle[index], expanded[index])
                XCTAssertEqual(expanded[index] - before[index], 34, accuracy: 0.5)
            }
            XCTAssertEqual(expanded[5], before[5] - 34, accuracy: 0.5, "Only the list viewport gives up space")
            for sample in [middle, expanded] {
                XCTAssertEqual(sample[3], before[3], accuracy: 0.5, "Opening must preserve scroll position")
                XCTAssertEqual(sample[4], before[4], accuracy: 0.5, "Composer remains at the bottom")
            }
            presentation.dismiss()
            _ = try await snapshot("return-start", save: false)
            try await clock.advance(by: 0.04)
            let returning = try await snapshot("return-middle")
            XCTAssertNotEqual(rendered["return-middle"], rendered["expanded"], "Return must also paint intermediate content")
            XCTAssertNotEqual(rendered["return-middle"], rendered["collapsed"])
            XCTAssertGreaterThan(returning[0], before[0])
            XCTAssertLessThan(returning[0], expanded[0])
            presentation.toggle()
            let reversed = try await snapshot("reopen-start", save: false)
            XCTAssertEqual(reversed[0], returning[0], accuracy: 0.5, "Reopening must continue from current geometry")
            try await clock.advance(by: 0.04)
            let reopening = try await snapshot("reopen-middle")
            XCTAssertGreaterThan(reopening[0], returning[0])
            XCTAssertLessThan(reopening[0], expanded[0])
            try await clock.advance(by: 0.13)
            let reopened = try await snapshot("reopened", save: false)
            XCTAssertEqual(reopened[0], expanded[0], accuracy: 0.5)
            presentation.dismiss()
            _ = try await snapshot("final-return-start", save: false)
            try await clock.advance(by: 0.17)
            let after = try await snapshot("returned")
            for index in before.indices { XCTAssertEqual(after[index], before[index], accuracy: 0.5) }
        }
        try records.joined(separator: "\n").write(toFile: "/tmp/dotist-filter-pushdown-geometry-20261103.tsv", atomically: true, encoding: .utf8)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    func testContentClickObserverPassesOriginalEventsAndExcludesStripAndOtherWindows() async throws {
        let presentation = DateFilterPresentation(schedule: { _, _ in })
        presentation.toggle()
        let receiver = ClickReceiver()
        let fixture = NativeRenderingFixture(VStack(spacing: 0) {
            Color.clear.frame(height: 34)
            ReceiverHost(view: receiver).frame(height: 100)
                .background(DateFilterContentClickObserver(enabled: true, dismiss: presentation.contentClicked))
        }, size: CGSize(width: 300, height: 134))
        defer { fixture.close() }
        _ = try await fixture.capture(scale: 2)
        let probe = try XCTUnwrap(fixture.descendants(DateFilterContentClickView.self).first)
        let inside = receiver.convert(CGPoint(x: receiver.bounds.midX, y: receiver.bounds.midY), to: nil)
        let outside = fixture.host.convert(CGPoint(x: 20, y: 10), to: nil)
        XCTAssertNil(probe.hitTest(.zero), "The observer must never become an input target")
        let root = try XCTUnwrap(fixture.window.contentView)
        XCTAssertTrue(root.hitTest(root.convert(inside, from: nil)) === receiver)

        // Direct in-process delivery to this fixture's real native receiver.
        // No app-wide sendEvent, global input synthesis, or window activation.
        let down = try mouse(.leftMouseDown, at: inside, window: fixture.window)
        let up = try mouse(.leftMouseUp, at: inside, window: fixture.window)
        // Unordered windows have number 0. Supply the fixture window at the
        // same boundary where the live local monitor resolves event.window.
        XCTAssertTrue(probe.observe(down, from: fixture.window) === down)
        receiver.mouseDown(with: down)
        XCTAssertTrue(presentation.isOpen, "Do not move a pressed control before its release")
        XCTAssertTrue(probe.observe(up, from: fixture.window) === up)
        XCTAssertTrue(presentation.isOpen, "Original mouse-up must reach the receiver before layout changes")
        receiver.mouseUp(with: up)
        _ = try await fixture.capture(scale: 2)
        XCTAssertFalse(presentation.isOpen)
        XCTAssertTrue(receiver.downs.first === down)
        XCTAssertTrue(receiver.ups.first === up)

        presentation.toggle()
        let stripDown = try mouse(.leftMouseDown, at: outside, window: fixture.window)
        XCTAssertTrue(probe.observe(stripDown, from: fixture.window) === stripDown)
        XCTAssertTrue(probe.observe(up, from: fixture.window) === up)
        XCTAssertTrue(presentation.isOpen, "A strip interaction released over content is not a content click")
        let dragged = try mouse(.leftMouseDragged, at: inside, window: fixture.window)
        XCTAssertTrue(probe.observe(dragged, from: fixture.window) === dragged)
        XCTAssertTrue(presentation.isOpen)

        let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        _ = probe.observe(try mouse(.leftMouseDown, at: inside, window: other), from: other)
        _ = probe.observe(try mouse(.leftMouseUp, at: inside, window: other), from: other)
        XCTAssertTrue(presentation.isOpen)
        probe.enabled = false
        _ = probe.observe(down, from: fixture.window); _ = probe.observe(up, from: fixture.window)
        XCTAssertTrue(presentation.isOpen)
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertFalse(other.isVisible)
    }

    func testContentCompletionAndComposerFocusSurviveDismissal() async throws {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = try XCTUnwrap(NSApp.accessibilityAttributeValue(enhanced) as? NSNumber)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-click-pass-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let task = try store.addTask(title: "Completion target")
        let model = try AppModel(store: store)
        let presentation = DateFilterPresentation(schedule: { _, _ in })
        presentation.toggle()
        let fixture = NativeRenderingFixture(MainWindow(model: model, state: TaskPanelState(scope: "all"),
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false,
            filterPresentation: presentation).background(Color.white), size: CGSize(width: 364, height: 440))
        defer { fixture.close() }
        try await clock.advance(by: 0)
        _ = try await fixture.capture(scale: 2)
        let window = fixture.window.frame
        let probes = fixture.descendants(DateFilterContentClickView.self)
        XCTAssertEqual(probes.count, 2, "List/blank space and composer each need a non-intercepting observer")
        func deliver(_ type: NSEvent.EventType, point: CGPoint) throws {
            let event = try mouse(type, at: point, window: fixture.window)
            for probe in probes { XCTAssertTrue(probe.observe(event, from: fixture.window) === event) }
        }
        let label = model.text("完成 {title}").replacingOccurrences(of: "{title}", with: task.title)
        let completion = try XCTUnwrap(element(fixture.host, label: label))
        let ax = try XCTUnwrap(completion as? any NSAccessibilityElementProtocol)
        let rect = fixture.window.convertFromScreen(ax.accessibilityFrame())
        let point = CGPoint(x: rect.midX, y: rect.midY)
        try deliver(.leftMouseDown, point: point)
        XCTAssertTrue(press(completion))
        try deliver(.leftMouseUp, point: point)
        XCTAssertTrue(presentation.isOpen, "The native release must finish before a content click can change layout")
        _ = try await fixture.capture(scale: 2)
        XCTAssertTrue(try XCTUnwrap(model.tasks.first { $0.id == task.id }).completed)
        XCTAssertFalse(presentation.isOpen)

        _ = try await fixture.capture(scale: 2)
        try await clock.advance(by: 0.17)
        presentation.toggle()
        _ = try await fixture.capture(scale: 2)
        try await clock.advance(by: 0.17)
        _ = try await fixture.capture(scale: 2)
        let listProbe = try XCTUnwrap(probes.max { $0.bounds.height < $1.bounds.height })
        let blank = listProbe.convert(CGPoint(x: listProbe.bounds.maxX - 12, y: listProbe.bounds.midY), to: nil)
        try deliver(.leftMouseDown, point: blank)
        try deliver(.leftMouseUp, point: blank)
        _ = try await fixture.capture(scale: 2)
        XCTAssertFalse(presentation.isOpen, "Blank list content must also dismiss")
        try await clock.advance(by: 0.17)
        presentation.toggle()
        _ = try await fixture.capture(scale: 2)
        try await clock.advance(by: 0.17)
        _ = try await fixture.capture(scale: 2)
        let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first)
        let fieldPoint = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        try deliver(.leftMouseDown, point: fieldPoint)
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("A retained draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        try deliver(.leftMouseUp, point: fieldPoint)
        XCTAssertTrue(presentation.isOpen)
        _ = try await fixture.capture(scale: 2)
        XCTAssertFalse(presentation.isOpen)
        try await clock.advance(by: 0.17)
        _ = try await fixture.capture(scale: 2)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertEqual(editor.string, "A retained draft")
        XCTAssertEqual(fixture.window.frame, window)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testReduceMotionPushdownChangesGeometryImmediately() async throws {
        let clock = LayoutMotionTestClock(reduceMotion: true)
        defer { clock.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-pushdown-reduce-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addTask(title: "Reduced motion row")
        let model = try AppModel(store: store)
        let presentation = DateFilterPresentation(schedule: { _, _ in })
        var rows: [TaskListRowFrame] = []
        let fixture = NativeRenderingFixture(MainWindow(model: model, state: TaskPanelState(scope: "all"),
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false,
            filterPresentation: presentation).onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 },
            size: CGSize(width: 364, height: 440))
        defer { fixture.close() }
        _ = try await fixture.capture(scale: 2)
        let initial = try XCTUnwrap(rows.first).frame
        presentation.toggle()
        _ = try await fixture.capture(scale: 2)
        XCTAssertEqual(try XCTUnwrap(rows.first).frame.minY - initial.minY, 34, accuracy: 0.5)
        presentation.dismiss()
        _ = try await fixture.capture(scale: 2)
        XCTAssertEqual(try XCTUnwrap(rows.first).frame, initial)
    }

    func testRealPanelRapidAXSelectionKeepsSlotsAndWindowStableAndClearsCustomRange() async throws {
        _ = NSApplication.shared
        // Initialize SwiftUI's lazy AX tree in this process only. No system
        // preference, assistive-access grant, window activation, or global input.
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhanced = try XCTUnwrap(NSApp.accessibilityAttributeValue(enhanced) as? NSNumber)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previousEnhanced, forAttribute: enhanced) }
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-filter-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!.dotistDay
        _ = try store.addTask(title: "Filter layout fixture", dueDate: tomorrow)
        let ids = ["today", "all", "tomorrow", "week", "next7"]
        var patch = DotistSettingsPatch(); patch.filters = ids; patch.language = "en"
        _ = try store.updateSettings(patch)
        let model = try AppModel(store: store)
        let state = TaskPanelState(scope: "all")
        state.customStart = tomorrow; state.customEnd = tomorrow
        let lifetime = DismissalClock()
        let presentation = DateFilterPresentation(schedule: lifetime.schedule)
        let defaults = try XCTUnwrap(VisibleFilterDefaults(suiteName: "dotist-filter-" + UUID().uuidString))
        var rows: [TaskListRowFrame] = []
        let content = MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {},
            showGroupPanel: { _ in }, collapse: {}, primary: false, toolbarConfig: ToolbarConfig(defaults: defaults),
            filterPresentation: presentation)
            .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
            .environment(\.colorScheme, .light).background(Color.white)
        let fixture = NativeRenderingFixture(content, size: CGSize(width: 520, height: 620))
        defer { fixture.close() }
        try await clock.advance(by: 0)
        let initial = try await fixture.capture(scale: 2)
        try initial.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/dotist-filter-animation-initial-20261103.png"))
        try describeAX(fixture.host).joined(separator: "\n").write(
            toFile: "/tmp/dotist-filter-animation-ax-20261103.txt", atomically: true, encoding: .utf8)
        XCTAssertFalse(presentation.isOpen)
        XCTAssertTrue(press(try XCTUnwrap(element(fixture.host, id: "date-filter-current"))))
        _ = try await fixture.capture(scale: 2)
        try await clock.advance(by: 0.17)
        _ = try await fixture.capture(scale: 2)
        XCTAssertTrue(presentation.isOpen)
        let hover = try XCTUnwrap(fixture.descendants(DateFilterHoverView.self).first)
        hover.pointerInWindow = { _ in hover.convert(CGPoint(x: hover.bounds.midX, y: hover.bounds.midY), to: nil) }
        hover.samplePointer()
        XCTAssertTrue(presentation.isHovered)
        let windowFrame = fixture.window.frame
        func frames() throws -> [CGRect] {
            try ids.map { id in
                let object = try XCTUnwrap(element(fixture.host, id: "date-filter:" + id), "Missing filter: " + id)
                return try XCTUnwrap(object as? any NSAccessibilityElementProtocol).accessibilityFrame()
            }
        }
        let baseline = try frames()
        XCTAssertTrue(baseline.allSatisfy { $0.width > 0 && $0.height > 0 })
        for id in ["tomorrow", "all", "today", "tomorrow", "next7"] {
            XCTAssertTrue(press(try XCTUnwrap(element(fixture.host, id: "date-filter:" + id))))
            _ = try await fixture.capture(scale: 2)
            XCTAssertEqual(state.scope, id)
            XCTAssertNil(state.customStart)
            XCTAssertNil(state.customEnd)
            XCTAssertTrue(presentation.isOpen)
            lifetime.advance(by: 1.5)
            XCTAssertTrue(presentation.isOpen, "Hovered selection must remain open despite the old opening callback")
            XCTAssertEqual(try frames(), baseline, "The selected text must not move any AX hit rectangle")
            XCTAssertEqual(fixture.window.frame, windowFrame)
        }
        try await clock.advance(by: 0.2)
        // Opacity/color/summary feedback uses SwiftUI's wall clock; let those
        // settle as well as the explicitly sampled selection clock.
        try await Task.sleep(for: .milliseconds(200))
        let image = try await fixture.capture(scale: 2)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { abs($0.frame.height - 32) <= 0.5 })
        XCTAssertFalse(fixture.window.isVisible)
        try image.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/dotist-filter-animation-panel-20261103.png"))
        lifetime.advance(by: 30)
        XCTAssertTrue(presentation.isOpen)
        hover.pointerInWindow = { _ in CGPoint(x: -999, y: -999) }; hover.samplePointer()
        lifetime.advance(by: 1.99)
        XCTAssertTrue(presentation.isOpen)
        lifetime.advance(by: 0.02)
        XCTAssertFalse(presentation.isOpen, "Only pointer exit starts the hovered strip's deadline")
    }

    // A selection must start at the currently drawn label, including in an
    // unordered window. Advancing logical time then exposes actual ink changes.
    func testSelectionDoesNotJumpToNewFontBeforeAnimationClockAdvances() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let selection = Selection()
        let fixture = NativeRenderingFixture(ButtonFixture(selection: selection), size: CGSize(width: 120, height: 34))
        defer { fixture.close() }
        let before = pixels(try await fixture.capture(scale: 2))
        selection.selected = true
        let initial = pixels(try await fixture.capture(scale: 2))
        XCTAssertTrue(initial == before, "Selection replaced the font immediately instead of starting from the presented label")
        try await clock.advance(by: 0.08)
        let middle = pixels(try await fixture.capture(scale: 2))
        try await clock.advance(by: 0.12)
        let after = pixels(try await fixture.capture(scale: 2))
        XCTAssertNotEqual(middle, before)
        XCTAssertNotEqual(middle, after, "The selection must paint an intermediate appearance")
        XCTAssertFalse(fixture.window.isVisible, "The harness must never order a desktop window")
    }

    func testHoverHoldsIndefinitelyAndEachExitGetsTwoFullSeconds() throws {
        let clock = DismissalClock()
        let presentation = DateFilterPresentation(schedule: clock.schedule)
        presentation.toggle()
        let old = try XCTUnwrap(clock.work.first).action
        presentation.hoverChanged(true)
        for _ in 0..<10 {
            presentation.selected()
            clock.advance(by: 20)
            XCTAssertTrue(presentation.isOpen)
        }
        XCTAssertTrue(clock.work.isEmpty, "Hovered selection must never arm a close")
        presentation.hoverChanged(false)
        clock.advance(by: 1.9)
        presentation.hoverChanged(true)
        old()
        clock.advance(by: 50)
        XCTAssertTrue(presentation.isOpen)
        presentation.hoverChanged(false)
        clock.advance(by: 1.99)
        XCTAssertTrue(presentation.isOpen)
        clock.advance(by: 0.02)
        XCTAssertFalse(presentation.isOpen)
        presentation.toggle()
        presentation.hoverChanged(true)
        presentation.toggle()
        presentation.toggle()
        presentation.hoverChanged(true)
        clock.advance(by: 100)
        old()
        XCTAssertTrue(presentation.isOpen)
        presentation.dismiss()
        clock.advance(by: 100)
        XCTAssertFalse(presentation.isOpen)
    }

    func testDateControlsSuspendPendingExitAndResumeWithFullLifetime() {
        let clock = DismissalClock()
        let presentation = DateFilterPresentation(schedule: clock.schedule)
        presentation.toggle()
        presentation.hoverChanged(true)
        presentation.hoverChanged(false)
        clock.advance(by: 1)
        presentation.dateControlsChanged(true)
        presentation.selected()
        clock.advance(by: 120)
        XCTAssertTrue(presentation.isOpen)
        presentation.dateControlsChanged(false)
        clock.advance(by: 1.99)
        XCTAssertTrue(presentation.isOpen)
        presentation.hoverChanged(true)
        clock.advance(by: 50)
        XCTAssertTrue(presentation.isOpen)
        presentation.hoverChanged(false)
        clock.advance(by: 2.01)
        XCTAssertFalse(presentation.isOpen)
    }

    func testMountedPanelNativeTrackingRecognizesStationaryPointerAndReentry() async throws {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let saved = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(saved, forAttribute: enhanced) }
        let motion = LayoutMotionTestClock(reduceMotion: true)
        defer { motion.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-hover-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addTask(title: "hover fixture")
        var patch = DotistSettingsPatch(); patch.filters = ["all", "today", "tomorrow"]
        _ = try store.updateSettings(patch)
        let model = try AppModel(store: store)
        let state = TaskPanelState(scope: "all")
        let clock = DismissalClock()
        let presentation = DateFilterPresentation(schedule: clock.schedule)
        let fixture = NativeRenderingFixture(MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {},
            showGroupPanel: { _ in }, collapse: {}, primary: false, filterPresentation: presentation), size: CGSize(width: 520, height: 440))
        defer { fixture.close() }
        _ = try await fixture.capture(scale: 1)
        let observer = try XCTUnwrap(fixture.descendants(DateFilterHoverView.self).first,
            "The production filter strip must mount native hover tracking")
        var inside = true
        observer.pointerInWindow = { _ in inside ? observer.convert(CGPoint(x: observer.bounds.midX, y: observer.bounds.midY), to: nil) : CGPoint(x: -999, y: -999) }
        presentation.toggle()
        _ = try await fixture.capture(scale: 1)
        try await motion.advance(by: 0)
        XCTAssertTrue(presentation.isHovered, "Opening under the pointer must detect hover without a mouse-entered event")
        XCTAssertFalse(observer.trackingAreas.isEmpty)
        XCTAssertTrue(observer.trackingAreas.allSatisfy { $0.options.contains(.inVisibleRect) && $0.options.contains(.activeAlways) })
        let pending = clock.work.count
        XCTAssertTrue(press(try XCTUnwrap(element(fixture.host, id: "date-filter:tomorrow"))))
        _ = try await fixture.capture(scale: 1)
        XCTAssertEqual(state.scope, "tomorrow")
        XCTAssertEqual(clock.work.count, pending, "Actual strip selection while hovered must not schedule dismissal")
        clock.advance(by: 30)
        XCTAssertTrue(presentation.isOpen)
        inside = false; observer.samplePointer()
        clock.advance(by: 1.9)
        inside = true; observer.samplePointer()
        clock.advance(by: 10)
        XCTAssertTrue(presentation.isOpen)
        presentation.dismiss()
        presentation.toggle() // Reopen without a native exit or a disabled layout.
        observer.samplePointer()
        clock.advance(by: 10)
        XCTAssertTrue(presentation.isOpen)
        inside = false; observer.samplePointer()
        clock.advance(by: 1.99)
        XCTAssertTrue(presentation.isOpen)
        clock.advance(by: 0.02)
        XCTAssertFalse(presentation.isOpen)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testIdleOpeningClosesAtTwoSecondsWithoutHoverInput() {
        let clock = DismissalClock()
        let presentation = DateFilterPresentation(schedule: clock.schedule)
        presentation.toggle()
        clock.advance(by: 1.99)
        XCTAssertTrue(presentation.isOpen)
        clock.advance(by: 0.02)
        XCTAssertFalse(presentation.isOpen, "Idle opening must close even with a stationary pointer")
        presentation.selected()
        XCTAssertFalse(presentation.isOpen, "A late selection cannot reopen a closed strip")
    }

    func testSelectionDoesNotMoveOpeningFallbackOrPointerExitDeadline() {
        let clock = DismissalClock()
        let presentation = DateFilterPresentation(schedule: clock.schedule)
        presentation.toggle()
        clock.advance(by: 1.5)
        presentation.selected()
        clock.advance(by: 0.51)
        XCTAssertFalse(presentation.isOpen, "A nonhover selection cannot extend the opening fallback")
        presentation.toggle()
        presentation.hoverChanged(true)
        clock.advance(by: 30)
        presentation.selected()
        XCTAssertTrue(presentation.isOpen)
        presentation.hoverChanged(false)
        clock.advance(by: 1.5)
        presentation.selected()
        clock.advance(by: 0.49)
        XCTAssertTrue(presentation.isOpen)
        clock.advance(by: 0.02)
        XCTAssertFalse(presentation.isOpen, "The two seconds count from exit, even if selection occurs later")
    }

    func testDismissToggleAndReopenInvalidateEarlierCallbacks() throws {
        let clock = DismissalClock()
        let presentation = DateFilterPresentation(schedule: clock.schedule)
        presentation.toggle()
        let stale = try XCTUnwrap(clock.work.first).action
        presentation.dismiss()
        presentation.toggle()
        stale() // Deliberately execute a callback from the previous opening.
        XCTAssertTrue(presentation.isOpen)
        presentation.toggle()
        XCTAssertFalse(presentation.isOpen)
        clock.advance(by: 3)
        XCTAssertFalse(presentation.isOpen)
        presentation.toggle()
        stale()
        clock.advance(by: 1.99)
        XCTAssertTrue(presentation.isOpen)
        clock.advance(by: 0.02)
        XCTAssertFalse(presentation.isOpen)
    }

    func testDeferredContentClickCannotDismissNewerOpening() async throws {
        let presentation = DateFilterPresentation(schedule: { _, _ in })
        presentation.toggle()
        presentation.contentClicked()
        presentation.dismiss()
        presentation.toggle()
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(presentation.isOpen, "A deferred click belongs to the opening that received it")
        presentation.contentClicked()
        XCTAssertTrue(presentation.isOpen)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(presentation.isOpen)
    }

    func testRapidSelectionReversesFromCurrentFractionWithoutOvershoot() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let motion = DateFilterSelectionMotion(selected: false)
        defer { motion.stop() }
        motion.setSelected(true, reduceMotion: false)
        XCTAssertEqual(motion.fraction, 0)
        try await clock.advance(by: 0.04)
        let ascending = motion.fraction
        XCTAssertGreaterThan(ascending, 0)
        XCTAssertLessThan(ascending, 1)
        motion.setSelected(false, reduceMotion: false)
        XCTAssertEqual(motion.fraction, ascending, "Reversal must retain the presented fraction")
        try await clock.advance(by: 0.04)
        let descending = motion.fraction
        XCTAssertGreaterThan(descending, 0)
        XCTAssertLessThan(descending, ascending)
        motion.setSelected(true, reduceMotion: false)
        motion.setSelected(false, reduceMotion: false)
        motion.setSelected(true, reduceMotion: false)
        XCTAssertEqual(motion.fraction, descending)
        try await clock.advance(by: 0.04)
        XCTAssertGreaterThan(motion.fraction, descending)
        XCTAssertLessThan(motion.fraction, 1)
        try await clock.advance(by: 0.13)
        XCTAssertEqual(motion.fraction, 1)
        motion.setSelected(false, reduceMotion: false)
        try await clock.advance(by: 0.17)
        XCTAssertEqual(motion.fraction, 0)
    }

    func testReduceMotionAndStopCancelInFlightSelection() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let motion = DateFilterSelectionMotion(selected: false)
        motion.setSelected(true, reduceMotion: false)
        try await clock.advance(by: 0.04)
        motion.setSelected(false, reduceMotion: true)
        XCTAssertEqual(motion.fraction, 0)
        try await clock.advance(by: 0.2)
        XCTAssertEqual(motion.fraction, 0)
        motion.setSelected(true, reduceMotion: false)
        LayoutMotionInputs.testOverride?.reduceMotion = true
        XCTAssertNil(DateFilterSelectionMotion.animation(reduceMotion: false))
        try await clock.advance(by: 0.02)
        XCTAssertEqual(motion.fraction, 1, "Enabling system Reduce Motion during a transition must finish immediately")
        LayoutMotionInputs.testOverride?.reduceMotion = false
        motion.setSelected(false, reduceMotion: false)
        try await clock.advance(by: 0.04)
        motion.stop()
        let stopped = motion.fraction
        try await clock.advance(by: 0.2)
        XCTAssertEqual(motion.fraction, stopped)
    }

    func testIntermediateInkStaysCenteredAndInsideReservedSlots() throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
        for (language, title) in [("en", "Tomorrow"), ("zh-CN", "今天"), ("zh-Hant", "未來 7 天"), ("de", "Diese Woche")] {
            let width = TaskDateFilterMetrics.slotWidth(title: title, language: language)
            for fraction: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                for scale: CGFloat in [1, 2] {
                    let label = DateFilterInkLabel(title: title, language: language, fraction: fraction,
                        regularColor: .black, selectedColor: .black, regularOpacity: 1, feedbackAnimation: nil)
                        .frame(width: width, height: 34)
                    let renderer = ImageRenderer(content: label)
                    renderer.scale = scale
                    let image = try XCTUnwrap(renderer.cgImage)
                    let ink = try XCTUnwrap(OpticalMetrics.inkBounds(of: image))
                    let context = "\(title), fraction=\(fraction), scale=\(scale)"
                    // At 1x an antialiased boundary can occupy one additional
                    // destination row; the existing OpticalText endpoints do too.
                    XCTAssertEqual(ink.midY / scale, 17, accuracy: 1 / scale, context)
                    XCTAssertGreaterThanOrEqual(ink.minX, 0, context)
                    XCTAssertLessThanOrEqual(ink.maxX / scale, width, context)
                    XCTAssertEqual(CGFloat(image.width) / scale, width, accuracy: 1 / scale, context)
                }
            }
        }
    }
}
