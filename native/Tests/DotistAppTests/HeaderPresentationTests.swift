import AppKit
import SwiftUI
import XCTest
import DotistCore
@testable import DotistApp

@MainActor
final class HeaderPresentationTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        addTeardownBlock { await MainActor.run { NSApp.accessibilitySetValue(previous, forAttribute: attribute) } }
    }

    private func mainWindow(presentation: HeaderPresentation? = nil, primary: Bool = false, language: String = "en", groupName: String = "Side project · 项目管理") throws -> MainWindow {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "header-host-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        var settings = DotistSettingsPatch(); settings.language = language
        _ = try store.updateSettings(settings)
        let group = try store.addGroup(name: groupName)
        let config = ToolbarConfig(defaults: defaults)
        for item in ToolbarItem.allCases { config.setVisibility(.always, for: item) }
        return MainWindow(model: try AppModel(store: store), state: TaskPanelState(groupID: group.id, scope: "all"),
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, close: {}, primary: primary,
            toolbarConfig: config, headerPresentation: presentation ?? HeaderPresentation())
    }

    private func axElements(_ root: NSObject, id: String) -> [NSObject] {
        let own = (root as? any NSAccessibilityElementProtocol)?.accessibilityIdentifier?() == id ? [root] : []
        let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        guard root.responds(to: selector), let children = root.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return own }
        return own + children.flatMap { axElements($0, id: id) }
    }

    func testClustersKeepEveryControlInsidePrimaryAndSecondaryPanels() async throws {
        for primary in [true, false] {
            let view = try mainWindow(primary: primary)
            for width in [primary ? 408.0 : 432.0, 620.0] {
                let fixture = NativeRenderingFixture(view, size: CGSize(width: width, height: 400))
                defer { fixture.close() }
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertFalse(fixture.window.isVisible)
                XCTAssertTrue(axElements(fixture.host, id: "toolbar-overflow").isEmpty)
                var frames: [CGRect] = []
                let ids = ["unified-filter", "date-filter-current", "toolbar:views", "toolbar:color", "toolbar:pin", "toolbar:lock", "toolbar:collapse"] + (primary ? [] : ["filter-group", "toolbar:close"])
                for id in ids {
                    let object = try XCTUnwrap(axElements(fixture.host, id: id).first, id)
                    let element = try XCTUnwrap(object as? any NSAccessibilityElementProtocol)
                    let frame = fixture.host.convert(fixture.window.convertFromScreen(element.accessibilityFrame()), from: nil)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0, id)
                    XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, id)
                    XCTAssertGreaterThanOrEqual(frame.height, 24, id)
                    XCTAssertGreaterThanOrEqual(frame.width, 24, id)
                    for other in frames { XCTAssertTrue(frame.intersection(other).isEmpty, id) }
                    frames.append(frame)
                }
                if primary {
                    XCTAssertTrue(axElements(fixture.host, id: "filter-group").isEmpty)
                    continue
                }
                let group = try XCTUnwrap(fixture.descendants(HeaderMenuButton.Button.self).first)
                XCTAssertEqual(group.focusRingType, .none)
                XCTAssertEqual((group.cell as? NSButtonCell)?.lineBreakMode, .byTruncatingTail)
            }
        }
    }

    func testMainWindowManagerRoundTripDismissesColor() async throws {
        let presentation = HeaderPresentation()
        let view = try mainWindow(presentation: presentation)
        let fixture = NativeRenderingFixture(view, size: CGSize(width: 364, height: 620))
        defer { fixture.close() }
        for tags in [true, false] {
            presentation.active = .color
            try await Task.sleep(for: .milliseconds(80))
            if tags { presentation.manageTags = true } else { presentation.manageGroups = true }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil(presentation.active)
            XCTAssertTrue(fixture.descendants(HeaderMenuButton.Button.self).filter { $0.accessibilityIdentifier() == "filter-group" }.isEmpty)
            presentation.manageTags = false
            presentation.manageGroups = false
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil(presentation.active)
            XCTAssertNotNil(fixture.descendants(HeaderMenuButton.Button.self).first { $0.accessibilityIdentifier() == "filter-group" })
            XCTAssertFalse(fixture.window.isVisible)
        }
    }

    func testDateReordersAcrossAllToolbarControls() throws {
        let view = try mainWindow()
        XCTAssertTrue(view.windowToolbarItems.contains(.filter))
        for item in view.windowToolbarItems {
            let items = view.reorderItems(for: item)
            var session = ToolbarDragSession(item: item, items: items)
            session.translation = -1000
            XCTAssertEqual(items[session.target], items.first)
            session.translation = 1000
            XCTAssertEqual(items[session.target], items.last)
            XCTAssertEqual(items, view.windowToolbarItems)
        }
    }

    func testHiddenWindowControlsAreRemovedWithoutOverflow() throws {
        let view = try mainWindow()
        for item in view.windowToolbarItems { view.toolbarConfig.setVisibility(.hidden, for: item) }
        XCTAssertTrue(view.windowToolbarItems.isEmpty)
    }

    func testReportedLegacyMenuTriggerCollapsesOffscreen() async throws {
        _ = NSApplication.shared
        let fixture = NativeRenderingFixture(Menu { Button("颜色") {} } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 28)
        }.menuStyle(.borderlessButton), size: CGSize(width: 60, height: 44))
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        func find(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("SwiftUIPopupButton") { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        let trigger = try XCTUnwrap(find(fixture.host))
        XCTAssertLessThan(trigger.bounds.height, 28)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testReplacementIgnoresDismissalFromPreviousPopoverAndManagerDismissesAll() {
        let presentation = HeaderPresentation()
        for first in [HeaderPopover.filters, .calendar, .color] {
            presentation.set(first, presented: true)
            XCTAssertEqual(presentation.active, first)
            let second: HeaderPopover = first == .color ? .calendar : .color
            presentation.set(second, presented: true)
            presentation.set(first, presented: false)
            XCTAssertEqual(presentation.active, second)
            presentation.dismiss()
            XCTAssertNil(presentation.active)
        }
    }

    func testNativeMenuButtonHasFullHitAreaAndLocalizedLabelWithoutIndicator() async throws {
        _ = NSApplication.shared
        let fixture = NativeRenderingFixture(
            HeaderMenuButton(title: "更多操作", symbol: "ellipsis", identifier: "toolbar-overflow", menu: { NSMenu() })
                .frame(width: 28, height: 28), size: CGSize(width: 28, height: 28))
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let button = try XCTUnwrap(buttons(fixture.host).first)
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertEqual(button.bounds.size, CGSize(width: 28, height: 24))
        XCTAssertEqual(button.accessibilityLabel(), "更多操作")
        XCTAssertNotNil(button.hitTest(button.convert(NSPoint(x: 14, y: 1), to: button.superview)))
        XCTAssertNotNil(button.hitTest(button.convert(NSPoint(x: 14, y: 23), to: button.superview)))
    }
}

extension HeaderPresentationTests {
    func testArgonLayoutEvidence() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOTIST_ARGON_EVIDENCE"] ?? "/tmp/dotist-argon-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        XCTAssertEqual(BubbleFilterSummary.lines(["Group", "Date", "#tag", "Open"]), ["Group · Date", "#tag · Open"])
        for dark in [false, true] {
            for width in [432.0, 620.0] {
                let view = try mainWindow()
                view.state.activeTag = "planning-long-tag-name"
                view.state.scope = "next7"
                view.state.hideCompleted = true
                let fixture = NativeRenderingFixture(view.environment(\.colorScheme, dark ? .dark : .light), size: CGSize(width: width, height: 400))
                defer { fixture.close() }
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertFalse(fixture.window.isVisible)
                let group = try XCTUnwrap(fixture.descendants(HeaderMenuButton.Button.self).first { $0.accessibilityIdentifier() == "filter-group" })
                XCTAssertEqual(group.focusRingType, .none)
                let bitmap = try await fixture.capture(scale: 2)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("panel-\(Int(width))-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

extension HeaderPresentationTests {
    func testAcceptedWidthsWithInlineDatesAndReadableGroups() async throws {
        var evidence: [[String: Any]] = []
        for primary in [true, false] {
            for language in ["en", "zh-CN"] {
                for title in [language == "en" ? "Personal" : "个人事务", "Side project · 项目管理"] {
                    for scope in ["all", "tomorrow", "next7", "custom", "crossyear"] {
                        let view = try mainWindow(primary: primary, language: language, groupName: title)
                        if scope == "custom" || scope == "crossyear" {
                            view.state.customStart = scope == "custom" ? "2026-11-15" : "2026-12-28"
                            view.state.customEnd = scope == "custom" ? "2026-12-20" : "2027-01-03"
                        } else { view.state.scope = scope }
                        let width = primary ? 408.0 : 432.0
                        let fixture = NativeRenderingFixture(view.header, size: CGSize(width: width, height: 44))
                        defer { fixture.close() }
                        try await Task.sleep(for: .milliseconds(40))
                        XCTAssertFalse(fixture.window.isVisible)
                        var frames: [CGRect] = []
                        let active = scope != "all"
                        let dateID = "date-filter-current"
                        let ids = ["unified-filter", "date-filter-current", "toolbar:views", "toolbar:color", "toolbar:pin", "toolbar:lock", "toolbar:collapse"] + (primary ? [] : ["filter-group", "toolbar:close"]) + (active ? [dateID + ":clear"] : [])
                        for id in ids {
                            let object = try XCTUnwrap(axElements(fixture.host, id: id).first, id)
                            let ax = try XCTUnwrap(object as? any NSAccessibilityElementProtocol)
                            let frame = fixture.host.convert(fixture.window.convertFromScreen(ax.accessibilityFrame()), from: nil)
                            XCTAssertGreaterThanOrEqual(frame.minX, 0, id)
                            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, id)
                            XCTAssertGreaterThanOrEqual(frame.minY, 0, id)
                            XCTAssertLessThanOrEqual(frame.maxY, 44.5, id)
                            XCTAssertGreaterThanOrEqual(frame.width, id.hasSuffix(":clear") ? 14 : 24, id)
                            XCTAssertGreaterThanOrEqual(frame.height, 24, id)
                            for other in frames { XCTAssertTrue(frame.intersection(other).isEmpty, id) }
                            frames.append(frame)
                        }
                        XCTAssertTrue(axElements(fixture.host, id: "toolbar:calendar").isEmpty)
                        if primary {
                            XCTAssertTrue(axElements(fixture.host, id: "filter-group").isEmpty)
                            evidence.append(["primary": primary, "language": language, "scope": scope, "width": width])
                            continue
                        }
                        let group = try XCTUnwrap(fixture.descendants(HeaderMenuButton.Button.self).first)
                        let textRect = try XCTUnwrap(group.cell).titleRect(forBounds: group.bounds)
                        if !title.contains("Side") {
                            let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
                            XCTAssertGreaterThanOrEqual(textRect.width + 0.5, textWidth, "\(primary) \(language) \(scope)")
                        } else { XCTAssertGreaterThan(textRect.width, 40) }
                        evidence.append(["primary": primary, "language": language, "title": title, "scope": scope, "width": width, "groupTextWidth": textRect.width])
                    }
                }
            }
        }
        let path = ProcessInfo.processInfo.environment["DOTIST_LAYOUT_EVIDENCE"] ?? "/tmp/dotist-layout-evidence"
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("header-matrix.json"))
    }

    func testCompactDateFormatsAndClearPreservesOtherFilters() throws {
        XCTAssertEqual(HeaderDateLabel.compact(start: "2026-11-15", end: "2026-11-20"), "11/15–20")
        XCTAssertEqual(HeaderDateLabel.compact(start: "2026-11-15", end: "2026-12-20"), "11/15–12/20")
        XCTAssertEqual(HeaderDateLabel.compact(start: "2026-12-28", end: "2027-01-03"), "26/12/28–27/01/03")
        let view = try mainWindow()
        let group = view.state.groupID
        view.state.activeTag = "planning"; view.state.hideCompleted = true
        view.state.customStart = "2026-12-28"; view.state.customEnd = "2027-01-03"
        view.clearDateFilter()
        XCTAssertEqual(view.state.scope, "all")
        XCTAssertNil(view.state.customStart); XCTAssertNil(view.state.customEnd)
        XCTAssertEqual(view.state.groupID, group)
        XCTAssertEqual(view.state.activeTag, "planning"); XCTAssertTrue(view.state.hideCompleted)
    }
}
