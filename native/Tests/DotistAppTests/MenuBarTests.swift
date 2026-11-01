import AppKit
import DotistCore
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

    private func render(_ count: Int?, scale: Int) -> NSBitmapImageRep {
        let image = MenuBarImage.make(count: count, accessibilityDescription: "test")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 26 * scale, pixelsHigh: 18 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    func testTemplateImagesRenderAtBothScales() throws {
        for scale in [1, 2] {
            let empty = render(nil, scale: scale)
            func alpha(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
                image.colorAt(x: x, y: y)?.alphaComponent ?? 0
            }
            func ink(_ image: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> Int {
                x.reduce(0) { sum, px in sum + y.filter { alpha(image, px, $0) > 0.05 }.count }
            }
            // Check four separate arcs and the dot, not merely that the image is nonempty.
            for (x, y) in [(7..<11, 0..<3), (7..<11, 15..<18), (0..<3, 7..<11), (15..<18, 7..<11), (20..<23, 7..<11)] {
                XCTAssertGreaterThan(ink(empty, x: (x.lowerBound * scale)..<(x.upperBound * scale), y: (y.lowerBound * scale)..<(y.upperBound * scale)), 0)
            }
            var masks = Set<[Int]>()
            for count in [0, 1, 9, 10, 99, 100] {
                let image = MenuBarImage.make(count: count, accessibilityDescription: "\(count)")
                XCTAssertTrue(image.isTemplate)
                XCTAssertEqual(image.size, NSSize(width: 26, height: 18))
                let rep = render(count, scale: scale)
                var digitPixels: [Int] = []
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide where abs(alpha(rep, x, y) - alpha(empty, x, y)) > 0.05 {
                        digitPixels.append(y * rep.pixelsWide + x)
                        let dx = (CGFloat(x) + 0.5) / CGFloat(scale) - 9
                        let dy = (CGFloat(y) + 0.5) / CGFloat(scale) - 9
                        XCTAssertLessThan(dx * dx + dy * dy, 7.9 * 7.9, "\(count) at \(scale)x: digit touches or crosses the circle")
                    }
                }
                XCTAssertGreaterThan(digitPixels.count, 0, "Missing digits for \(count) at \(scale)x")
                masks.insert(digitPixels)
            }
            XCTAssertEqual(masks.count, 6, "Each displayed value must have distinct digit ink")
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
        XCTAssertEqual(button.image?.size.width, 26)
        XCTAssertEqual(button.accessibilityLabel(), expected(0))

        let legacy = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(legacy) }
        let legacyButton = try XCTUnwrap(legacy.button)
        legacyButton.image = NSImage(size: NSSize(width: 18, height: 18))
        legacyButton.title = " 99"
        legacyButton.imagePosition = .imageLeading
        legacyButton.layoutSubtreeIfNeeded()
        button.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(button.frame.width, 0, "Status item must have a real on-screen width")
        XCTAssertLessThan(button.frame.width, legacyButton.frame.width, "Compact item should be narrower than the previous icon and two-digit title")
        print("Menu bar widths: old \(legacyButton.frame.width) pt; new \(button.frame.width) pt")

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
}
