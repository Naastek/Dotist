import Foundation
import XCTest
@testable import DotistApp

@MainActor
final class ToolbarConfigTests: XCTestCase {
    func testLegacySearchIsIgnoredWithoutLosingOrderOrVisibility() throws {
        let suite = "dotist-toolbar-wIB1-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // This is the exact enum-keyed dictionary representation produced by v1.
        let legacy = #"{"order":["collapse","search","lock","views","pin"],"visibility":["search","always","lock","hidden","views","always","pin","hidden","collapse","hover"]}"#
        defaults.set(Data(legacy.utf8), forKey: "dotist.toolbar.v1")
        let config = ToolbarConfig(defaults: defaults)
        XCTAssertEqual(config.order, [.lock, .views, .pin, .filter, .completion, .calendar, .color, .collapse])
        XCTAssertEqual(config.visibility(of: .lock), .hidden)
        XCTAssertEqual(config.visibility(of: .views), .always)
        XCTAssertEqual(config.visibility(of: .collapse), .always)
        XCTAssertEqual(config.visibility(of: .color), .hover)
        config.move(.color, onto: .collapse)
        config.setVisibility(.always, for: .color)
        let reloaded = ToolbarConfig(defaults: defaults)
        XCTAssertEqual(reloaded.order, config.order)
        XCTAssertEqual(reloaded.visibility, config.visibility)
    }

    func testStringKeyedLegacyStorageAlsoDropsRetiredItemsAndDuplicates() throws {
        let suite = "dotist-toolbar-wIB1-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"order":["lock","search","lock","views"],"visibility":{"search":"always","views":"hidden"}}"#.utf8), forKey: "dotist.toolbar.v1")
        let config = ToolbarConfig(defaults: defaults)
        XCTAssertEqual(config.order, [.lock, .views, .filter, .completion, .calendar, .pin, .color, .collapse])
        XCTAssertEqual(config.visibility(of: .views), .hidden)
    }

    func testDefaultsMoveVisibilityAndReset() {
        let suite = "dotist-toolbar-wIB1-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = ToolbarConfig(defaults: defaults)
        config.reset()
        XCTAssertEqual(config.order, [.filter, .completion, .calendar, .views, .pin, .lock, .color, .collapse])
        XCTAssertEqual(config.visibility(of: .views), .hover)
        XCTAssertEqual(config.visibility(of: .color), .hover)
        XCTAssertEqual(config.visibility(of: .collapse), .always)
        config.move(.views, onto: .lock)
        XCTAssertEqual(config.order, [.filter, .completion, .calendar, .pin, .lock, .views, .color, .collapse])
        config.move(.collapse, onto: .pin)
        XCTAssertEqual(config.order, [.filter, .completion, .calendar, .pin, .lock, .views, .color, .collapse])
        config.move(.color, onto: .collapse)
        XCTAssertEqual(config.order.last, .collapse)
        config.setVisibility(.hidden, for: .collapse)
        XCTAssertEqual(config.visibility(of: .collapse), .always)
        config.setVisibility(.always, for: .color)
        XCTAssertTrue(config.items(.always).contains(.color))
        config.reset()
        XCTAssertEqual(config.order, ToolbarConfig.defaultOrder)
        XCTAssertEqual(config.visibility, ToolbarConfig.defaultVisibility)
    }
}
