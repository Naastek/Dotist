import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class MenuBarTests: XCTestCase {
    func testTodayCountMatchesAgendaAcrossDaysAndGroups() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("menubar-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let overdue = try store.addTask(title: "overdue", dueDate: "2026-11-01")
        _ = try store.addTask(title: "child", parentId: overdue.id, dueDate: "2026-11-02")
        _ = try store.addTask(title: "future", dueDate: "2026-11-03")
        _ = try store.addTask(title: "undated")
        let done = try store.addTask(title: "done", dueDate: "2026-11-02")
        _ = try store.patchTask(id: done.id, completed: true)
        _ = try store.addTask(title: "work", category: "work", dueDate: "2026-11-02")
        let tasks = try store.snapshot().tasks
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
        XCTAssertEqual(MenuBarImage.todayCount(tasks: tasks, groupID: nil, now: date, calendar: calendar), 3)
        XCTAssertEqual(MenuBarImage.todayCount(tasks: tasks, groupID: DotistGroup.inboxID, now: date, calendar: calendar), 2)
        XCTAssertEqual(MenuBarImage.todayCount(tasks: tasks, groupID: nil, now: calendar.date(byAdding: .day, value: 1, to: date)!, calendar: calendar), 4)
    }

    private var artifacts: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOTIST_MENUBAR_ARTIFACTS"] ?? FileManager.default.temporaryDirectory.path)
    }

    private func render(_ count: Int?, scale: Int) throws -> NSBitmapImageRep {
        let image = MenuBarImage.make(count: count, accessibilityDescription: "test")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * scale, pixelsHigh: 18 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set(); NSRect(origin: .zero, size: image.size).fill(using: .copy)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: artifacts.appendingPathComponent("template-\(count.map(String.init) ?? "icon")-\(scale)x.png"))
        return rep
    }

    private func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    func testApprovedMarkMatchesSVGAndHasTransparentLowerRightHole() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for scale in [1, 2] {
            let rep = try render(nil, scale: scale)
            let source = root.appendingPathComponent("design-system/logo/menubar-template-16\(scale == 2 ? "@2x" : "").png")
            let svg = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: source)))
            XCTAssertEqual(rep.pixelsWide, 16 * scale)
            XCTAssertEqual(alpha(rep, Int(9.25 * Double(scale)), Int(11.25 * Double(scale))), 0, accuracy: 0.02, "Hole must be transparent at visual lower right")
            XCTAssertGreaterThan(alpha(rep, 6 * scale, 6 * scale), 0.95, "Upper left must remain solid")
            var error: CGFloat = 0
            // The one-point vertical inset keeps the approved 16 pt shape unchanged.
            for y in 0..<(16 * scale) {
                for x in 0..<(16 * scale) {
                    error += abs(alpha(rep, x, y + scale) - alpha(svg, x, y))
                }
            }
            XCTAssertLessThan(error / CGFloat(256 * scale * scale), 0.025, "Native path must match the approved SVG raster, including orientation")
            XCTAssertEqual(alpha(rep, 0, 0), 0)
        }
    }

    func testTemplateImagesRenderAtBothScales() throws {
        for scale in [1, 2] {
            let empty = try render(nil, scale: scale)
            var masks = Set<[Int]>()
            for count in [0, 1, 9, 10, 99, 100] {
                let image = MenuBarImage.make(count: count, accessibilityDescription: "\(count)")
                XCTAssertTrue(image.isTemplate)
                XCTAssertEqual(image.accessibilityDescription, "\(count)")
                let rep = try render(count, scale: scale)
                XCTAssertGreaterThan(rep.pixelsWide, 19 * scale)
                var digitPixels: [Int] = []
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<(16 * scale) {
                        XCTAssertEqual(alpha(rep, x, y), alpha(empty, x, y), accuracy: 0.01, "Count must not alter the mark or its hole")
                    }
                    for x in (16 * scale)..<(19 * scale) { XCTAssertEqual(alpha(rep, x, y), 0) }
                    for x in (19 * scale)..<rep.pixelsWide where alpha(rep, x, y) > 0.05 {
                        digitPixels.append(y * rep.pixelsWide + x)
                        XCTAssertLessThan(x, rep.pixelsWide - scale, "Count must have trailing clearance")
                        XCTAssertGreaterThan(y, 0, "No vertical clipping")
                        XCTAssertLessThan(y, rep.pixelsHigh - 1, "No vertical clipping")
                    }
                }
                XCTAssertGreaterThan(digitPixels.count, 8 * scale * scale, "Missing readable digits for \(count) at \(scale)x")
                masks.insert(digitPixels)
                print("Template count=\(count) scale=\(scale) size=\(image.size)")
            }
            XCTAssertEqual(masks.count, 6, "Each displayed value must have distinct digit ink")
        }
    }

    func testTemplateButtonsInLightAndDarkAppearances() throws {
        _ = NSApplication.shared
        for (theme, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for scale in [1, 2] {
                for count in [nil, 0, 1, 9, 10, 99, 100] as [Int?] {
                    let image = MenuBarImage.make(count: count, accessibilityDescription: "test")
                    let button = NSButton(image: image, target: nil, action: nil)
                    button.isBordered = false
                    button.imagePosition = .imageOnly
                    button.appearance = NSAppearance(named: name)
                    button.frame = NSRect(x: 0, y: 0, width: image.size.width + 8, height: 22)
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(button.frame.width) * scale, pixelsHigh: 22 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = button.frame.size
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    button.effectiveAppearance.performAsCurrentDrawingAppearance {
                        (theme == "dark" ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white).set()
                        button.bounds.fill()
                        button.displayIgnoringOpacity(button.bounds, in: NSGraphicsContext.current!)
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    var contrastPixels = 0
                    for y in 0..<rep.pixelsHigh {
                        for x in 0..<rep.pixelsWide {
                            let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            if theme == "dark" ? color.redComponent > 0.5 : color.redComponent < 0.5 { contrastPixels += 1 }
                        }
                    }
                    XCTAssertGreaterThan(contrastPixels, 40 * scale * scale, "Template must contrast with \(theme) background")
                    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: artifacts.appendingPathComponent("button-\(theme)-\(count.map(String.init) ?? "icon")-\(scale)x.png"))
                }
            }
        }
    }

    func testStatusItemCountUpdatesAndDayChange() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("Status item integration requires a WindowServer display") }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("menubar-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        var patch = DotistSettingsPatch()
        patch.trayMode = "count"
        patch.showMenubar = true
        _ = try store.updateSettings(patch)
        let model = try AppModel(store: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
        let controller = MenuBarController(model: model, now: { now }, perform: { _ in })
        defer { if let item = controller.item { NSStatusBar.system.removeStatusItem(item) } }
        func expected(_ count: Int) -> String {
            model.text("今天还有 {n} 件未完成任务").replacingOccurrences(of: "{n}", with: "\(count)")
        }
        func waitForCount(_ count: Int) async {
            let predicate = NSPredicate { _, _ in controller.item?.button?.toolTip == expected(count) }
            let update = expectation(for: predicate, evaluatedWith: nil)
            await fulfillment(of: [update], timeout: 3)
        }
        await waitForCount(0)
        let item = try XCTUnwrap(controller.item)
        let button = try XCTUnwrap(item.button)
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.image?.size.width, MenuBarImage.make(count: 0, accessibilityDescription: "").size.width)
        XCTAssertEqual(button.accessibilityLabel(), expected(0))

        button.layoutSubtreeIfNeeded()
        XCTAssertTrue(item.isVisible)
        XCTAssertEqual(item.length, NSStatusItem.variableLength)
        XCTAssertGreaterThan(button.frame.width, 0)
        print("Status item width=\(button.frame.width) visible=\(item.isVisible) window=\(String(describing: button.window?.frame))")

        _ = try store.addTask(title: "today", dueDate: "2026-11-02")
        await waitForCount(1)
        XCTAssertEqual(button.title, "")
        _ = try store.addTask(title: "tomorrow", dueDate: "2026-11-03")
        let snapshotArrived = expectation(for: NSPredicate { _, _ in model.tasks.count == 2 }, evaluatedWith: nil)
        await fulfillment(of: [snapshotArrived], timeout: 3)
        XCTAssertEqual(button.toolTip, expected(1))
        now = calendar.date(byAdding: .day, value: 1, to: now)!
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        await waitForCount(2)
        XCTAssertEqual(button.accessibilityLabel(), expected(2))
        XCTAssertEqual(button.title, "")
    }
    func testStatusItemLifecycleModesGroupsAndFullAccessibilityCount() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("No WindowServer display; cannot verify native status item") }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("menubar-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        var patch = DotistSettingsPatch()
        patch.showMenubar = true; patch.showDock = false; patch.trayMode = "count"
        patch.trayFilter = "all"; patch.trayGroup = "all"
        patch.trayLeftClick = "menu"; patch.trayRightClick = "quick"; patch.trayRotateSecs = 2
        _ = try store.updateSettings(patch)
        let today = Date().dotistDay
        for index in 0..<100 { _ = try store.addTask(title: "Task \(index)", dueDate: today) }
        let model = try AppModel(store: store)
        let controller = MenuBarController(model: model, perform: { _ in })
        defer { if let item = controller.item { NSStatusBar.system.removeStatusItem(item) } }
        func wait(_ description: String, _ condition: @escaping () -> Bool) async {
            let ready = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil, handler: nil)
            ready.expectationDescription = description
            await fulfillment(of: [ready], timeout: 4)
        }
        await wait("Initial count", { controller.item?.button?.toolTip?.contains("100") == true })
        XCTAssertTrue(try XCTUnwrap(controller.item).isVisible)
        XCTAssertTrue(try XCTUnwrap(controller.item?.button?.accessibilityLabel()).contains("100"))
        for mode in ["icon", "next", "next_date", "rotate", "count"] {
            patch = DotistSettingsPatch(); patch.trayMode = mode
            _ = try store.updateSettings(patch)
            await wait("Mode \(mode)", { model.settings.trayMode == mode && (mode == "icon" || mode == "count" ? controller.item?.button?.title == "" : controller.item?.button?.title.isEmpty == false) })
            XCTAssertNotNil(controller.item?.button?.image?.tiffRepresentation)
            XCTAssertTrue(controller.item?.button?.image?.isTemplate == true)
            XCTAssertLessThan(try XCTUnwrap(controller.item?.button).frame.width, 600, "Text mode must remain bounded")
            if mode == "rotate" {
                let initial = controller.item?.button?.title
                await wait("Rotation advances", { controller.item?.button?.title != initial })
            }
        }
        let work = try store.addGroup(name: "Work")
        patch = DotistSettingsPatch(); patch.trayGroup = work.id
        _ = try store.updateSettings(patch)
        await wait("Empty group count", { controller.item?.button?.toolTip?.contains("0") == true && controller.item?.button?.toolTip?.contains("100") == false })
        for enabled in [false, true, false, true] {
            patch = DotistSettingsPatch(); patch.showMenubar = enabled
            _ = try store.updateSettings(patch)
            await wait("showMenubar=\(enabled)", { enabled ? controller.item?.isVisible == true : controller.item == nil })
        }
        XCTAssertFalse(try store.settings().showDock, "Do not change user settings to recover the menu bar")
    }

    func testSettingsMenubarToggleInUnorderedNativeHost() async throws {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("menubar-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        var patch = DotistSettingsPatch(); patch.showMenubar = true; patch.showDock = false; patch.language = "zh-CN"
        _ = try store.updateSettings(patch)
        let model = try AppModel(store: store)
        let host = NSHostingView(rootView: SettingsWindow(model: model, updater: NativeUpdater(model: model), beginShortcutCapture: {}, endShortcutCapture: { _, _ in }, resetWindowSize: {}, initialModule: .general).frame(width: 800, height: 540))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 540)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        // SwiftUI AX nodes expose selectors without conforming to the full
        // NSAccessibilityProtocol; traverse the public element protocol instead.
        func elements(_ node: Any, depth: Int = 0) -> [(NSObject, any NSAccessibilityElementProtocol)] {
            guard depth < 30, let object = node as? NSObject else { return [] }
            var result: [(NSObject, any NSAccessibilityElementProtocol)] = []
            if let element = object as? any NSAccessibilityElementProtocol { result.append((object, element)) }
            let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [Any] {
                result += children.flatMap { elements($0, depth: depth + 1) }
            }
            return result
        }
        for enabled in [false, true] {
            try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
            let toggle = try XCTUnwrap(elements(host).first { object, _ in
                let selector = #selector(NSAccessibilityProtocol.accessibilityLabel)
                return object.responds(to: selector) && object.perform(selector)?.takeUnretainedValue() as? String == model.text("显示在菜单栏")
            })
            let frame = host.convert(window.convertFromScreen(toggle.1.accessibilityFrame()), from: nil)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertTrue(host.bounds.contains(frame), "Switch must remain within the minimum settings window")
            let selector = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
            XCTAssertTrue(toggle.0.responds(to: selector))
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let press = unsafeBitCast(try XCTUnwrap(toggle.0.method(for: selector)), to: Press.self)
            XCTAssertTrue(press(toggle.0, selector), "Invoke only this fixture host's AX action")
            let changed = expectation(for: NSPredicate { _, _ in model.settings.showMenubar == enabled }, evaluatedWith: nil)
            await fulfillment(of: [changed], timeout: 3)
            XCTAssertEqual(try store.settings().showMenubar, enabled)
            XCTAssertFalse(try store.settings().showDock)
        }
        XCTAssertFalse(window.isVisible, "Never order the test window onto the desktop")
    }

}
