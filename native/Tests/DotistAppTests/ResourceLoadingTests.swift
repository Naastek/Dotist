import Foundation
import XCTest
@testable import DotistApp

final class ResourceLoadingTests: XCTestCase {
    func testLocalizationResourcesAreAvailableAndDecodable() throws {
        for name in ["locales", "native-locales"] {
            let url = try XCTUnwrap(AppResources.url(forResource: name, withExtension: "json"))
            let dictionary = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url))
            XCTAssertFalse(dictionary.isEmpty, name)
        }
    }

    func testSettingsSidebarSVGIconsAreAvailableAndParseable() throws {
        for module in SettingsModule.allCases {
            let url = try XCTUnwrap(AppResources.url(forResource: module.iconResourceName, withExtension: "svg"), module.rawValue)
            let data = try Data(contentsOf: url)
            let document = try XCTUnwrap(SVGIconDocument.parse(data: data), module.rawValue)
            XCTAssertFalse(document.elements.isEmpty, module.rawValue)
            XCTAssertGreaterThan(document.viewBox.width, 0, module.rawValue)
            XCTAssertGreaterThan(document.viewBox.height, 0, module.rawValue)
        }
    }

    func testMissingResourceReturnsNil() {
        XCTAssertNil(AppResources.url(forResource: "dotist-resource-that-does-not-exist", withExtension: "json"))
    }
}
