import Foundation
import XCTest

final class LocalizationPunctuationTests: XCTestCase {
    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DotistApp", isDirectory: true)
    }

    private func dictionary(_ name: String) throws -> [String: [String: String]] {
        let url = sourceDirectory.appendingPathComponent("Resources/\(name).json")
        return try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url))
    }

    private func swiftSources() throws -> [String] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sourceDirectory, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
    }

    private func matches(_ pattern: String, in value: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    // Chinese prose uses fullwidth punctuation, … and ——. Buttons/titles keep
    // their existing unpunctuated endings. Chinese/Latin words and number/unit
    // pairs use one ASCII space; percentages remain attached to their number.
    // Protect technical syntax rather than changing shortcuts, URLs, versions,
    // decimals or the names of interpolation placeholders.
    private func prose(_ value: String) throws -> String {
        let technicalTokens = #"⌘,|https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+|\{[A-Za-z_][A-Za-z0-9_]*\}|\b[vV]?\d+(?:\.\d+)+\b"#
        let regex = try NSRegularExpression(pattern: technicalTokens)
        return regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "TOKEN")
    }

    private func hasHalfwidthProsePunctuation(_ value: String) throws -> Bool {
        try matches(#"[,.:;!?()]|\.\.\.|--"#, in: prose(value))
    }

    func testChineseKeysAndTraditionalChineseUseFullwidthPunctuation() throws {
        let locales = try dictionary("native-locales")
        let chinese = Set(locales.values.flatMap { $0.keys })
            .union(try XCTUnwrap(locales["zh-TW"]).values)
        for value in chinese {
            XCTAssertFalse(try hasHalfwidthProsePunctuation(value), value)
            XCTAssertFalse(try matches(#"[‘’“”]"#, in: value), "Use corner quotes: \(value)")
            XCTAssertFalse(try matches(#"\s+[，。：；！？（）、「」『』]|[，。：；！？（）、「」『』]\s+"#, in: value), value)
            XCTAssertFalse(try matches(#"[\p{Han}][A-Za-z]|[A-Za-z][\p{Han}]|[0-9][\p{Han}]"#, in: prose(value)), value)
        }
    }

    func testEnglishFrenchAndGermanUseTheirOwnPunctuation() throws {
        let locales = try dictionary("native-locales")
        for value in try XCTUnwrap(locales["en"]).values {
            XCTAssertFalse(try matches("[，。：；！？（）]", in: value), value)
            XCTAssertFalse(value.contains("..."), value)
        }
        for language in ["fr", "de"] {
            for value in try XCTUnwrap(locales[language]).values {
                XCTAssertFalse(try matches("[，。：；！？（）]", in: value), value)
            }
        }
    }

    func testTechnicalWhitelistDoesNotHideChinesePunctuationMistakes() throws {
        for value in ["说明,错误", "说明.错误", "说明:错误", "说明;错误", "说明!错误", "说明?错误", "全部(默认颜色)", "正在处理...", "第一项--第二项"] {
            XCTAssertTrue(try hasHalfwidthProsePunctuation(value), value)
        }
        for value in ["⌘, 打开设置。", "版本 2.9.6。", "等待 1.5 秒。", "打开 https://example.com/a?q=1。", "任务「{title}」。", "第一项——第二项…"] {
            XCTAssertFalse(try hasHalfwidthProsePunctuation(value), value)
        }
        XCTAssertTrue(try hasHalfwidthProsePunctuation("打开 https://example.com，说明,错误"))
    }

    func testNativeLanguagesHaveIdenticalKeysAndLiteralTranslationsRemainCovered() throws {
        let locales = try dictionary("native-locales")
        let englishKeys = Set(try XCTUnwrap(locales["en"]).keys)
        for language in ["fr", "de", "zh-TW"] {
            XCTAssertEqual(Set(try XCTUnwrap(locales[language]).keys), englishKeys, language)
        }
        let inheritedEnglishKeys = Set(try XCTUnwrap(dictionary("locales")["en"]).keys)
        let translated = englishKeys.union(inheritedEnglishKeys)
        let literal = try NSRegularExpression(pattern: #"model\.text\(\s*"((?:\\.|[^"\\])*)""#)
        var missing = Set<String>()
        for source in try swiftSources() {
            for match in literal.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let range = try XCTUnwrap(Range(match.range(at: 1), in: source))
                let key = String(source[range])
                if !translated.contains(key) { missing.insert(key) }
            }
        }
        // This acronym was the only untranslated model.text literal before
        // normalization and is identical in all supported interface languages.
        XCTAssertEqual(missing, ["MCP"])
    }

    func testRetiredKeysHaveNoRemainingSwiftReferences() throws {
        let retired = [
            "该分组的任务会移到‘无分组’(全部)里,不会被删除",
            "只移除标题里的 #标签,任务会保留",
            "各分组可在管理分组里单独设置颜色,未设置的分组使用这个默认颜色",
            "全部(默认颜色)",
            "分组未设置颜色时使用‘全部’的默认颜色",
            "新版本在退出 Dotist 时安装，重新打开后生效",
            "在任务里写 #词 就会有标签，比如：写周报 #sideproject",
            "点一天，再点另一天可选范围；按住 Shift 点击也能延伸",
            "再点一天，选出结束日期",
            "在面板上按住 ⌘ 可以左右拖动图标调整顺序",
            "先放进 Inbox，稍后再整理",
            "Inbox 是固定的收集箱",
            "需要 direction: up 或 down",
        ]
        for source in try swiftSources() {
            for key in retired { XCTAssertFalse(source.contains("\"" + key + "\""), key) }
        }
    }
}
