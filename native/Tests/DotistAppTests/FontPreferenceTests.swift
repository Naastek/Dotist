import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor final class FontPreferenceTests: XCTestCase {
    private var fonts: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/native-migration/fonts")
    }
    override func setUp() async throws {
        _ = NSApplication.shared
        DotistDesign.fontPreferences = .init()
        DotistDesign.registerFonts(in: fonts)
        OpticalMetrics.reset()
    }
    override func tearDown() async throws { DotistDesign.fontPreferences = .init() }

    private func axis(_ id: UInt32, of font: CTFont) throws -> CGFloat {
        let variations = CTFontCopyVariation(font) as? [NSNumber: CGFloat] ?? [:]
        if let value = variations[NSNumber(value: id)] { return value }
        // CoreText omits axes at their default value from CTFontCopyVariation.
        let axes = CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []
        let axis = axes.first { ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value == id }
        return try XCTUnwrap(axis?[kCTFontVariationAxisDefaultValueKey as String] as? CGFloat)
    }

    func testSettingsBackwardCompatibilityUnknownValuesAndSnakeCaseRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-font-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try Data(#"{"theme":"dark","font_serif_latin":"future-font","font_sans_cjk":"unknown"}"#.utf8).write(to: settingsURL)
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let initial = try store.settings()
        XCTAssertEqual(initial.fontPreferences, .init())
        XCTAssertEqual(initial.theme, "dark")
        var patch = DotistSettingsPatch()
        patch.fontSerifLatin = "source-serif-4"; patch.fontSansLatin = "system"
        patch.fontSerifCjk = "chiron-sung-hk"; patch.fontSansCjk = "system"
        let changed = try store.updateSettings(patch)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try Data(contentsOf: settingsURL)
        XCTAssertEqual(try decoder.decode(DotistSettings.self, from: data), changed)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["font_serif_latin"] as? String, "source-serif-4")
        XCTAssertEqual(object["font_sans_latin"] as? String, "system")
        XCTAssertEqual(object["font_serif_cjk"] as? String, "chiron-sung-hk")
        XCTAssertEqual(object["font_sans_cjk"] as? String, "system")
        var old = object
        for key in ["font_serif_latin", "font_sans_latin", "font_serif_cjk", "font_sans_cjk"] { old.removeValue(forKey: key) }
        XCTAssertEqual(try decoder.decode(DotistSettings.self, from: JSONSerialization.data(withJSONObject: old)).fontPreferences, .init())
        patch.fontSerifLatin = "unknown"; patch.fontSansLatin = "unknown"; patch.fontSerifCjk = "unknown"; patch.fontSansCjk = "unknown"
        XCTAssertEqual(try store.updateSettings(patch).fontPreferences, .init())
    }

    func testDefaultFamiliesWeightsOpticalSizeAndRegionalCascades() throws {
        for (serif, family, file) in [(true, "Newsreader", "Newsreader"), (false, "Atkinson Hyperlegible Next", "AtkinsonHyperlegibleNext")] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fonts.appendingPathComponent(file + ".ttf").path), "Fetch the pinned fonts before running this test")
            var names: [String] = []
            for (weight, expected): (NSFont.Weight, CGFloat) in [(.regular, 400), (.medium, 500), (.semibold, 600)] {
                let font = DotistDesign.nativeFont(13, weight: weight, serif: serif, language: "en")
                XCTAssertEqual(font.familyName, family)
                let variation = try XCTUnwrap(CTFontCopyVariation(font as CTFont) as? [NSNumber: CGFloat])
                XCTAssertEqual(try axis(0x77676874, of: font as CTFont), expected, accuracy: 0.01)
                if serif { XCTAssertEqual(try axis(0x6f70737a, of: font as CTFont), 13, accuracy: 0.01) }
                names.append(font.fontName)
                print("FONT \(family), requested=\(expected), postScript=\(font.fontName), axes=\(variation)")
                for (language, region) in [("zh-CN", "SC"), ("zh-TW", "TC"), ("zh-HK", "TC")] {
                    let localized = DotistDesign.nativeFont(13, weight: weight, serif: serif, language: language)
                    let fallback = CTFontCreateForString(localized as CTFont, "全部" as CFString, CFRange(location: 0, length: 2))
                    XCTAssertEqual(CTFontCopyFamilyName(fallback) as String, "Noto \(serif ? "Serif" : "Sans") \(region)")
                }
            }
            XCTAssertEqual(Set(names).count, 3, "Named weight instances must remain distinct")
        }
    }

    func testSelectableSourceSystemAndChironFamilies() throws {
        let source = DotistFontPreferences(serifLatin: "source-serif-4", sansLatin: "source-sans-3")
        XCTAssertEqual(DotistDesign.nativeFont(13, serif: true, language: "en", preferences: source).familyName, "Source Serif 4")
        XCTAssertEqual(DotistDesign.nativeFont(13, language: "en", preferences: source).familyName, "Source Sans 3")
        let system = DotistFontPreferences(serifLatin: "system", sansLatin: "system", serifCjk: "system", sansCjk: "system")
        XCTAssertEqual(DotistDesign.nativeFont(13, language: "en", preferences: system).familyName, NSFont.systemFont(ofSize: 13).familyName)
        XCTAssertNotEqual(DotistDesign.nativeFont(13, serif: true, language: "en", preferences: system).familyName, "Newsreader")
        for (language, expected) in [("zh-CN", "Songti SC"), ("zh-TW", "Songti TC")] {
            let font = DotistDesign.nativeFont(13, serif: true, language: language, preferences: system)
            XCTAssertEqual(CTFontCopyFamilyName(CTFontCreateForString(font as CTFont, "全部" as CFString, CFRange(location: 0, length: 2))) as String, expected)
        }
        let chiron = DotistFontPreferences(serifCjk: "chiron-sung-hk")
        for weight in [NSFont.Weight.regular, .semibold] {
            let font = DotistDesign.nativeFont(13, weight: weight, serif: true, language: "zh-TW", preferences: chiron)
            let cjk = CTFontCreateForString(font as CTFont, "全部任務" as CFString, CFRange(location: 0, length: 4))
            XCTAssertEqual(CTFontCopyFamilyName(cjk) as String, "Chiron Sung HK VF")
            XCTAssertEqual((CTFontCopyVariation(cjk) as? [NSNumber: CGFloat])?[NSNumber(value: 0x77676874)], weight == .regular ? 400 : 600)
        }
        XCTAssertEqual(DotistDesign.cjkFamilies(serif: true, region: "JP", preferences: chiron).first, "Noto Serif JP")
        XCTAssertEqual(DotistDesign.cjkFamilies(serif: true, region: "SC", preferences: chiron).first, "Noto Serif SC")
        XCTAssertEqual(DotistDesign.cjkFamilies(serif: false, region: "HK", preferences: system).first, "PingFang HK")
        XCTAssertNil(DotistDesign.familyFont("Dotist nonexistent font", size: 13, weight: .regular))
    }

    func testMissingPrimaryFontFallsBackToSourceThenRestores() throws {
        let url = fonts.appendingPathComponent("Newsreader.ttf")
        XCTAssertTrue(CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil))
        defer { DotistDesign.registerFonts(in: fonts) }
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-no-fonts-\(UUID().uuidString)")
        DotistDesign.registerFonts(in: empty)
        XCTAssertEqual(DotistDesign.nativeFont(13, serif: true, language: "en").familyName, "Source Serif 4")
    }

    func testCacheKeysDateSlotsAndImmediateModelPublication() async throws {
        let originalKey = DotistDesign.fontCacheKey
        let originalFont = DotistDesign.nativeFont(17, weight: .medium, language: "en")
        let originalWidth = TaskDateFilterMetrics.slotWidth(title: "Tomorrow", language: "en")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-font-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let published = expectation(description: "Font publication")
        let observation = DotistTypography.shared.$preferences.dropFirst().sink { value in
            if value.sansLatin == "source-sans-3" { published.fulfill() }
        }
        var patch = DotistSettingsPatch(); patch.fontSansLatin = "source-sans-3"
        await withCheckedContinuation { continuation in model.updateSettings(patch) { _ in continuation.resume() } }
        await fulfillment(of: [published], timeout: 3)
        observation.cancel()
        XCTAssertNotEqual(DotistDesign.fontCacheKey, originalKey)
        XCTAssertEqual(DotistDesign.nativeFont(17, weight: .medium, language: "en").familyName, "Source Sans 3")
        XCTAssertNotEqual(originalFont.familyName, DotistDesign.nativeFont(17, weight: .medium, language: "en").familyName)
        XCTAssertNotEqual(originalWidth, TaskDateFilterMetrics.slotWidth(title: "Tomorrow", language: "en"))
        var keys: Set<String> = []
        for role in DotistFontRole.allCases {
            for choice in role.choices {
                var change = DotistSettingsPatch(); role.set(choice, in: &change)
                let settings = try model.core.updateSettings(change)
                keys.insert(settings.fontPreferences.cacheKey)
            }
        }
        XCTAssertGreaterThan(keys.count, 4)
    }

    func testFontSettingsSearchInFourLanguages() {
        for (title, queries) in [
            ("字体", ["字体", "Fonts", "フォント", "字體"]),
            ("西文衬线", ["西文衬线", "Latin serif", "欧文セリフ", "西文襯線", "Newsreader"]),
            ("西文无衬线", ["西文无衬线", "Latin sans", "欧文サンセリフ", "西文無襯線", "Atkinson"]),
            ("中文衬线", ["中文衬线", "CJK serif", "CJKセリフ", "中文襯線", "Chiron"]),
            ("中文无衬线", ["中文无衬线", "CJK sans", "CJKサンセリフ", "中文無襯線", "PingFang"]),
            ("恢复默认字体", ["恢复默认字体", "Restore default fonts", "フォントを初期設定に戻す", "恢復預設字體"])
        ] {
            for query in queries { XCTAssertTrue(SettingsSearchIndex.matches(query).contains { $0.target == "appearance." + title }, query) }
        }
    }

    func testExistingNativeSearchAndSettingsControlsRefreshWithoutRecreation() async throws {
        let host = NSHostingView(rootView: VStack {
            SearchRow(text: .constant("Typography"), placeholder: "Search", language: "en")
            SettingsSegmentedPicker(selection: .constant("a"), options: [("a", "First"), ("b", "Second")], label: "Theme", language: "en")
        }.frame(width: 320, height: 100))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 100)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        func controls(_ view: NSView) -> [NSControl] {
            view.subviews.flatMap { child in (child as? NSControl).map { [$0] } ?? controls(child) }
        }
        let before = controls(host).filter { $0 is ComposerTextField || $0 is FocusSegmentedControl }
        XCTAssertEqual(before.count, 2)
        XCTAssertTrue(before.allSatisfy { $0.font?.familyName == "Atkinson Hyperlegible Next" })
        DotistDesign.fontPreferences = .init(sansLatin: "source-sans-3")
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        let after = controls(host).filter { $0 is ComposerTextField || $0 is FocusSegmentedControl }
        XCTAssertEqual(Set(before.map(ObjectIdentifier.init)), Set(after.map(ObjectIdentifier.init)))
        XCTAssertTrue(after.allSatisfy { $0.font?.familyName == "Source Sans 3" })
    }

    func testNativeMenuLabelCalibration() async throws {
        for choice in DotistFontRole.serifLatin.choices {
            DotistDesign.fontPreferences = .init(serifLatin: choice)
            for title in ["Inbox", "全部", "全部 work"] {
                let font = DotistDesign.nativeFont(13, weight: .semibold, serif: true, language: "en")
                let plain = OpticalText(title: title, size: 13, weight: .semibold, serif: true, language: "en").frame(width: 100, height: 24)
                let menu = Menu {} label: { ComposerGroupLabel(title: title, language: "en") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 100, height: 24)
                let content = HStack(spacing: 0) { plain; menu }.foregroundStyle(.black).frame(width: 200, height: 52).background(.white)
                let host = NSHostingView(rootView: content)
                host.frame = CGRect(x: 0, y: 0, width: 200, height: 52)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: NSScreen.main)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = host
                XCTAssertTrue(host.window === window, "Independent Menu calibration must use its native window, without a neighboring composer field")
                host.layoutSubtreeIfNeeded()
                await Task.yield()
                host.layoutSubtreeIfNeeded()
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                let scale = CGFloat(image.pixelsWide) / 200
                var centers: [CGFloat] = []
                for range in [0..<100, 100..<200] {
                    var first = image.pixelsHigh, last = -1
                    for y in 0..<image.pixelsHigh {
                        for x in Int(CGFloat(range.lowerBound) * scale)..<Int(CGFloat(range.upperBound) * scale) {
                            if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), max(color.redComponent, color.greenComponent, color.blueComponent) < 0.8 {
                                first = min(first, y); last = max(last, y)
                            }
                        }
                    }
                    XCTAssertGreaterThanOrEqual(last, first, "\(choice) \(title): each plain/menu label must render ink")
                    centers.append(CGFloat(first + last + 1) / (2 * scale))
                }
                print("Native font menu \(choice), \(title), font=\(font.fontName), plain/menu=\(centers), scale=\(scale), windowBacking=\(window.backingScaleFactor)")
                if centers.contains(where: { abs($0 - 26) > 0.5 }) || abs(centers[0] - centers[1]) > 0.5 {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-menu-\(choice)-\(title).png")
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: file)
                    print("Native menu failure capture: \(file.path)")
                }
                for center in centers { XCTAssertEqual(center, 26, accuracy: 2.0, "\(choice) \(title)") }
                XCTAssertEqual(centers[0], centers[1], accuracy: 2.0, "\(choice) \(title): plain/menu ink axes must agree")
            }
        }
    }

    func testOpticalCalibrationForEveryFontChoiceAndWeight() throws {
        var report = ["preferences,family,language,size,weight,script,offsetPt"]
        for role in DotistFontRole.allCases {
            for choice in role.choices {
                let preferences = DotistFontPreferences(serifLatin: role == .serifLatin ? choice : nil, sansLatin: role == .sansLatin ? choice : nil, serifCjk: role == .serifCjk ? choice : nil, sansCjk: role == .sansCjk ? choice : nil)
                DotistDesign.fontPreferences = preferences
                for language in ["zh-CN", "zh-TW"] {
                    for size: CGFloat in [12, 13, 17] {
                        for weight in [NSFont.Weight.regular, .medium, .semibold] {
                            for script in OpticalMetrics.Script.allCases {
                                let font = DotistDesign.nativeFont(size, weight: weight, serif: role.isSerif, language: language)
                                let measurement = OpticalMetrics.text(font, script: script)
                                report.append("\(preferences.cacheKey),\(font.familyName ?? ""),\(language),\(size),\(weight.rawValue),\(script.rawValue),\(measurement.inkOffset)")
                                let renderer = ImageRenderer(content: OpticalText(title: script.sample, size: size, weight: weight, serif: role.isSerif, language: language).foregroundStyle(.white).frame(width: 240, height: 40))
                                renderer.scale = 2
                                let bounds = try XCTUnwrap(OpticalMetrics.inkBounds(of: XCTUnwrap(renderer.cgImage)))
                                XCTAssertEqual(bounds.midY / 2, 20, accuracy: 0.5, "\(choice) \(language) \(script) \(weight)")
                            }
                        }
                    }
                }
            }
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wN4-font-optical.csv")
        try report.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        print("Font optical calibration: \(output.path), \(report.count - 1) measurements; tolerance 0.5pt")
    }
}
