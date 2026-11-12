import XCTest
@testable import DotistApp

final class SettingsSearchTests: XCTestCase {
    func testAllModulesAreRegisteredAndTargetsAreUnique() {
        let entries = SettingsSearchIndex.entries
        XCTAssertEqual(Set(entries.map(\.module)), Set(SettingsModule.allCases))
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
    }
    func testEveryModuleRemainsSearchableByItsTextLabel() {
        for module in SettingsModule.allCases {
            XCTAssertTrue(SettingsSearchIndex.matches(module.title).contains { $0.module == module }, module.title)
        }
    }
    func testEmptyWhitespaceAndUnknownQueryHaveNoResults() {
        for query in ["", "  \n\t", "no-such-setting-12345"] {
            XCTAssertTrue(SettingsSearchIndex.matches(query).isEmpty)
        }
    }
    func testTitlesMatchInAllFourLanguagesWithoutChangingInterfaceLanguage() {
        for query in ["开机启动", "Launch at login", "開機啟動"] {
            XCTAssertTrue(SettingsSearchIndex.matches(query).contains { $0.title == "开机启动" }, query)
        }
        for query in ["全部", "All", "Tout", "default color"] {
            XCTAssertTrue(SettingsSearchIndex.matches(query).contains { $0.target == "appearance.全部" && $0.title == "全部" }, query)
        }
        for query in ["失焦后内容透明度", "Unfocused content transparency", "失焦後內容透明度", "Transparence du contenu lorsque la fenêtre est inactive", "Inhaltstransparenz bei inaktivem Fenster"] {
            XCTAssertTrue(SettingsSearchIndex.matches(query).contains { $0.target == "appearance.失焦后内容透明度" }, query)
        }
        for query in ["分组便签背景透明度", "Group tab background transparency", "群組便籤背景透明度"] {
            XCTAssertTrue(SettingsSearchIndex.matches(query).contains { $0.target == "appearance.分组便签背景透明度" }, query)
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
        let work = SettingsSearchIndex.groupEntry(id: "work", name: "工作")
        let home = SettingsSearchIndex.groupEntry(id: "home", name: "家事")
        XCTAssertEqual(SettingsSearchIndex.matches("工作", in: [work, home]).map(\.target), ["appearance.color-work"])
        let renamed = SettingsSearchIndex.groupEntry(id: "work", name: "Projects")
        XCTAssertTrue(SettingsSearchIndex.matches("工作", in: [renamed, home]).isEmpty)
        XCTAssertEqual(SettingsSearchIndex.matches("group color Projects", in: [renamed, home]).map(\.id), [renamed.id])
        XCTAssertTrue(SettingsSearchIndex.matches("Projects", in: [home]).isEmpty)
    }
    func testToolbarColorAndVisibilityKeywordsAreDiscoverable() {
        for query in ["Toolbar Color", "ツールバー カラー", "工具列 顏色", "toolbar hidden"] {
            XCTAssertTrue(SettingsSearchIndex.matches(query).contains { $0.target == "toolbar.颜色" }, query)
        }
    }
}
