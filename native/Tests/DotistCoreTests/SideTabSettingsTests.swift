import Foundation
import XCTest
@testable import DotistCore

final class SideTabSettingsTests: XCTestCase {
    private func withSettings(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-side-tab-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("settings.json"))
    }

    func testLegacySettingsDefaultToEightyFiveWithoutRewritingTheFile() throws {
        try withSettings { path in
            let legacy = Data(#"{"theme":"dark","opacity":43}"#.utf8)
            try legacy.write(to: path)
            let store = try SettingsStore(path: path)
            XCTAssertEqual(store.current().sideTabOpacity, 85)
            XCTAssertEqual(store.current().opacity, 43)
            XCTAssertEqual(try Data(contentsOf: path), legacy)
        }
    }

    func testSettingsDecoderDefaultsMissingAndNullSideTabOpacity() throws {
        try withSettings { path in
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let settings = try SettingsStore(path: path).current()
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(settings)) as? [String: Any])
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            for missing in [true, false] {
                if missing { object.removeValue(forKey: "side_tab_opacity") }
                else { object["side_tab_opacity"] = NSNull() }
                let decoded = try decoder.decode(DotistSettings.self, from: JSONSerialization.data(withJSONObject: object))
                XCTAssertEqual(decoded.sideTabOpacity, 85)
                XCTAssertEqual(decoded, settings, "The custom decoder must preserve every existing preference")
            }
        }
    }

    func testPatchClampsAndPersistsOpacityIndependentlyOfPanelOpacity() throws {
        try withSettings { path in
            let store = try SettingsStore(path: path)
            for (input, expected): (UInt8, UInt8) in [(0, 0), (9, 9), (10, 10), (47, 47), (100, 100), (255, 100)] {
                var patch = DotistSettingsPatch()
                patch.sideTabOpacity = input
                let updated = try store.update(patch)
                XCTAssertEqual(updated.sideTabOpacity, expected)
                XCTAssertEqual(updated.opacity, 56)
                XCTAssertEqual(try SettingsStore(path: path).current().sideTabOpacity, expected)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
                XCTAssertEqual(object["side_tab_opacity"] as? Int, Int(expected))
                XCTAssertNil(object["sideTabOpacity"])
            }
            var unrelated = DotistSettingsPatch()
            unrelated.opacity = 32
            XCTAssertEqual(try store.update(unrelated).sideTabOpacity, 100)
        }
    }

    func testStoredOutOfRangeValuesClampWithoutRewritingOnRead() throws {
        try withSettings { path in
            for (input, expected) in [(0, 0), (255, 100)] {
                let stored = Data("{\"side_tab_opacity\":\(input)}".utf8)
                try stored.write(to: path)
                XCTAssertEqual(try SettingsStore(path: path).current().sideTabOpacity, UInt8(expected))
                XCTAssertEqual(try Data(contentsOf: path), stored)
            }
        }
    }

    func testPatchEncodesTheAgreedSnakeCaseKey() throws {
        var patch = DotistSettingsPatch()
        patch.sideTabOpacity = 64
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(patch)) as? [String: Any])
        XCTAssertEqual(object["side_tab_opacity"] as? Int, 64)
        XCTAssertEqual(object.count, 1)
    }
}
