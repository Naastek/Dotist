import XCTest
@testable import DotistApp

final class SettingsSearchTests: XCTestCase {
    func testAllModulesAreRegisteredAndTargetsAreUnique() {
        let entries = SettingsSearchIndex.entries
        XCTAssertEqual(Set(entries.map(\.module)), Set(SettingsModule.allCases))
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
    }
    func testEmptyWhitespaceAndUnknownQueryHaveNoResults() {
        for query in ["", "  \n\t", "no-such-setting-12345"] {
            XCTAssertTrue(SettingsSearchIndex.matches(query).isEmpty)
        }
    }
    func testTitlesMatchInAllFourLanguagesWithoutChangingInterfaceLanguage() {
        for query in ["开机启动", "Launch at login", "ログイン", "開機啟動"] {
            XCTAssertTrue(SettingsSearchIndex.matches(query).contains { $0.title == "开机启动" }, query)
        }
        for query in ["默认颜色", "default color", "デフォルトカラー", "預設顏色"] {
            XCTAssertTrue(SettingsSearchIndex.matches(query).contains { $0.title == "全部(默认颜色)" }, query)
        }
    }
    func testTokensCanMatchAcrossModuleAndSettingTitle() {
        let matches = SettingsSearchIndex.matches("  GENERAL   LANGUAGE ")
        XCTAssertEqual(matches.map(\.title), ["语言"])
        XCTAssertTrue(SettingsSearchIndex.matches("General no-such-setting").isEmpty)
        XCTAssertTrue(SettingsSearchIndex.matches("ＭＣＰ").contains { $0.module == .mcp })
    }
    func testDuplicateTitlesNavigateToTheCorrectModule() {
        XCTAssertEqual(SettingsSearchIndex.matches("Menu bar 分组").map(\.target), ["menubar.分组"])
        XCTAssertEqual(SettingsSearchIndex.matches("General 分组").map(\.target), ["general.分组"])
    }
    func testDynamicGroupsReflectAddRenameAndDeleteWithoutCachedResults() {
        let work = SettingsSearchIndex.groupEntry(id: "work", name: "仕事")
        let home = SettingsSearchIndex.groupEntry(id: "home", name: "家事")
        XCTAssertEqual(SettingsSearchIndex.matches("仕事", in: [work, home]).map(\.target), ["appearance.color-work"])
        let renamed = SettingsSearchIndex.groupEntry(id: "work", name: "Projects")
        XCTAssertTrue(SettingsSearchIndex.matches("仕事", in: [renamed, home]).isEmpty)
        XCTAssertEqual(SettingsSearchIndex.matches("group color Projects", in: [renamed, home]).map(\.id), [renamed.id])
        XCTAssertTrue(SettingsSearchIndex.matches("Projects", in: [home]).isEmpty)
    }
    func testToolbarColorAndVisibilityKeywordsAreDiscoverable() {
        for query in ["Toolbar Color", "ツールバー カラー", "工具列 顏色", "toolbar hidden"] {
            XCTAssertTrue(SettingsSearchIndex.matches(query).contains { $0.target == "toolbar.颜色" }, query)
        }
    }
}
