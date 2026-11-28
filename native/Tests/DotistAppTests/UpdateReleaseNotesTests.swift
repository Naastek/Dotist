import Foundation
import XCTest
@testable import DotistApp

final class UpdateReleaseNotesTests: XCTestCase {
    func testExtractLocalizedNotesReadsNamespacedAndUnprefixedKeys() {
        let properties: [AnyHashable: Any] = [
            "dotist:notes-en": "English notes",
            "dotist:notes-zh-CN": "简体中文说明",
            "dotist:notes-zh-TW": "繁體中文說明",
            "notes-fr": "Notes en français",
            "dotist:notes-de": "Deutsche Hinweise",
            "dotist:notes-ja": "Ignored unsupported language",
            "title": "Dotist 0.3.83"
        ]

        let extracted = NativeUpdater.extractLocalizedNotes(from: properties)
        XCTAssertEqual(Set(extracted.keys), Set(NativeUpdater.supportedNoteLanguages))
        XCTAssertEqual(extracted["en"], "English notes")
        XCTAssertEqual(extracted["zh-CN"], "简体中文说明")
        XCTAssertEqual(extracted["zh-TW"], "繁體中文說明")
        XCTAssertEqual(extracted["fr"], "Notes en français")
        XCTAssertEqual(extracted["de"], "Deutsche Hinweise")
    }

    func testResolveNotesFollowsInAppLanguageAndFallsBackSafely() {
        let localized: [String: String] = [
            "en": "English release notes",
            "zh-CN": "简体中文更新说明",
            "zh-TW": "繁體中文更新說明",
            "fr": "Notes de version en français",
            "de": "Versionshinweise auf Deutsch"
        ]

        XCTAssertEqual(NativeUpdater.resolveNotes(localized: localized, fallback: "Fallback", language: "zh-CN"), "简体中文更新说明")
        XCTAssertEqual(NativeUpdater.resolveNotes(localized: localized, fallback: "Fallback", language: "zh-Hans-CN"), "简体中文更新说明")
        XCTAssertEqual(NativeUpdater.resolveNotes(localized: localized, fallback: "Fallback", language: "zh-TW"), "繁體中文更新說明")
        XCTAssertEqual(NativeUpdater.resolveNotes(localized: localized, fallback: "Fallback", language: "zh-Hant-HK"), "繁體中文更新說明")
        XCTAssertEqual(NativeUpdater.resolveNotes(localized: localized, fallback: "Fallback", language: "fr-FR"), "Notes de version en français")
        XCTAssertEqual(NativeUpdater.resolveNotes(localized: localized, fallback: "Fallback", language: "de-DE"), "Versionshinweise auf Deutsch")
        XCTAssertEqual(NativeUpdater.resolveNotes(localized: localized, fallback: "Fallback", language: "en-US"), "English release notes")
        XCTAssertEqual(NativeUpdater.resolveNotes(localized: localized, fallback: "Fallback", language: "ja-JP"), "English release notes")

        // Backward compatibility with legacy appcast items that only carry <description>.
        XCTAssertEqual(NativeUpdater.resolveNotes(localized: [:], fallback: "Legacy description", language: "zh-CN"), "Legacy description")
    }

    func testRepositoryReleaseNotesContainAllSupportedLanguagesAndNoRetiredMaterialClaim() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let notesURL = repoRoot.appendingPathComponent("docs/release-notes.md")
        let content = try String(contentsOf: notesURL, encoding: .utf8)

        let headingRegex = try NSRegularExpression(pattern: #"^##\s+.+?<!--\s*lang:([A-Za-z0-9-]+)\s*-->\s*$"#)
        var sections: [String: [String]] = [:]
        var currentLanguage: String?
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = headingRegex.firstMatch(in: trimmed, range: range),
               let langRange = Range(match.range(at: 1), in: trimmed) {
                let lang = String(trimmed[langRange])
                XCTAssertNil(sections[lang], "Duplicate release notes section for \(lang)")
                sections[lang] = []
                currentLanguage = lang
            } else if let currentLanguage {
                sections[currentLanguage, default: []].append(line)
            }
        }

        XCTAssertEqual(Set(sections.keys), Set(NativeUpdater.supportedNoteLanguages))
        for lang in NativeUpdater.supportedNoteLanguages {
            let body = (sections[lang] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(body.isEmpty, "Release notes section for \(lang) must not be empty")
        }
        XCTAssertFalse(content.contains("悬浮球与悬浮横条继续保持独立清透水滴材质"))
    }
}
