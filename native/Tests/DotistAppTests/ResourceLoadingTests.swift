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

    func testMissingResourceReturnsNil() {
        XCTAssertNil(AppResources.url(forResource: "dotist-resource-that-does-not-exist", withExtension: "json"))
    }
}
