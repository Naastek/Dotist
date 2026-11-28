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
            XCTAssertEqual(store.current().resolvedPanelMaterial, .regular)
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
                XCTAssertEqual(updated.resolvedPanelMaterial, .regular)
                XCTAssertEqual(try SettingsStore(path: path).current().sideTabOpacity, expected)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
                XCTAssertEqual(object["side_tab_opacity"] as? Int, Int(expected))
                XCTAssertNil(object["sideTabOpacity"])
                XCTAssertNil(object["opacity"])
                XCTAssertNil(object["frost"])
            }
            var unrelated = DotistSettingsPatch()
            unrelated.panelMaterial = DotistPanelMaterial.clear.rawValue
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

    func testPanelMaterialDefaultsPersistsAndInfersFromLegacySettings() throws {
        try withSettings { path in
            let fresh = try SettingsStore(path: path)
            XCTAssertEqual(fresh.current().resolvedPanelMaterial, .regular)

            var patch = DotistSettingsPatch()
            patch.panelMaterial = DotistPanelMaterial.clear.rawValue
            let updated = try fresh.update(patch)
            XCTAssertEqual(updated.resolvedPanelMaterial, .clear)
            XCTAssertEqual(try SettingsStore(path: path).current().resolvedPanelMaterial, .clear)

            // Legacy clear/ultra presets infer `.clear` without rewriting the file.
            for legacyJSON in [#"{"opacity":38,"frost":22}"#, #"{"opacity":8,"frost":4}"#, #"{"opacity":0,"frost":0}"#] {
                let data = Data(legacyJSON.utf8)
                try data.write(to: path)
                let store = try SettingsStore(path: path)
                XCTAssertEqual(store.current().resolvedPanelMaterial, .clear)
                XCTAssertEqual(try Data(contentsOf: path), data)
            }

            // Legacy standard/default values infer `.regular` without rewriting the file.
            for legacyJSON in [#"{"opacity":60,"frost":40}"#, #"{"opacity":56,"frost":35}"#, #"{"opacity":80,"frost":10}"#] {
                let data = Data(legacyJSON.utf8)
                try data.write(to: path)
                let store = try SettingsStore(path: path)
                XCTAssertEqual(store.current().resolvedPanelMaterial, .regular)
                XCTAssertEqual(try Data(contentsOf: path), data)
            }

            // Unknown panel_material falls back safely to `.regular`.
            try Data(#"{"panel_material":"unknown-style"}"#.utf8).write(to: path)
            XCTAssertEqual(try SettingsStore(path: path).current().resolvedPanelMaterial, .regular)
        }
    }
}
