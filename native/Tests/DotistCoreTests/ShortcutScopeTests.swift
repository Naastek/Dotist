import Foundation
import XCTest
@testable import DotistCore

final class ShortcutScopeTests: XCTestCase {
    func testScopesNormalizeAndRejectActiveDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SettingsStore(path: directory.appendingPathComponent("settings.json"))
        var patch = DotistSettingsPatch()
        patch.shortcutScopes = ["toggle": "bad", "search": "off", "unknown": "global"]
        patch.searchShortcut = store.current().toggleShortcut
        let value = try store.update(patch)
        XCTAssertEqual(value.shortcutScopes, ["toggle": "global", "quickAdd": "global", "settings": "app", "views": "off", "search": "off"])
        patch.shortcutScopes = ["search": "app"]
        XCTAssertThrowsError(try store.update(patch)) { XCTAssertEqual($0.localizedDescription, "不同的动作不能使用同一个快捷键") }
    }

    private func withSettings(_ stored: [String: Any] = [:], _ check: (SettingsStore, URL, Data) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-shortcut-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.json")
        let original = try JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys])
        try original.write(to: path)
        try check(SettingsStore(path: path), path, original)
    }

    func testLegacyInjectedSearchDefaultYieldsToExplicitBindingWithoutWriting() throws {
        for binding in ["Command+K", "CommandOrControl+K"] {
            try withSettings(["toggle_shortcut": binding]) { store, path, original in
                XCTAssertEqual(store.current().toggleShortcut, binding)
                XCTAssertEqual(store.current().searchShortcut, "")
                XCTAssertEqual(store.current().shortcutScopes["search"], "app")
                XCTAssertEqual(try Data(contentsOf: path), original, "Loading must never rewrite settings")
            }
        }
    }

    func testInjectedSettingsDefaultYieldsToExplicitAliasWithoutWriting() throws {
        try withSettings(["quick_add_shortcut": "CommandOrControl+Comma"]) { store, path, original in
            XCTAssertEqual(store.current().quickAddShortcut, "CommandOrControl+Comma")
            XCTAssertEqual(store.current().settingsShortcut, "")
            XCTAssertEqual(store.current().searchShortcut, "Command+K")
            XCTAssertEqual(try Data(contentsOf: path), original)
        }
    }

    func testInjectedDefaultNeverOverridesAnExplicitModernScopeOrBinding() throws {
        try withSettings(["views_shortcut": "Alt+Command+D", "shortcut_scopes": ["views": "app", "toggle": "global"]]) { store, path, original in
            XCTAssertEqual(store.current().viewsShortcut, "Alt+Command+D")
            XCTAssertEqual(store.current().toggleShortcut, "")
            XCTAssertEqual(store.current().shortcutScopes["toggle"], "global")
            XCTAssertEqual(store.current().shortcutScopes["views"], "app")
            XCTAssertEqual(try Data(contentsOf: path), original)
        }
    }

    func testExplicitModernBindingsAreNotSilentlyReplacedByMigration() throws {
        try withSettings(["toggle_shortcut": "Command+K", "search_shortcut": "CommandOrControl+K",
                          "settings_shortcut": "Command+Comma", "shortcut_scopes": ["toggle": "app", "search": "app"]]) { store, path, original in
            XCTAssertEqual(store.current().toggleShortcut, "Command+K")
            XCTAssertEqual(store.current().searchShortcut, "CommandOrControl+K")
            XCTAssertEqual(store.current().settingsShortcut, "Command+Comma")
            XCTAssertEqual(store.current().shortcutScopes["search"], "app")
            XCTAssertEqual(try Data(contentsOf: path), original)
        }
    }

    func testPreviouslyAcceptedLegacyAliasesLoadButConflictingEditsRemainAtomic() throws {
        try withSettings(["toggle_shortcut": "CommandOrControl+Alt+D", "quick_add_shortcut": "Alt+Command+D"]) { store, path, original in
            let before = store.current()
            XCTAssertEqual(before.toggleShortcut, "CommandOrControl+Alt+D")
            XCTAssertEqual(before.quickAddShortcut, "Alt+Command+D")
            XCTAssertEqual(try Data(contentsOf: path), original)
            var patch = DotistSettingsPatch(); patch.theme = "dark"
            XCTAssertThrowsError(try store.update(patch))
            XCTAssertEqual(store.current(), before)
            XCTAssertEqual(try Data(contentsOf: path), original)
            patch.quickAddShortcut = "Control+Alt+D"
            let repaired = try store.update(patch)
            XCTAssertEqual(repaired.quickAddShortcut, "Control+Alt+D")
            XCTAssertEqual(try SettingsStore(path: path).current(), repaired)
        }
    }

    func testActiveSemanticDuplicatesRejectAtomicallyAcrossAliasesAndModifierOrder() throws {
        for binding in ["Command+Alt+D", "Alt+CommandOrControl+D", "Alt+Command+Command+D"] {
            try withSettings { store, path, original in
                let before = store.current()
                var patch = DotistSettingsPatch(); patch.searchShortcut = binding
                XCTAssertThrowsError(try store.update(patch))
                XCTAssertEqual(store.current(), before)
                XCTAssertEqual(try Data(contentsOf: path), original)
            }
        }
    }

    func testOffDuplicatesAreRetainedAndControlRemainsDistinct() throws {
        try withSettings { store, path, _ in
            var patch = DotistSettingsPatch()
            patch.searchShortcut = "Alt+Command+D"; patch.shortcutScopes = ["search": "off"]
            let disabled = try store.update(patch)
            XCTAssertEqual(disabled.searchShortcut, "Alt+Command+D")
            let disk = try Data(contentsOf: path)
            patch.shortcutScopes = ["search": "app"]
            XCTAssertThrowsError(try store.update(patch))
            XCTAssertEqual(store.current(), disabled)
            XCTAssertEqual(try Data(contentsOf: path), disk)
            patch.searchShortcut = "Alt+Control+D"
            let distinct = try store.update(patch)
            XCTAssertEqual(distinct.searchShortcut, "Alt+Control+D")
            XCTAssertEqual(try SettingsStore(path: path).current(), distinct)
        }
    }

    func testSupportedFunctionAndPunctuationAliasesConflictButDifferentKeysDoNot() throws {
        for pair in [("Alt+CommandOrControl+F20", "Command+Alt+F20"), ("Shift+CommandOrControl+Slash", "Command+Shift+Slash")] {
            try withSettings { store, path, _ in
                var patch = DotistSettingsPatch(); patch.toggleShortcut = pair.0
                let before = try store.update(patch); let disk = try Data(contentsOf: path)
                patch.searchShortcut = pair.1
                XCTAssertThrowsError(try store.update(patch))
                XCTAssertEqual(store.current(), before)
                XCTAssertEqual(try Data(contentsOf: path), disk)
                patch.searchShortcut = "Command+Shift+Backslash"
                XCTAssertNoThrow(try store.update(patch))
            }
        }
    }

}
