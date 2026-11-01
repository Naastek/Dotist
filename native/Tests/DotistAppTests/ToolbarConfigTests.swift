import Foundation
import XCTest
@testable import DotistApp

@MainActor
final class ToolbarConfigTests: XCTestCase {
    func testDefaultsMoveVisibilityAndReset() {
        let defaults = UserDefaults.standard
        let key = "dotist.toolbar.v1"
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
            ToolbarConfig.shared.reset()
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        let config = ToolbarConfig.shared
        config.reset()
        XCTAssertEqual(config.order, [.views, .pin, .lock, .search, .collapse])
        XCTAssertEqual(config.visibility(of: .views), .hover)
        XCTAssertEqual(config.visibility(of: .search), .hidden)
        XCTAssertEqual(config.visibility(of: .collapse), .always)
        config.move(.views, onto: .lock)
        XCTAssertEqual(config.order, [.pin, .lock, .views, .search, .collapse])
        config.move(.collapse, onto: .pin)
        XCTAssertEqual(config.order, [.collapse, .pin, .lock, .views, .search])
        config.setVisibility(.always, for: .search)
        XCTAssertTrue(config.items(.always).contains(.search))
        config.reset()
        XCTAssertEqual(config.order, ToolbarConfig.defaultOrder)
        XCTAssertEqual(config.visibility, ToolbarConfig.defaultVisibility)
    }
}
