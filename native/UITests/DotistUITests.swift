import AppKit
import Foundation
import XCTest

final class DotistUITests: XCTestCase {
    private var dataDirectory: String { ProcessInfo.processInfo.environment["DOTIST_UI_DATA"]! }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DOTIST_DATA_DIR"] = dataDirectory
        // Keep the fixture away from notifications in the top-right corner.
        let screen = NSScreen.main!.visibleFrame
        let preferences = UserDefaults(suiteName: "dev.codex.dotist-native-qa")!
        preferences.set(screen.midX - 182, forKey: "dotist.native.window.x")
        preferences.set(screen.midY - 310, forKey: "dotist.native.window.y")
        XCTAssertTrue(preferences.synchronize())
        app.launch()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        XCTAssertTrue(app.dialogs["Dotist"].waitForExistence(timeout: 15))
        app.activate()
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

    private func activate(_ app: XCUIApplication, showing element: XCUIElement) {
        // testmanagerd can restore another app after keyboard synthesis has returned.
        for _ in 0..<3 {
            let state = app.state
            guard state == .runningForeground || state == .runningBackground else {
                XCTFail("QA exited before foreground recovery")
                return
            }
            app.activate()
            if element.waitForExistence(timeout: 1) && app.state == .runningForeground { return }
        }
        XCTFail("The existing QA window did not regain the foreground")
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

    private func openTaskViews(_ app: XCUIApplication) {
        let main = app.dialogs["Dotist"]
        let views = main.buttons["任务视图"]
        XCTAssertTrue(views.waitForExistence(timeout: 5))
        views.click()
    }

    private func selectGroup(_ id: String, name: String, in window: XCUIElement, app: XCUIApplication) {
        if window.label == "Dotist" {
            let item = app.buttons["side-tab:\(id)"]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Missing side tab \(id)")
            item.click()
        } else {
            window.staticTexts["group-menu"].rightClick()
            let item = app.menuItems.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Missing group menu item \(id)")
            item.click()
        }
    }

    private func openGroupPanel(_ id: String, name: String, app: XCUIApplication) -> XCUIElement {
        app.dialogs["Dotist"].staticTexts["group-menu"].rightClick()
        let open = app.menuItems["在独立面板中打开"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        open.hover()
        app.menuItems[name].click()
        let panel = app.dialogs["Dotist · " + name]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        return panel
    }

    func testInboxDefaultAndGroupContextAddPreserveTheirCategories() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        let composer = main.textFields["新任务"]
        composer.click()
        composer.typeText("QA-Inbox 默认收集\n")
        expectation(for: NSPredicate { _, _ in self.sql("SELECT category FROM tasks WHERE title='QA-Inbox 默认收集'") == "inbox" }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        selectGroup("work", name: "工作", in: main, app: app)
        main.staticTexts["工作"].rightClick()
        app.menuItems["添加任务"].click()
        let groupInput = main.textFields["新任务（工作）"]
        XCTAssertTrue(groupInput.waitForExistence(timeout: 5))
        groupInput.typeText("QA-工作组内添加\n")
        expectation(for: NSPredicate { _, _ in self.sql("SELECT category FROM tasks WHERE title='QA-工作组内添加'") == "work" }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(main.buttons["完成 QA-Inbox 默认收集"].exists)
        XCTAssertFalse(main.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "还有 ")).firstMatch.exists)
        capture(main, name: "inbox-group-context-add")
    }

    func testGroupPanelsSwitchIndependentlyAndKeepDraftsThroughBubbles() {
        continueAfterFailure = false
        let app = launch()
        let work = openGroupPanel("work", name: "工作", app: app)
        let workSize = work.frame.size
        let draft = work.textFields["新任务"]
        draft.click()
        draft.typeText("QA-保留未提交草稿")
        let life = openGroupPanel("life", name: "生活", app: app)
        let lifeSize = life.frame.size
        work.buttons["收起为悬浮球"].click()
        life.buttons["收起为悬浮球"].click()
        expectation(for: NSPredicate { _, _ in
            abs(work.frame.width - 48) < 1 && abs(work.frame.height - 48) < 1
                && abs(life.frame.width - 48) < 1 && abs(life.frame.height - 48) < 1
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(work.frame.width, 48, accuracy: 1)
        XCTAssertEqual(life.frame.width, 48, accuracy: 1)
        capture(app, name: "independent-group-bubbles")
        work.buttons["展开分组 工作"].click()
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _, _ in
            abs(work.frame.width - workSize.width) < 1 && abs(work.frame.height - workSize.height) < 1
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(draft.value as? String, "QA-保留未提交草稿")
        XCTAssertEqual(life.frame.width, 48, accuracy: 1)
        selectGroup("study", name: "学习", in: work, app: app)
        let study = app.dialogs["Dotist · 学习"]
        XCTAssertTrue(study.waitForExistence(timeout: 5))
        XCTAssertEqual(study.buttons["分组"].value as? String, "学习")
        XCTAssertEqual(app.dialogs["Dotist"].buttons["分组"].value as? String, "Inbox")
        study.buttons["关闭面板"].click()
        life.buttons["展开分组 生活"].click()
        expectation(for: NSPredicate { _, _ in
            abs(life.frame.width - lifeSize.width) < 1 && abs(life.frame.height - lifeSize.height) < 1
                && life.textFields["新任务"].exists
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        life.buttons["关闭面板"].click()
    }

    func testGroupBubblesRevealAndRetractIndependentlyWithSharedMotion() throws {
        continueAfterFailure = false
        let path = URL(fileURLWithPath: dataDirectory).appendingPathComponent("settings.json")
        let original = try Data(contentsOf: path)
        var settings = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        settings["hover_expand"] = true
        try JSONSerialization.data(withJSONObject: settings).write(to: path)
        addTeardownBlock { try original.write(to: path) }
        let app = launch()
        let work = openGroupPanel("work", name: "工作", app: app)
        let life = openGroupPanel("life", name: "生活", app: app)
        let workSize = work.frame.size
        let lifeSize = life.frame.size
        work.buttons["收起为悬浮球"].click()
        life.buttons["收起为悬浮球"].click()
        expectation(for: NSPredicate { _, _ in
            abs(work.frame.width - 48) < 1 && abs(work.frame.height - 48) < 1
                && abs(life.frame.width - 48) < 1 && abs(life.frame.height - 48) < 1
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)

        let workBubble = work.buttons["展开分组 工作"]
        let lifeBubble = life.buttons["展开分组 生活"]
        XCTAssertTrue(workBubble.waitForExistence(timeout: 5))
        XCTAssertTrue(lifeBubble.waitForExistence(timeout: 5))
        for (name, panel, other, bubble) in [("work", work, life, workBubble), ("life", life, work, lifeBubble)] {
            let circle = panel.frame
            let otherCircle = other.frame
            let outside = panel.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: -70, dy: 80))
            activate(app, showing: bubble)
            outside.hover()
            bubble.hover()
            expectation(for: NSPredicate { _, _ in panel.frame.width > 70 && abs(panel.frame.height - 48) < 1 }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            XCTAssertLessThanOrEqual(min(abs(panel.frame.minX - circle.minX), abs(panel.frame.maxX - circle.maxX)), 1,
                "Each group circle must anchor its own detail capsule")
            XCTAssertEqual(other.frame, otherCircle, "Hovering one group must leave the other bubble unchanged")
            capture(panel, name: "group-\(name)-hover-reveal")
            outside.hover()
            expectation(for: NSPredicate { _, _ in abs(panel.frame.width - 48) < 1 && abs(panel.frame.height - 48) < 1 }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(other.frame, otherCircle)
            capture(panel, name: "group-\(name)-hover-retracted")
        }

        // Expand the left panel first so it cannot cover the other group's circle.
        XCTAssertTrue(lifeBubble.isHittable)
        lifeBubble.click()
        expectation(for: NSPredicate { _, _ in
            abs(life.frame.width - lifeSize.width) < 1 && abs(life.frame.height - lifeSize.height) < 1
                && life.textFields["新任务"].exists
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(work.frame.size, CGSize(width: 48, height: 48))
        XCTAssertFalse(work.textFields["新任务"].exists)
        XCTAssertTrue(workBubble.isHittable)
        workBubble.click()
        expectation(for: NSPredicate { _, _ in
            abs(work.frame.width - workSize.width) < 1 && abs(work.frame.height - workSize.height) < 1
                && work.textFields["新任务"].exists
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(life.frame.size, lifeSize)
        XCTAssertTrue(life.textFields["新任务"].exists)
        capture(app, name: "group-panels-expanded-after-independent-hover")
        work.buttons["关闭面板"].click()
        life.buttons["关闭面板"].click()
    }

    func testSearchWindowCanBeDraggedAndKeepsItsQuery() {
        continueAfterFailure = false
        let app = launch()
        app.dialogs["Dotist"].buttons["搜索"].click()
        let search = app.windows["搜索"]
        let field = app.textFields["搜索任务、分组或视图"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("工作")
        activate(app, showing: field)
        let before = search.frame
        let handle = search.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 250, dy: 18))
        handle.press(forDuration: 0.12, thenDragTo: handle.withOffset(CGVector(dx: -80, dy: 48)))
        XCTAssertGreaterThan(hypot(search.frame.minX - before.minX, search.frame.minY - before.minY), 30)
        XCTAssertEqual(field.value as? String, "工作")
        capture(search, name: "draggable-search-window")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(field.exists)
    }

    func testDraggingInboxTaskOntoGroupHeaderClassifiesIt() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        let composer = main.textFields["新任务"]
        let title = "QA-inbox-drag-\(UUID().uuidString.prefix(8))"
        composer.click()
        composer.typeText(title + "\n")
        let task = main.staticTexts[title]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        let destination = main.staticTexts["工作"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        task.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.25, thenDragTo: destination)
        expectation(for: NSPredicate { _, _ in self.sql("SELECT category FROM tasks WHERE title='\(title)'") == "work" }, evaluatedWith: nil)
        waitForExpectations(timeout: 6)
        capture(main, name: "inbox-drag-classification")
    }

    func testCancelledDragDoesNotBlockLaterTaskChanges() throws {
        continueAfterFailure = false
        let settingsURL = URL(fileURLWithPath: dataDirectory).appendingPathComponent("settings.json")
        var settings = FileManager.default.fileExists(atPath: settingsURL.path)
            ? try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any] : [:]
        settings["mcp_enabled"] = true
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL, options: .atomic)
        let app = launch()
        let main = app.dialogs["Dotist"]
        let composer = main.textFields["新任务"]
        composer.click()
        composer.typeText("QA-cancel-drag\n")
        let task = main.staticTexts["QA-cancel-drag"]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.25,
            thenDragTo: main.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 160, dy: 18)))
        composer.click()
        composer.typeText("QA-after-cancel\n")
        XCTAssertTrue(main.buttons["完成 QA-after-cancel"].waitForExistence(timeout: 5))

        task.click()
        let editor = main.textViews["任务内容"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("QA-cancel-edited")
        selectGroup("life", name: "生活", in: main, app: app)
        expectation(for: NSPredicate { _, _ in self.sql("SELECT COUNT(*) FROM tasks WHERE title='QA-cancel-edited'") == "1" }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        selectGroup("inbox", name: "Inbox", in: main, app: app)
        XCTAssertTrue(main.buttons["完成 QA-cancel-edited"].waitForExistence(timeout: 5))

        let socket = dataDirectory + "/mcp.sock"
        expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: socket) }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        // This external client uses the app's real MCP endpoint and TaskStore writes.
        let client = Process()
        client.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        client.arguments = ["-c", #"""
        import json, socket, sys
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(sys.argv[1])
            with connection.makefile("rwb") as stream:
                def send(value):
                    stream.write((json.dumps(value) + "\n").encode())
                    stream.flush()
                def receive(identifier):
                    while True:
                        line = stream.readline()
                        if not line:
                            raise RuntimeError("MCP closed before its reply")
                        value = json.loads(line)
                        if value.get("id") != identifier:
                            continue
                        if "error" in value:
                            raise RuntimeError(value["error"])
                        return value["result"]
                send({"jsonrpc":"2.0", "id":1, "method":"initialize", "params":{
                    "protocolVersion":"2025-06-18", "capabilities":{},
                    "clientInfo":{"name":"dotist-cancel-ui-test", "version":"1"}}})
                receive(1)
                send({"jsonrpc":"2.0", "method":"notifications/initialized"})
                send({"jsonrpc":"2.0", "id":2, "method":"tools/call", "params":{
                    "name":"add_tasks", "arguments":{"category":"inbox",
                    "tasks":[{"title":"QA-external-after-cancel"}]}}})
                result = receive(2)
                if result.get("isError", False):
                    raise RuntimeError(result)
                print(json.dumps(result))
        """#, socket]
        let response = Pipe()
        client.standardOutput = response
        client.standardError = response
        try client.run()
        defer { if client.isRunning { client.terminate(); client.waitUntilExit() } }
        let result = response.fileHandleForReading.readDataToEndOfFile()
        client.waitUntilExit()
        XCTAssertEqual(client.terminationStatus, 0, String(decoding: result, as: UTF8.self))
        XCTAssertTrue(main.buttons["完成 QA-external-after-cancel"].waitForExistence(timeout: 6))
        XCTAssertEqual(sql("SELECT category FROM tasks WHERE title='QA-external-after-cancel'"), "inbox")
        capture(main, name: "cancelled-drag-edited-and-external-change-synced")
    }

    func testSwitchingGroupsSavesTheTaskBeingEdited() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        let composer = main.textFields["新任务"]
        composer.click()
        composer.typeText("QA-edit-before-switch\n")
        let title = main.staticTexts["QA-edit-before-switch"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        let editor = main.textViews["任务内容"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("QA-edit-saved-on-switch")
        selectGroup("life", name: "生活", in: main, app: app)
        expectation(for: NSPredicate { _, _ in self.sql("SELECT COUNT(*) FROM tasks WHERE title='QA-edit-saved-on-switch'") == "1" }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        selectGroup("inbox", name: "Inbox", in: main, app: app)
        XCTAssertTrue(main.buttons["完成 QA-edit-saved-on-switch"].waitForExistence(timeout: 5))
    }

    func testLongGroupComposerStaysOnOneLineAndKeepsTheDraft() throws {
        continueAfterFailure = false
        let path = URL(fileURLWithPath: dataDirectory).appendingPathComponent("settings.json")
        let original = try Data(contentsOf: path)
        var settings = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        settings["window_width"] = 320
        settings["window_height"] = 440
        settings["theme"] = "dark"
        try JSONSerialization.data(withJSONObject: settings).write(to: path)
        addTeardownBlock { try original.write(to: path) }
        let app = launch()
        let main = app.dialogs["Dotist"]
        main.buttons["分组"].click()
        app.menuItems["管理分组…"].click()
        let name = "Side project · 项目管理"
        let field = main.textFields["新分组，回车添加"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(name + "\n")
        XCTAssertTrue(main.buttons[name].waitForExistence(timeout: 5))
        main.buttons["返回任务列表"].click()
        let composer = main.textFields["新任务"]
        composer.click()
        composer.typeText("QA-换行保留草稿")
        main.buttons["分组"].click()
        app.menuItems[name].click()
        let group = main.buttons["分组"]
        XCTAssertEqual(group.value as? String, name)
        XCTAssertGreaterThan(group.frame.width, 80)
        XCTAssertEqual(composer.value as? String, "QA-换行保留草稿")
        XCTAssertGreaterThan(composer.frame.width, 0)
        XCTAssertEqual(composer.frame.midY, group.frame.midY, accuracy: 4)
        capture(main, name: "adaptive-composer-dark-compact")
    }

    func testHoverActionsStayAvailableAcrossTheirHitRegion() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        let title = "QA-悬停操作稳定性"
        let composer = main.textFields["新任务"]
        composer.click()
        composer.typeText(title + "\n")
        let task = main.buttons["完成 " + title]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        let initial = task.frame
        let remove = main.buttons["删除 " + title]
        task.hover()
        for _ in 0..<6 {
            remove.hover()
            XCTAssertTrue(remove.isHittable, "The action must keep its hover hit region")
            XCTAssertEqual(task.frame, initial, "Hovering must not move the task")
            task.hover()
        }
        capture(main, name: "task-row-hover")
    }

    func testHeaderActionsStayAboveDateFiltersAndSearchUsesKeyboard() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        let search = main.buttons["搜索"]
        let calendar = main.buttons["日历"]
        let collapse = main.buttons["收起为悬浮球"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(main.buttons["任务视图"].exists)
        XCTAssertTrue(collapse.exists)
        XCTAssertGreaterThan(calendar.frame.minY, search.frame.maxY)
        XCTAssertEqual(search.frame.minY, collapse.frame.minY, accuracy: 1)
        capture(main, name: "header-two-rows")
        search.click()
        let field = app.textFields["搜索任务、分组或视图"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("工作")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        capture(app, name: "command-palette-keyboard")
        app.typeKey(.escape, modifierFlags: [])
        expectation(for: NSPredicate { _, _ in !field.exists }, evaluatedWith: nil)
        waitForExpectations(timeout: 3)
        calendar.click()
        XCTAssertTrue(app.buttons["下个月"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSearchGroupFromBubbleShowsMainPanel() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        main.buttons["收起为悬浮球"].click()
        expectation(for: NSPredicate { _, _ in main.frame.width <= 49 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)

        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["搜索任务、分组或视图"]
        activate(app, showing: search)
        search.click()
        search.typeText("工作")
        activate(app, showing: search)
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "工作")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.click()
        activate(app, showing: main)

        let composer = main.textFields["新任务"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Selecting a group must display the main task list")
        XCTAssertGreaterThan(main.frame.width, 300)
        XCTAssertEqual(main.buttons["分组"].value as? String, "工作")
        XCTAssertFalse(search.exists)
        capture(main, name: "search-group-from-bubble")
    }

    func testSearchTaskLeavesGroupAndTagManagers() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        let title = "QA-搜索离开管理页 #导航"
        let composer = main.textFields["新任务"]
        composer.click()
        composer.typeText(title + "\n")
        let task = main.buttons["完成 " + title]
        XCTAssertTrue(task.waitForExistence(timeout: 5))

        for tags in [false, true] {
            main.buttons["分组"].click()
            let manage = app.buttons["管理分组…"]
            XCTAssertTrue(manage.waitForExistence(timeout: 5))
            manage.click()
            let back = main.buttons["返回任务列表"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            if tags { main.buttons["标签"].click() }
            app.typeKey("k", modifierFlags: .command)
            let search = app.textFields["搜索任务、分组或视图"]
            activate(app, showing: search)
            search.click()
            search.typeText("QA-搜索离开管理页")
            activate(app, showing: search)
            let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 5))
            result.click()
            activate(app, showing: main)

            XCTAssertTrue(composer.waitForExistence(timeout: 5), "Explicit task navigation must leave management pages")
            XCTAssertFalse(back.exists)
            XCTAssertTrue(task.exists)
            XCTAssertTrue(task.isHittable)
            capture(main, name: tags ? "search-task-from-tag-manager" : "search-task-from-group-manager")
        }
    }

    func testHeaderActionsPersistWindowSettings() throws {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        let path = URL(fileURLWithPath: dataDirectory).appendingPathComponent("settings.json")
        let original = try Data(contentsOf: path)
        let initial = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        addTeardownBlock { app.terminate(); try original.write(to: path) }
        for (key, off, on) in [("always_on_top", "置顶窗口", "取消置顶"), ("locked", "固定窗口", "取消固定")] {
            main.buttons["任务视图"].hover()
            let enabled = initial[key] as? Bool ?? (key == "always_on_top")
            let action = main.buttons[enabled ? on : off]
            XCTAssertTrue(action.waitForExistence(timeout: 3))
            action.click()
            expectation(for: NSPredicate { _, _ in
                guard let data = try? Data(contentsOf: path), let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return settings[key] as? Bool == !enabled
            }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            XCTAssertTrue(main.buttons[enabled ? off : on].waitForExistence(timeout: 3))
        }
        openTaskViews(app)
        XCTAssertTrue(app.windows["任务视图"].waitForExistence(timeout: 5))
    }

    func testHeaderFitsCompactWindowAndSupportsKeyboard() throws {
        continueAfterFailure = false
        let path = URL(fileURLWithPath: dataDirectory).appendingPathComponent("settings.json")
        let original = try Data(contentsOf: path)
        var settings = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        settings["window_width"] = 320
        settings["window_height"] = 440
        settings["language"] = "en"
        settings["theme"] = "dark"
        try JSONSerialization.data(withJSONObject: settings).write(to: path)
        addTeardownBlock { try original.write(to: path) }
        let app = launch()
        let main = app.dialogs["Dotist"]
        let search = main.buttons["Search"]
        let views = main.buttons["Task views"]
        XCTAssertTrue(views.waitForExistence(timeout: 5))
        XCTAssertEqual(main.frame.width, 320, accuracy: 1)
        XCTAssertEqual(main.frame.height, 440, accuracy: 1)
        for button in [search, views, main.buttons["Calendar"], main.buttons["Collapse to bubble"]] {
            XCTAssertTrue(button.exists)
            XCTAssertGreaterThanOrEqual(button.frame.minX, main.frame.minX)
            XCTAssertLessThanOrEqual(button.frame.maxX, main.frame.maxX)
        }
        capture(main, name: "header-compact-dark-english")
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["Search tasks, groups or views"]
        activate(app, showing: field)
        XCTAssertTrue(field.exists)
        app.typeKey(.escape, modifierFlags: [])
        activate(app, showing: search)
        XCTAssertFalse(field.exists, "Escape must close search before keyboard navigation")
        XCTAssertFalse(app.windows["Task views"].exists)
        // Anchor keyboard navigation in the composer instead of activation's default focus.
        let composer = main.textFields["New task"]
        XCTAssertTrue(composer.exists)
        composer.click()
        for _ in 0..<2 {
            app.typeKey(.tab, modifierFlags: [])
            activate(app, showing: views)
        }
        app.typeKey(" ", modifierFlags: [])
        activate(app, showing: app.windows["Task views"])
        XCTAssertTrue(app.windows["Task views"].waitForExistence(timeout: 5))
    }

    func testFilterButtonsDragWindowWithoutChangingSelection() throws {
        guard ProcessInfo.processInfo.environment["DOTIST_UI_PHYSICAL_DRAG"] == "1" else { throw XCTSkip("Requires the guarded physical pointer driver") }
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        XCTAssertTrue(main.buttons["全部"].isSelected)
        let before = main.frame
        let data = URL(fileURLWithPath: dataDirectory)
        try Data().write(to: data.appendingPathComponent("filter-window-drag-ready"))
        expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: data.appendingPathComponent("filter-window-drag-done").path) }, evaluatedWith: nil)
        waitForExpectations(timeout: 40)
        XCTAssertGreaterThan(hypot(main.frame.minX - before.minX, main.frame.minY - before.minY), 50)
        XCTAssertTrue(main.buttons["全部"].isSelected, "Dragging a filter must move the window without selecting it")
        main.buttons["今天"].click()
        XCTAssertTrue(main.buttons["今天"].isSelected, "A normal click must still select the filter")
        capture(main, name: "filter-label-window-drag")
    }

    func testSettingsFiltersReorderByDragging() throws {
        guard ProcessInfo.processInfo.environment["DOTIST_UI_PHYSICAL_DRAG"] == "1" else { throw XCTSkip("Requires the guarded physical pointer driver") }
        continueAfterFailure = false
        let path = URL(fileURLWithPath: dataDirectory).appendingPathComponent("settings.json")
        let original = try Data(contentsOf: path)
        var initial = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        initial["filters"] = ["today", "all", "tomorrow", "week", "nextweek", "next7", "overdue", "undated", "done"]
        try JSONSerialization.data(withJSONObject: initial).write(to: path)
        addTeardownBlock { try original.write(to: path) }
        let app = launch()
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Dotist 设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["筛选器"].click()
        XCTAssertTrue(settings.staticTexts["今天"].waitForExistence(timeout: 3))
        try Data().write(to: path.deletingLastPathComponent().appendingPathComponent("filter-order-drag-ready"))
        expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: path.deletingLastPathComponent().appendingPathComponent("filter-order-drag-done").path) }, evaluatedWith: nil)
        waitForExpectations(timeout: 40)
        expectation(for: NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: path), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let filters = value["filters"] as? [String] else { return false }
            return Array(filters.prefix(3)) == ["all", "tomorrow", "today"] && Set(filters).count == 9
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        capture(settings, name: "settings-drag-filter-order")
    }

    func testSettingsSeparateDataAndAboutAndProvideCodex() {
        continueAfterFailure = false
        let app = launch()
        let clipboard = NSPasteboard.general
        let original = (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        addTeardownBlock { clipboard.clearContents(); clipboard.writeObjects(original) }
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Dotist 设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertFalse(settings.staticTexts["分组颜色"].exists)
        XCTAssertFalse(settings.buttons["数据与关于"].exists)
        capture(settings, name: "settings-native-appearance-controls")
        settings.buttons["MCP"].click()
        let copy = settings.buttons["复制 Codex 添加命令"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        copy.click()
        let command = clipboard.string(forType: .string) ?? ""
        XCTAssertTrue(command.hasPrefix("codex mcp add dotist --env "))
        XCTAssertTrue(command.contains("DOTIST_DATA_DIR=" + dataDirectory))
        XCTAssertTrue(command.hasSuffix("/Contents/MacOS/dotist' --mcp"))
        capture(settings, name: "settings-codex-mcp")
        settings.buttons["数据"].click()
        XCTAssertTrue(settings.staticTexts["数据库路径"].waitForExistence(timeout: 3))
        XCTAssertFalse(settings.buttons["检查更新"].exists)
        settings.buttons["关于"].click()
        XCTAssertTrue(settings.buttons["检查更新"].waitForExistence(timeout: 3))
        XCTAssertFalse(settings.staticTexts["数据库路径"].exists)
        capture(settings, name: "settings-about-updates")
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

    func testComposerGroupUsesLeadingLayoutAndOpensPicker() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        let group = main.buttons["分组"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        capture(main, name: "composer-group-insets")
        let leading = group.frame.minX - main.frame.minX
        let bottom = main.frame.maxY - group.frame.maxY
        XCTAssertEqual(leading, 20, accuracy: 1)
        XCTAssertEqual(bottom, 12, accuracy: 1)
        group.click()
        XCTAssertTrue(app.buttons["管理分组…"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testDueCalendarDaysAlignWithWeekdayColumnsAndChooseDate() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        main.buttons["设置到期日"].click()
        let dates = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日.*"))
        XCTAssertTrue(dates.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(dates.count, 42)
        capture(app.popovers.firstMatch.exists ? app.popovers.firstMatch : app, name: "due-calendar-columns")
        let days = dates.allElementsBoundByIndex
        let headers = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"].map { app.staticTexts[$0].firstMatch }
        for index in 0..<42 {
            XCTAssertEqual(days[index].frame.midX, headers[index % 7].frame.midX, accuracy: 1, "Date \(index) must align with its weekday header")
        }
        for index in 1..<7 {
            XCTAssertGreaterThan(days[index].frame.midX - days[index - 1].frame.midX, 28)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        dates.matching(NSPredicate(format: "label BEGINSWITH %@", formatter.string(from: Date()))).firstMatch.click()
        let input = main.textFields["新任务"]
        input.click()
        input.typeText("QA-日历等宽日期\n")
        formatter.dateFormat = "yyyy-MM-dd"
        let expected = formatter.string(from: Date())
        expectation(for: NSPredicate { _, _ in self.sql("SELECT due_date FROM tasks WHERE title='QA-日历等宽日期'") == expected }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }

    func testHoverCapsuleRevealAndRetractionRecording() throws {
        continueAfterFailure = false
        let path = URL(fileURLWithPath: dataDirectory).appendingPathComponent("settings.json")
        let original = try Data(contentsOf: path)
        var settings = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        settings["hover_expand"] = true
        try JSONSerialization.data(withJSONObject: settings).write(to: path)
        addTeardownBlock { try original.write(to: path) }
        let app = launch()
        let main = app.dialogs["Dotist"]
        let input = main.textFields["新任务"]
        input.click()
        input.typeText("QA-横条文字和背景从同一侧展开\n")
        main.buttons["收起为悬浮球"].click()
        let bubble = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "点击展开")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _, _ in main.frame.width <= 49 && main.frame.height <= 49 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        let circle = main.frame
        let outside = main.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: -70, dy: 80))
        activate(app, showing: bubble)
        outside.hover()
        for cycle in 1...2 {
            bubble.hover()
            expectation(for: NSPredicate { _, _ in main.frame.width > 70 }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(main.frame.height, 48, accuracy: 1)
            XCTAssertLessThanOrEqual(min(abs(main.frame.minX - circle.minX), abs(main.frame.maxX - circle.maxX)), 1, "The circle must anchor the capsule")
            capture(main, name: "hover-reveal-\(cycle)")
            outside.hover()
            expectation(for: NSPredicate { _, _ in abs(main.frame.width - 48) < 1 }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
        }
        bubble.click()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
    }

    func testBubbleContextMenuOpensWithoutExpandingAndShowsMain() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        main.buttons["收起为悬浮球"].click()
        let bubble = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "点击展开")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        bubble.rightClick()
        for title in ["显示窗口", "快速添加", "任务视图", "设置…", "退出 Dotist"] {
            XCTAssertTrue(main.menuItems[title].waitForExistence(timeout: 3))
        }
        XCTAssertEqual(main.frame.width, 48, accuracy: 1)
        XCTAssertFalse(main.textFields["新任务"].exists)
        capture(app, name: "bubble-context-menu")
        main.menuItems["显示窗口"].click()
        XCTAssertTrue(main.textFields["新任务"].waitForExistence(timeout: 5))
    }

    func testCapsuleContextMenuKeepsAnchorUntilDismissed() throws {
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
        let outside = main.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: -70, dy: 80))
        outside.hover()
        bubble.hover()
        expectation(for: NSPredicate { _, _ in main.frame.width > 70 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        let frame = main.frame
        // Hit the detail bar away from the 48 pt circle.
        main.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).rightClick()
        let settingsItem = main.menuItems["设置…"]
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 3))
        settingsItem.hover()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(main.frame, frame, "Moving into the menu must keep the capsule and anchor stable")
        capture(app, name: "capsule-context-menu")
        app.typeKey(.escape, modifierFlags: [])
        activate(app, showing: bubble)
        outside.hover()
        expectation(for: NSPredicate { _, _ in abs(main.frame.width - 48) < 1 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCUIElement.perform(withKeyModifiers: .control) {
            activate(app, showing: bubble)
            bubble.click()
            XCTAssertTrue(main.menuItems["显示窗口"].waitForExistence(timeout: 3))
            app.typeKey(.escape, modifierFlags: [])
        }
        activate(app, showing: bubble)
        bubble.click()
        XCTAssertTrue(main.textFields["新任务"].waitForExistence(timeout: 5))
    }

    func testBubbleContextMenuActionsUseExistingWindowsAndSettings() throws {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        let path = URL(fileURLWithPath: dataDirectory).appendingPathComponent("settings.json")
        let original = try Data(contentsOf: path)
        let initial = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        addTeardownBlock { app.terminate(); try original.write(to: path) }
        main.buttons["收起为悬浮球"].click()
        let bubble = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "点击展开")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        for (key, off, on) in [("always_on_top", "置顶窗口", "取消置顶"), ("locked", "固定窗口", "取消固定")] {
            let enabled = initial[key] as? Bool ?? (key == "always_on_top")
            bubble.rightClick()
            let action = main.menuItems[enabled ? on : off]
            XCTAssertTrue(action.waitForExistence(timeout: 3))
            action.click()
            expectation(for: NSPredicate { _, _ in
                guard let data = try? Data(contentsOf: path), let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return settings[key] as? Bool == !enabled
            }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            bubble.rightClick()
            XCTAssertTrue(main.menuItems[enabled ? off : on].waitForExistence(timeout: 3))
            app.typeKey(.escape, modifierFlags: [])
        }
        bubble.rightClick()
        main.menuItems["快速添加"].click()
        XCTAssertTrue(app.textFields["快速添加"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        bubble.rightClick()
        main.menuItems["任务视图"].click()
        let views = app.windows["任务视图"]
        XCTAssertTrue(views.waitForExistence(timeout: 5))
        views.buttons[XCUIIdentifierCloseWindow].click()
        bubble.rightClick()
        main.menuItems["设置…"].click()
        let settings = app.windows["Dotist 设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        bubble.rightClick()
        main.menuItems["退出 Dotist"].click()
        expectation(for: NSPredicate { _, _ in app.state == .notRunning }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
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
        openTaskViews(app)
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
        openTaskViews(app)
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
        openTaskViews(app)
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

    func testBoardTaskDragChangesItsStatusThroughTheNativeTitle() {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        let title = "QA-board-drag-\(UUID().uuidString.prefix(8))"
        main.textFields["新任务"].click()
        main.textFields["新任务"].typeText(title + "\n")
        XCTAssertTrue(main.staticTexts[title].waitForExistence(timeout: 5))
        openTaskViews(app)
        let views = app.windows["任务视图"]
        XCTAssertTrue(views.waitForExistence(timeout: 6))
        segment("看板", in: views).click()
        let source = views.staticTexts[title]
        let doing = views.staticTexts["进行中"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(doing.isHittable)
        let initialX = source.frame.midX
        let destination = doing.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 100))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.25, thenDragTo: destination)
        destination.click()
        expectation(for: NSPredicate { _, _ in self.sql("SELECT status FROM tasks WHERE title='\(title)'") == "doing" }, evaluatedWith: nil)
        waitForExpectations(timeout: 6)
        XCTAssertEqual(sql("SELECT completed FROM tasks WHERE title='\(title)'"), "0")
        expectation(for: NSPredicate { _, _ in source.frame.midX > initialX + views.frame.width / 6 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(views.buttons["调整任务 " + title].exists)
        capture(views, name: "board-native-task-status-drop")
    }

    func testWeekCalendarAcceptsAnUnscheduledNativeTaskDrag() throws {
        continueAfterFailure = false
        let app = launch()
        let main = app.dialogs["Dotist"]
        if sql("SELECT COUNT(*) FROM tasks WHERE due_date IS NULL AND deleted_at IS NULL") == "0" {
            let title = "QA-week-drag-\(UUID().uuidString.prefix(8))"
            main.textFields["新任务"].click()
            main.textFields["新任务"].typeText(title + "\n")
            XCTAssertTrue(main.staticTexts[title].waitForExistence(timeout: 5))
        }
        // The first item keeps the drag source and date columns in the same viewport.
        let row = try JSONSerialization.jsonObject(with: Data(sql("SELECT json_object('id',id,'title',title) FROM tasks WHERE due_date IS NULL AND deleted_at IS NULL ORDER BY position,id LIMIT 1").utf8)) as! [String: String]
        let taskID = try XCTUnwrap(row["id"])
        let title = try XCTUnwrap(row["title"])
        XCTAssertEqual(sql("SELECT due_date IS NULL FROM tasks WHERE id='\(taskID)'"), "1")
        openTaskViews(app)
        let views = app.windows["任务视图"]
        XCTAssertTrue(views.waitForExistence(timeout: 6))
        segment("周", in: views).click()
        let days = views.groups.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日.*"))
        expectation(for: NSPredicate { _, _ in days.count == 7 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        let unscheduled = views.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "未排期 ")).firstMatch
        XCTAssertTrue(unscheduled.waitForExistence(timeout: 5))
        unscheduled.click()
        let source = views.staticTexts[title]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.hover()
        XCTAssertTrue(source.isHittable, "The unscheduled drag source must be visible")

        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: Date())
        let mondayOffset = -((calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7)
        let date = calendar.date(byAdding: .day, value: mondayOffset + 6, to: today)!
        let label = DateFormatter()
        label.calendar = calendar
        label.locale = Locale(identifier: "zh-CN")
        label.setLocalizedDateFormatFromTemplate("yyyyMMMMEEEEd")
        let column = views.groups[label.string(from: date)]
        XCTAssertTrue(column.exists)
        // Keep both ends inside the actual scrolled viewport, clear of the toolbar.
        let visible = column.frame.intersection(views.scrollViews.firstMatch.frame)
            .intersection(views.frame.insetBy(dx: 0, dy: 110))
        let geometry = XCTAttachment(string: "data=\(dataDirectory)\nid=\(taskID)\ntitle=\(title)\nsource=\(source.frame)\ncolumn=\(column.frame)\nviewport=\(views.scrollViews.firstMatch.frame)\nwindow=\(views.frame)\nintersection=\(visible)")
        geometry.name = "week-drag-fixture-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        XCTAssertGreaterThan(visible.width, 30)
        XCTAssertGreaterThan(visible.height, 60)
        let destination = views.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: visible.midX - views.frame.minX, dy: visible.midY - views.frame.minY))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.25, thenDragTo: destination)
        destination.click()
        let stored = DateFormatter()
        stored.calendar = calendar
        stored.locale = Locale(identifier: "en_US_POSIX")
        stored.dateFormat = "yyyy-MM-dd"
        expectation(for: NSPredicate { _, _ in self.sql("SELECT due_date FROM tasks WHERE id='\(taskID)'") == stored.string(from: date) }, evaluatedWith: nil)
        waitForExpectations(timeout: 6)
        XCTAssertTrue(column.frame.contains(CGPoint(x: source.frame.midX, y: source.frame.midY)))
        capture(views, name: "week-calendar-native-unscheduled-drop")
    }

    func testNativeViewSegmentsChangeCalendarAndTaskViews() {
        continueAfterFailure = false
        let app = launch()
        openTaskViews(app)
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
        openTaskViews(app)
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
        openTaskViews(app)
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
        openTaskViews(app)
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
        app.activate()
        main.textFields["新任务"].click()
        openTaskViews(app)
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
        openTaskViews(app)
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
        settings.buttons["关于"].click()
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
        settings.buttons["关于"].click()
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
        settings.buttons["关于"].click()
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
        settings.buttons["关于"].click()
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
        settings.buttons["关于"].click()
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
        settings.buttons["关于"].click()
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
