import Foundation
import XCTest

final class DotistUITests: XCTestCase {
    private var dataDirectory: String { ProcessInfo.processInfo.environment["DOTIST_UI_DATA"]! }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DOTIST_DATA_DIR"] = dataDirectory
        app.launch()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        XCTAssertTrue(app.dialogs["Dotist"].waitForExistence(timeout: 15))
        return app
    }

    private func sql(_ statement: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", dataDirectory + "/tasks.sqlite", statement]
        let pipe = Pipe()
        process.standardOutput = pipe
        try! process.run()
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func segment(_ label: String, in container: XCUIElement) -> XCUIElement {
        // NSSegmentedControl exposes buttons or radio buttons depending on macOS.
        let control = container.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)",
            label, XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.radioButton.rawValue
        )).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing segment: \(label)")
        return control
    }

    private func capture(_ element: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func relativeFrame(_ element: XCUIElement, in window: XCUIElement) -> CGRect {
        element.frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }

    func testCompletionButtonCenter() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        let input = main.textFields["新任务"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText("QA-完成按钮\n")
        let checkbox = main.buttons["完成 QA-完成按钮"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        checkbox.click()
        expectation(for: NSPredicate { _, _ in self.sql("SELECT completed FROM tasks WHERE title='QA-完成按钮'") == "1" }, evaluatedWith: nil)
        waitForExpectations(timeout: 8)
    }

    func testBubbleReturnsToPanel() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        main.buttons["收起为悬浮球"].click()
        let bubble = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "点击展开")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        bubble.click()
        XCTAssertTrue(main.textFields["新任务"].waitForExistence(timeout: 5))
    }

    func testCollapseRequiresPointerExitBeforeHoverDetails() throws {
        continueAfterFailure = false
        let path = URL(fileURLWithPath: dataDirectory).appendingPathComponent("settings.json")
        let original = try Data(contentsOf: path)
        var settings = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        settings["hover_expand"] = true
        try JSONSerialization.data(withJSONObject: settings).write(to: path)
        addTeardownBlock { try original.write(to: path) }
        let app = launch()
        let main = app.dialogs["Dotist"]
        main.buttons["收起为悬浮球"].click()
        let bubble = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "点击展开")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(main.frame.width, 48, accuracy: 1, "Collapse must not reveal hover details under the click pointer")
        capture(main, name: "collapse-pointer-stays-circle")
        main.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: -70, dy: 80)).hover()
        bubble.hover()
        expectation(for: NSPredicate { _, _ in main.frame.width > 70 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        capture(main, name: "fresh-pointer-entry-details")
        bubble.click()
        XCTAssertTrue(main.textFields["新任务"].waitForExistence(timeout: 5))
    }

    func testFocusAndGroupMenuUseBrandStyling() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        main.buttons["今天"].click()
        capture(main, name: "header-focus-no-blue")
        main.buttons["分组"].click()
        XCTAssertTrue(app.buttons["管理分组…"].waitForExistence(timeout: 5))
        capture(app.popovers.firstMatch.exists ? app.popovers.firstMatch : main, name: "group-menu-plain-rows")
        app.typeKey(.escape, modifierFlags: [])
        if main.buttons["取消置顶"].exists { main.buttons["取消置顶"].click() }
        main.buttons["任务视图"].click()
        let views = app.windows["任务视图"]
        XCTAssertTrue(views.waitForExistence(timeout: 5))
        segment("周", in: views).click()
        let days = views.groups.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日.*"))
        XCTAssertEqual(days.count, 7)
        days.element(boundBy: 0).buttons.firstMatch.click()
        XCTAssertTrue(days.element(boundBy: 0).buttons.firstMatch.isSelected)
        views.typeKey(.rightArrow, modifierFlags: [])
        expectation(for: NSPredicate { _, _ in days.element(boundBy: 1).buttons.firstMatch.isSelected }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(days.element(boundBy: 0).buttons.firstMatch.isSelected)
        app.activate()
        capture(views, name: "week-date-keyboard-focus")
    }

    func testGlassTabsKeepKeyboardFocusWithSelection() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        if main.buttons["取消置顶"].exists { main.buttons["取消置顶"].click() }
        main.buttons["任务视图"].click()
        let views = app.windows["任务视图"]
        XCTAssertTrue(views.waitForExistence(timeout: 5))
        segment("日", in: views).click()
        let days = views.groups.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日.*"))
        views.typeKey(.rightArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        views.typeKey(" ", modifierFlags: [])
        expectation(for: NSPredicate { _, _ in days.count == 7 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        capture(views, name: "glass-tabs-arrow-space-stays-week")
        views.buttons[XCUIIdentifierCloseWindow].click()
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Dotist 设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        segment("浅色", in: settings).click()
        let storedTheme = { () -> String? in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: self.dataDirectory + "/settings.json")),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return value["theme"] as? String
        }
        expectation(for: NSPredicate { _, _ in storedTheme() == "light" }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        settings.typeKey(.rightArrow, modifierFlags: [])
        expectation(for: NSPredicate { _, _ in storedTheme() == "dark" }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        settings.typeKey(" ", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(storedTheme(), "dark", "Async settings binding must not return keyboard focus to the old segment")
        capture(settings, name: "glass-tabs-async-theme-keyboard")
    }

    func testCalendarAndGanttNavigationKeepSelectedDate() {
        continueAfterFailure = false
        let app = launch()
        app.buttons["任务视图"].click()
        let views = app.windows["任务视图"]
        XCTAssertTrue(views.waitForExistence(timeout: 6))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh-CN")
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMMEEEEd")
        let selected = views.staticTexts[formatter.string(from: Date())].firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 4))
        views.buttons["下一段"].click()
        views.buttons["下一段"].click()
        XCTAssertTrue(selected.exists)
        segment("甘特", in: views).click()
        views.buttons["下一段"].click()
        segment("日历", in: views).click()
        XCTAssertTrue(selected.exists)
    }

    func testRepeatedBubbleExpansionPreservesTaskLayout() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        main.buttons["全部"].click()
        let input = main.textFields["新任务"]
        let titles = ["QA-布局稳定短任务", "QA-布局稳定这是一条足够长以跨行显示并在展开后保持位置不变的示例任务"]
        for title in titles {
            input.click()
            input.typeText(title + "\n")
            XCTAssertTrue(main.staticTexts[title].waitForExistence(timeout: 5))
        }
        let elements = titles.map { main.staticTexts[$0] } + [input]
        let windowSize = main.frame.size
        let frames = elements.map { relativeFrame($0, in: main) }
        XCTAssertGreaterThan(frames[1].height, frames[0].height, "The sample must exercise a wrapped task title")
        capture(main, name: "panel-layout-before-folding")

        for cycle in 1...4 {
            main.buttons["收起为悬浮球"].click()
            let bubble = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "点击展开")).firstMatch
            XCTAssertTrue(bubble.waitForExistence(timeout: 5))
            expectation(for: NSPredicate { _, _ in main.frame.height <= 49 }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            capture(main, name: "bubble-cycle-\(cycle)")
            bubble.click()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            expectation(for: NSPredicate { _, _ in
                abs(main.frame.width - windowSize.width) <= 1 && abs(main.frame.height - windowSize.height) <= 1
            }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)

            for (index, element) in elements.enumerated() {
                XCTAssertTrue(element.exists)
                let frame = relativeFrame(element, in: main)
                XCTAssertEqual(frame.minX, frames[index].minX, accuracy: 1, "Cycle \(cycle), element \(index): horizontal drift")
                XCTAssertEqual(frame.minY, frames[index].minY, accuracy: 1, "Cycle \(cycle), element \(index): vertical drift")
                XCTAssertEqual(frame.width, frames[index].width, accuracy: 1, "Cycle \(cycle), element \(index): width changed")
                XCTAssertEqual(frame.height, frames[index].height, accuracy: 1, "Cycle \(cycle), element \(index): wrapping changed")
            }
            capture(main, name: "panel-layout-after-cycle-\(cycle)")
        }
    }

    func testNativeViewSegmentsChangeCalendarAndTaskViews() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        if main.buttons["取消置顶"].exists { main.buttons["取消置顶"].click() }
        main.buttons["任务视图"].click()
        let views = app.windows["任务视图"]
        XCTAssertTrue(views.waitForExistence(timeout: 6))
        let days = views.groups.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日.*"))
        for (label, count) in [("日", 1), ("周", 7), ("月", 42)] {
            segment(label, in: views).click()
            expectation(for: NSPredicate { _, _ in days.count == count }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            capture(views, name: "native-calendar-\(label)")
        }
        segment("看板", in: views).click()
        XCTAssertTrue(views.staticTexts["进行中"].waitForExistence(timeout: 5))
        XCTAssertTrue(views.staticTexts["待办"].exists)
        capture(views, name: "native-board-segment")
        segment("甘特", in: views).click()
        XCTAssertTrue(segment("按分组", in: views).exists)
        XCTAssertTrue(segment("手动排序", in: views).exists)
        capture(views, name: "native-gantt-segment")
        segment("日历", in: views).click()
        expectation(for: NSPredicate { _, _ in days.count == 42 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        views.buttons[XCUIIdentifierCloseWindow].click()
    }

    func testGlassControlsAcceptOneClickAcrossTheirWholeSurface() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        if main.buttons["取消置顶"].exists { main.buttons["取消置顶"].click() }
        main.buttons["任务视图"].click()
        let views = app.windows["任务视图"]
        XCTAssertTrue(views.waitForExistence(timeout: 6))
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        for label in ["日", "周", "月", "周", "日"] {
            let button = segment(label, in: views)
            finder.activate()
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).click()
            expectation(for: NSPredicate { _, _ in button.isSelected }, evaluatedWith: nil)
            waitForExpectations(timeout: 3)
        }
        capture(views, name: "single-click-calendar-controls")
    }

    func testCalendarNavigationControlsHaveOneCompactHeight() {
        continueAfterFailure = false
        let app = launch()
        app.buttons["任务视图"].click()
        let views = app.windows["任务视图"]
        XCTAssertTrue(views.waitForExistence(timeout: 6))
        let today = views.buttons["今天"]
        for name in ["上一段", "下一段"] {
            let button = views.buttons[name]
            XCTAssertEqual(button.frame.width, button.frame.height, accuracy: 1)
            XCTAssertEqual(button.frame.height, today.frame.height, accuracy: 1)
            XCTAssertEqual(button.frame.height, 32, accuracy: 1)
        }
        capture(views, name: "compact-calendar-controls")
    }

    func testCalendarArrowPaddingRespondsToOneClick() {
        continueAfterFailure = false
        let app = launch()
        app.buttons["任务视图"].click()
        let views = app.windows["任务视图"]
        XCTAssertTrue(views.waitForExistence(timeout: 6))
        let title = views.staticTexts.matching(NSPredicate(format: "value MATCHES %@ OR label MATCHES %@", "[0-9]{4}年[0-9]{1,2}月", "[0-9]{4}年[0-9]{1,2}月")).firstMatch
        XCTAssertTrue(title.exists)
        let before = title.value as? String ?? title.label
        views.buttons["下一段"].coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).click()
        expectation(for: NSPredicate { _, _ in (title.value as? String ?? title.label) != before }, evaluatedWith: nil)
        waitForExpectations(timeout: 3)
    }

    func testInactiveWindowControlRespondsToFirstPhysicalClick() throws {
        guard ProcessInfo.processInfo.environment["DOTIST_UI_PHYSICAL_CLICK"] == "1" else { throw XCTSkip("Requires the guarded physical pointer driver") }
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        if main.buttons["取消置顶"].exists { main.buttons["取消置顶"].click() }
        app.activate()
        main.textFields["新任务"].click()
        main.buttons["任务视图"].click()
        let views = app.windows["任务视图"]
        XCTAssertTrue(views.waitForExistence(timeout: 6))
        let button = segment("周", in: views)
        let point = CGPoint(x: button.frame.midX, y: button.frame.midY)
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        let data = URL(fileURLWithPath: dataDirectory)
        try JSONSerialization.data(withJSONObject: ["x":point.x, "y":point.y]).write(to: data.appendingPathComponent("first-click-ready.json"))
        expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: data.appendingPathComponent("first-click-done").path) }, evaluatedWith: nil)
        waitForExpectations(timeout: 40)
        XCTAssertTrue(button.isSelected, "A physical click must perform the action while activating the window")
    }

    func testTopAndEmptyPanelAreasDragWithoutTakingButtonClicks() throws {
        guard ProcessInfo.processInfo.environment["DOTIST_UI_PHYSICAL_DRAG"] == "1" else { throw XCTSkip("Requires the guarded physical pointer driver") }
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        let data = URL(fileURLWithPath: dataDirectory)
        try Data().write(to:data.appendingPathComponent("position-ready"))
        expectation(for:NSPredicate { _, _ in FileManager.default.fileExists(atPath:data.appendingPathComponent("position-done").path) },evaluatedWith:nil)
        waitForExpectations(timeout:40)
        XCTAssertEqual(main.frame.minX,682,accuracy:1)
        XCTAssertEqual(main.frame.minY,149,accuracy:1)
        var dragIndex = 0
        func drag(_ start: CGPoint, by offset: CGVector) throws {
            dragIndex += 1
            app.activate()
            let data = URL(fileURLWithPath: dataDirectory)
            try JSONSerialization.data(withJSONObject: ["startX":start.x,"startY":start.y,"endX":start.x+offset.dx,"endY":start.y+offset.dy]).write(to:data.appendingPathComponent("drag-\(dragIndex)-ready.json"))
            expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath:data.appendingPathComponent("drag-\(dragIndex)-done").path) }, evaluatedWith:nil)
            waitForExpectations(timeout:40)
        }
        for point in [CGVector(dx: 150, dy: 260), CGVector(dx: 80, dy: 40)] {
            let before = main.frame
            try drag(CGPoint(x:before.minX + point.dx,y:before.minY + point.dy),by:CGVector(dx:-32,dy:-24))
            XCTAssertGreaterThan(hypot(main.frame.minX - before.minX, main.frame.minY - before.minY), 20)
            XCTAssertEqual(main.frame.size, before.size)
        }
        main.buttons["任务视图"].click()
        let views = app.windows["任务视图"]
        XCTAssertTrue(views.waitForExistence(timeout: 5))
        let before = views.frame
        try drag(CGPoint(x:before.minX+250,y:before.minY+24),by:CGVector(dx:32,dy:24))
        XCTAssertGreaterThan(hypot(views.frame.minX - before.minX, views.frame.minY - before.minY), 20)
        let gapFrame = views.frame
        try drag(CGPoint(x:gapFrame.minX+400,y:gapFrame.minY+80),by:CGVector(dx:32,dy:24))
        XCTAssertGreaterThan(hypot(views.frame.minX - gapFrame.minX, views.frame.minY - gapFrame.minY),20)
        segment("看板", in: views).click()
        XCTAssertTrue(views.staticTexts["进行中"].waitForExistence(timeout: 3))
        capture(views, name: "header-drag-preserves-controls")
        app.typeKey(",",modifierFlags:.command)
        let settings = app.windows["Dotist 设置"]
        XCTAssertTrue(settings.waitForExistence(timeout:5))
        let settingsFrame = settings.frame
        try drag(CGPoint(x:settingsFrame.minX+250,y:settingsFrame.minY+24),by:CGVector(dx:32,dy:24))
        XCTAssertGreaterThan(hypot(settings.frame.minX-settingsFrame.minX,settings.frame.minY-settingsFrame.minY),20)
    }

    func testNativeThemeSegmentsPersistSelection() {
        continueAfterFailure = false
        let app = launch()
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Dotist 设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 6))
        for (label, theme) in [("深色", "dark"), ("浅色", "light"), ("跟随系统", "system"), ("浅色", "light")] {
            segment(label, in: settings).click()
            expectation(for: NSPredicate { _, _ in
                let url = URL(fileURLWithPath: self.dataDirectory).appendingPathComponent("settings.json")
                guard let data = try? Data(contentsOf: url),
                      let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return stored["theme"] as? String == theme
            }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            capture(settings, name: "native-theme-\(theme)")
        }
        settings.buttons[XCUIIdentifierCloseWindow].click()
    }
    private var updateTarget: [String: String] {
        let path = URL(fileURLWithPath: dataDirectory).appendingPathComponent("update-target.json")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: String]
    }

    func testSignedUpdaterCheck() throws {
        guard FileManager.default.fileExists(atPath:dataDirectory + "/update-target.json") else { throw XCTSkip("Requires a signed isolated update fixture") }
        continueAfterFailure = false
        let app = launch()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["设置…"].click()
        let settings = app.windows["Dotist 设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 6))
        settings.buttons["数据与关于"].click()
        let check = settings.buttons["检查更新"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        check.click()
        let available = settings.staticTexts["发现新版本 \(updateTarget["version"]!)"]
        if !available.waitForExistence(timeout: 15) { print("DOTIST_UPDATE_AX_START\n\(settings.debugDescription)\nDOTIST_UPDATE_AX_END") }
        XCTAssertTrue(available.exists)
        XCTAssertTrue(settings.buttons["立即更新"].exists)
        print("DOTIST_SIGNED_UPDATE_CHECK_OK")
    }


    func testRejectTamperedUpdate() throws {
        guard FileManager.default.fileExists(atPath:dataDirectory + "/update-target.json") else { throw XCTSkip("Requires a signed isolated update fixture") }
        continueAfterFailure = false
        let app = launch()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["设置…"].click()
        let settings = app.windows["Dotist 设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 6))
        settings.buttons["数据与关于"].click()
        settings.buttons["检查更新"].click()
        XCTAssertTrue(settings.staticTexts["发现新版本 \(updateTarget["version"]!)"].waitForExistence(timeout: 15))
        settings.buttons["立即更新"].click()
        let failure = settings.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "检查更新失败：")).firstMatch
        if !failure.waitForExistence(timeout: 35) { print("DOTIST_UPDATE_FAILURE_AX_START\n\(settings.debugDescription)\nDOTIST_UPDATE_FAILURE_AX_END") }
        XCTAssertTrue(failure.exists)
        print("DOTIST_UPDATE_ERROR: \(failure.value ?? "unknown")")
        let info = URL(fileURLWithPath: dataDirectory).deletingLastPathComponent().appendingPathComponent("Dotist-Native-QA.app/Contents/Info.plist")
        let value = try! PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as! [String: Any]
        XCTAssertEqual(value["CFBundleVersion"] as? String, updateTarget["currentBuild"])
        print("DOTIST_TAMPERED_UPDATE_REJECTED")
    }

    func testInstallSignedUpdate() throws {
        guard FileManager.default.fileExists(atPath:dataDirectory + "/update-target.json") else { throw XCTSkip("Requires a signed isolated update fixture") }
        continueAfterFailure = false
        let app = launch()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["设置…"].click()
        let settings = app.windows["Dotist 设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 6))
        settings.buttons["数据与关于"].click()
        settings.buttons["检查更新"].click()
        XCTAssertTrue(settings.staticTexts["发现新版本 \(updateTarget["version"]!)"].waitForExistence(timeout: 15))
        settings.buttons["立即更新"].click()
        let info = URL(fileURLWithPath: dataDirectory).deletingLastPathComponent().appendingPathComponent("Dotist-Native-QA.app/Contents/Info.plist")
        expectation(for: NSPredicate { _, _ in
            guard let bytes = try? Data(contentsOf: info), let value = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { return false }
            return value["CFBundleVersion"] as? String == self.updateTarget["targetBuild"]
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 45)
        print("DOTIST_SIGNED_UPDATE_INSTALLED_IN_QA")
    }


    func testDisableStagedAutomaticUpdate() throws {
        guard FileManager.default.fileExists(atPath:dataDirectory + "/update-target.json") else { throw XCTSkip("Requires a signed isolated update fixture") }
        continueAfterFailure = false
        let app = launch()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["设置…"].click()
        let settings = app.windows["Dotist 设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 6))
        settings.buttons["数据与关于"].click()
        let staged = settings.staticTexts["更新已下载，退出 Dotist 时安装。"]
        if !staged.waitForExistence(timeout: 30) { print("DOTIST_AUTO_UPDATE_AX_START\n\(settings.debugDescription)\nDOTIST_AUTO_UPDATE_AX_END") }
        XCTAssertTrue(staged.exists)
        settings.checkBoxes["自动安装更新"].click()
        XCTAssertTrue(staged.waitForNonExistence(timeout: 20))
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["退出 Dotist"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        let info = URL(fileURLWithPath: dataDirectory).deletingLastPathComponent().appendingPathComponent("Dotist-Native-QA.app/Contents/Info.plist")
        for _ in 0..<32 {
            let value = try! PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as! [String: Any]
            XCTAssertEqual(value["CFBundleVersion"] as? String, updateTarget["currentBuild"])
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("DOTIST_DISABLE_STAGED_AUTO_UPDATE_OK")
    }

    func testAutomaticUpdateOnQuit() throws {
        guard FileManager.default.fileExists(atPath:dataDirectory + "/update-target.json") else { throw XCTSkip("Requires a signed isolated update fixture") }
        continueAfterFailure = false
        let app = launch()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["设置…"].click()
        let settings = app.windows["Dotist 设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 6))
        settings.buttons["数据与关于"].click()
        let staged = settings.staticTexts["更新已下载，退出 Dotist 时安装。"]
        XCTAssertTrue(staged.waitForExistence(timeout: 30))
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["退出 Dotist"].click()
        let info = URL(fileURLWithPath: dataDirectory).deletingLastPathComponent().appendingPathComponent("Dotist-Native-QA.app/Contents/Info.plist")
        expectation(for: NSPredicate { _, _ in
            guard let bytes = try? Data(contentsOf: info), let value = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { return false }
            return value["CFBundleVersion"] as? String == self.updateTarget["targetBuild"]
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 45)
        print("DOTIST_AUTOMATIC_UPDATE_ON_QUIT_OK")
    }

    func testSkipStagedUpdatePersistsAndAllowsManualCheck() throws {
        guard FileManager.default.fileExists(atPath:dataDirectory + "/update-target.json") else { throw XCTSkip("Requires a signed isolated update fixture") }
        continueAfterFailure = false
        let app = launch()
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Dotist 设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 6))
        settings.buttons["数据与关于"].click()
        let staged = settings.staticTexts["更新已下载，退出 Dotist 时安装。"]
        XCTAssertTrue(staged.waitForExistence(timeout: 30))
        settings.buttons["跳过此版本"].click()
        XCTAssertTrue(staged.waitForNonExistence(timeout: 15))
        let path = URL(fileURLWithPath:dataDirectory).appendingPathComponent("settings.json")
        let saved = try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Any]
        XCTAssertEqual(saved["skipped_update_version"] as? String,updateTarget["version"])
        let check = settings.buttons["检查更新"]
        expectation(for:NSPredicate { _, _ in check.isEnabled },evaluatedWith:nil)
        waitForExpectations(timeout:15)
        check.click()
        XCTAssertTrue(settings.staticTexts["发现新版本 \(updateTarget["version"]!)"].waitForExistence(timeout:15))
        capture(settings, name:"manual-check-after-skipped-update")
    }


}
