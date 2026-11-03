import AppKit
import SwiftUI
import XCTest
import DotistCore
@testable import DotistApp

@MainActor
final class GroupHeaderRenderingTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
    }

    private struct FullWidthInkReference: NSViewRepresentable {
        let title: String
        let language: String
        let empty: Bool
        func makeNSView(context: Context) -> GroupHeaderInkView { GroupHeaderInkView() }
        func updateNSView(_ view: GroupHeaderInkView, context: Context) {
            view.configure(title: title, font: DotistDesign.nativeFont(15, weight: .semibold, serif: true, language: language),
                           symbol: "chevron.down", showsChevron: false,
                           titleColor: NSColor(empty ? DotistDesign.faint : DotistDesign.ink))
        }
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: GroupHeaderInkView, context: Context) -> CGSize? {
            CGSize(width: 200, height: 30)
        }
    }

    // A 2x intrinsic measurement followed by a 1x draw used to paint 工….
    // Compare actual pixels, since AX still exposed the complete title.
    func testShortTitlesPaintWholeGlyphsIn364PointMainList() async throws {
        let savedFonts = DotistDesign.fontPreferences
        defer { DotistDesign.fontPreferences = savedFonts }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-header-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addTask(title: "Header fixture", category: "work")
        var patch = DotistSettingsPatch(); patch.language = "zh-CN"
        _ = try store.updateSettings(patch)
        let model = try AppModel(store: store)
        for cjk in ["noto-serif", "system"] {
            for latin in ["newsreader", "system"] {
                DotistDesign.fontPreferences = .init(serifLatin: latin, serifCjk: cjk)
                let state = TaskPanelState(scope: "all")
                for backingScale: CGFloat in [1, 2] {
                    let fixture = NativeRenderingFixture(
                        MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {})
                            .background(Color.white).environment(\.colorScheme, .light),
                        size: CGSize(width: 364, height: 620), simulatedBackingScale: backingScale)
                    defer { fixture.close() }
                    for scale: CGFloat in [1, 2] {
                        let bitmap = try await fixture.capture(scale: scale)
                        let headers = fixture.descendants(GroupHeaderInkView.self)
                        XCTAssertFalse(headers.isEmpty, "Fixture must render the real group list")
                        XCTAssertEqual(headers.count, model.visibleGroups.count)
                        for (header, group) in zip(headers, model.visibleGroups) {
                            let reference = NativeRenderingFixture(
                                FullWidthInkReference(title: group.name, language: model.language, empty: !model.tasks.contains { $0.category == group.id })
                                    .background(Color.white).environment(\.colorScheme, .light),
                                size: CGSize(width: 200, height: 30), simulatedBackingScale: backingScale)
                            defer { reference.close() }
                            let expected = try await reference.capture(scale: scale)
                            let expectedView = try XCTUnwrap(reference.descendants(GroupHeaderInkView.self).first)
                            let frame = fixture.host.convert(header.bounds, from: header)
                            let referenceFrame = reference.host.convert(expectedView.bounds, from: expectedView)
                            let actualInk = try XCTUnwrap(inkBounds(bitmap, x: frame.minX..<(frame.minX + header.titleInkFrame.width), y: frame.minY..<frame.maxY))
                            let expectedInk = try XCTUnwrap(inkBounds(expected, x: referenceFrame.minX..<(referenceFrame.minX + expectedView.titleInkFrame.width), y: referenceFrame.minY..<referenceFrame.maxY))
                            let message = "\(group.name), \(latin)/\(cjk), backing=\(backingScale)x, draw=\(scale)x"
                            print("CONSTRAINED HEADER \(message): bounds=\(header.bounds), ink=\(actualInk), full=\(expectedInk)")
                            XCTAssertEqual(actualInk.width, expectedInk.width, accuracy: 0.5 / scale, message)
                            XCTAssertEqual(actualInk.height, expectedInk.height, accuracy: 0.5 / scale, message)
                            // An ellipsis with a similar bounding box must also fail.
                            var different = 0
                            for y in 0..<Int(expectedInk.height * scale) {
                                for x in 0..<Int(expectedInk.width * scale) {
                                    func dark(_ image: NSBitmapImageRep, _ rect: CGRect) -> Bool {
                                        guard let c = image.colorAt(x: Int(rect.minX * scale) + x, y: Int(rect.minY * scale) + y)?.usingColorSpace(.deviceRGB) else { return false }
                                        return 1 - max(c.redComponent, c.greenComponent, c.blueComponent) > 0.2
                                    }
                                    if dark(bitmap, actualInk) != dark(expected, expectedInk) { different += 1 }
                                }
                            }
                            XCTAssertEqual(different, 0, "Rendered glyph mask differs from full title: " + message)
                        }
                        if scale == 1 && backingScale == 2 && latin == "newsreader" && cjk == "noto-serif" {
                            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/dotist-header-current.png"))
                        }
                    }
                }
            }
        }
    }

    func testDisclosureSlotReservesBothDirectionsBeforeAnyAnimatedResize() throws {
        for (title, language) in [("life", "en"), ("work", "en"), ("工作 Work", "zh-CN")] {
            let view = GroupHeaderInkView()
            let font = DotistDesign.nativeFont(15, weight: .semibold, serif: true, language: language)
            var widths: [CGFloat] = []
            for (symbol, visible) in [("chevron.right", true), ("chevron.down", true), ("chevron.down", false), ("chevron.right", false)] {
                view.configure(title: title, font: font, symbol: symbol, showsChevron: visible, titleColor: .black)
                widths.append(view.intrinsicContentSize.width)
            }
            print("GROUP WIDTH \(title): right/down/hidden=\(widths); screen=\(String(describing: NSScreen.main?.backingScaleFactor))")
            for width in widths.dropFirst() {
                XCTAssertEqual(width, widths[0], accuracy: 0.01,
                               "Arrow direction/visibility must never borrow title space during a layout transaction: \(title)")
            }
        }
    }

    private final class HeaderState: ObservableObject {
        @Published var collapsed = false
        @Published var hovered = false
    }
    private struct AnimatedHeader: View {
        @ObservedObject var state: HeaderState
        let title: String
        let language: String
        var body: some View {
            VStack(spacing: 0) {
                GroupCollapseHeader(title: title, language: language, collapsed: state.collapsed, hovered: state.hovered, toggle: {})
                if !state.collapsed { Color.clear.frame(height: 32).transition(.opacity) }
            }.animation(.easeInOut(duration: 0.16), value: state.collapsed)
                .frame(maxHeight: .infinity, alignment: .top).background(Color.white).environment(\.colorScheme, .light)
        }
    }

    func testWholeTitlesRemainUnchangedThroughoutCollapseExpansionAndHover() async throws {
        for (title, language) in [("life", "en"), ("work", "en"), ("工作 Work", "zh-CN")] {
            let state = HeaderState()
            let fixture = NativeRenderingFixture(AnimatedHeader(state: state, title: title, language: language), size: CGSize(width: 320, height: 62))
            defer { fixture.close() }
            let glyphs = try XCTUnwrap(fixture.descendants(GroupHeaderInkView.self).first)
            let scale = fixture.window.backingScaleFactor
            _ = try await fixture.capture(scale: scale)
            let width = glyphs.bounds.width
            let fullTitle = glyphs.titleInkFrame
            print("GROUP ANIMATION \(title), screens=\(NSScreen.screens.count), window backing=\(scale)x, bitmap=\(scale)x; screenless backing is not Retina evidence")
            for (collapsed, hovered) in [(true, false), (false, true), (false, false), (false, true), (true, true), (false, false)] {
                withAnimation(.easeInOut(duration: 0.16)) { state.collapsed = collapsed; state.hovered = hovered }
                for delay in [0, 20, 60, 100] {
                    if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                    let bitmap = try await fixture.capture(scale: scale)
                    let frame = fixture.host.convert(glyphs.bounds, from: glyphs)
                    let pixels = try XCTUnwrap(inkBounds(bitmap, x: frame.minX..<(frame.minX + fullTitle.width)))
                    XCTAssertEqual(glyphs.bounds.width, width, accuracy: 0.01, "\(title), collapsed=\(collapsed), hover=\(hovered), delay=\(delay)")
                    XCTAssertEqual(glyphs.titleInkFrame, fullTitle, "Title must retain all glyphs, including its final letter")
                    XCTAssertEqual(pixels.width, fullTitle.width, accuracy: 0.5 / scale)
                    XCTAssertEqual(pixels.midY, 15, accuracy: 0.5 / scale)
                    if collapsed || hovered || glyphs.disclosureProgress < 1 {
                        let arrow = try XCTUnwrap(inkBounds(bitmap, x: (frame.minX + glyphs.symbolInkFrame.minX)..<(frame.minX + glyphs.symbolInkFrame.maxX)))
                        if abs(arrow.midY - pixels.midY) > 0.5 / scale {
                            print("ROTATION AXIS title=\(title), collapsed=\(collapsed), hovered=\(hovered), delay=\(delay), fraction=\(glyphs.disclosureProgress), titleFrame=\(glyphs.titleInkFrame), symbolFrame=\(glyphs.symbolInkFrame), titlePixels=\(pixels), arrowPixels=\(arrow), glyphViewFrame=\(frame)")
                            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/dotist-rotation-axis.png"))
                        }
                        XCTAssertEqual(arrow.midY, pixels.midY, accuracy: 0.5 / scale)
                    }
                }
            }
        }
    }

    /// Scan the entire height and separate only by horizontal glyph ranges.
    /// The reference axis is the complete rendered title, not its cap height,
    /// its first word, a script sample, or a standalone ImageRenderer view.
    private func inkBounds(_ image: NSBitmapImageRep, x: Range<CGFloat>, y: Range<CGFloat>? = nil) -> CGRect? {
        let scale = CGFloat(image.pixelsWide) / image.size.width
        var left = image.pixelsWide, right = -1, top = image.pixelsHigh, bottom = -1
        let rows = y.map { max(0, Int(($0.lowerBound * scale).rounded(.up)))..<min(image.pixelsHigh, Int(($0.upperBound * scale).rounded(.down))) } ?? 0..<image.pixelsHigh
        for y in rows {
            for column in max(0, Int((x.lowerBound * scale).rounded(.up)))..<min(image.pixelsWide, Int((x.upperBound * scale).rounded(.down))) {
                // Use the same visible-ink definition as OpticalAlignment and
                // PanelFeedbackRevision: RGB < .8 on the white fixture.
                guard let c = image.colorAt(x: column, y: y)?.usingColorSpace(.deviceRGB),
                      c.alphaComponent * (1 - max(c.redComponent, c.greenComponent, c.blueComponent)) > 0.2 else { continue }
                left = min(left, column); right = max(right, column)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left else { return nil }
        return CGRect(x: CGFloat(left) / scale, y: CGFloat(top) / scale,
                      width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale)
    }

    func testRealGroupHeaderWholeTitleAndChevronShareInkAxis() async throws {
        let saved = DotistDesign.fontPreferences
        defer { DotistDesign.fontPreferences = saved }
        for serif in ["newsreader", "source-serif-4", "system"] {
            // In-memory typography only; never write application settings.
            DotistDesign.fontPreferences = .init(serifLatin: serif)
            for (title, language) in [("life", "en"), ("work", "en"), ("All", "en"), ("Life gyp", "en"),
                                      ("生活", "zh-CN"), ("工作 Work", "zh-CN"), ("全部", "zh-TW"), ("仕事", "ja")] {
                for collapsed in [false, true] {
                    for hovered in [false, true] {
                        let header = GroupCollapseHeader(title: title, language: language, collapsed: collapsed,
                                                         hovered: hovered, toggle: {})
                            .background(Color.white).environment(\.colorScheme, .light)
                        let fixture = NativeRenderingFixture(header, size: CGSize(width: 320, height: 30))
                        defer { fixture.close() }
                        let glyphs = try XCTUnwrap(fixture.descendants(GroupHeaderInkView.self).first)
                        XCTAssertTrue(glyphs.window === fixture.window)
                        XCTAssertNil(glyphs.hitTest(.zero), "Native label must leave the SwiftUI collapse button interactive")
                        for scale: CGFloat in [1, 2] {
                            let image = try await fixture.capture(scale: scale)
                            let frame = fixture.host.convert(glyphs.bounds, from: glyphs)
                            let titleRange = (frame.minX + glyphs.titleInkFrame.minX)..<(frame.minX + glyphs.titleInkFrame.maxX)
                            let symbolRange = (frame.minX + glyphs.symbolInkFrame.minX)..<(frame.minX + glyphs.symbolInkFrame.maxX)
                            let titleInk = try XCTUnwrap(inkBounds(image, x: titleRange), "Window capture must contain the entire title: \(title)")
                            let message = "\(serif), \(title), \(language), collapsed=\(collapsed), hovered=\(hovered), bitmap=\(scale)x, window backing=\(fixture.window.backingScaleFactor)x, titleFrame=\(glyphs.titleInkFrame), symbolFrame=\(glyphs.symbolInkFrame)"
                            XCTAssertEqual(titleInk.width, glyphs.titleInkFrame.width, accuracy: 1 / scale, message)
                            XCTAssertEqual(titleInk.height, glyphs.titleInkFrame.height, accuracy: 1 / scale, message)
                            XCTAssertEqual(titleInk.midY, 15, accuracy: 0.5 / scale, message)
                            if collapsed || hovered {
                                let symbolInk = try XCTUnwrap(inkBounds(image, x: symbolRange), "Missing disclosure glyph: \(message)")
                                // The closest pixel-grid placement differs by at
                                // most half a pixel when ink heights have opposite parity.
                                XCTAssertEqual(symbolInk.midY, titleInk.midY, accuracy: 0.5 / scale, message)
                                if abs(symbolInk.midY - titleInk.midY) > 0.5 / scale {
                                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-group-" + UUID().uuidString + ".png")
                                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
                                    print("GROUP ACTUAL title=\(titleInk) symbol=\(symbolInk) artifact=\(url.path)")
                                }
                            } else {
                                XCTAssertNil(inkBounds(image, x: symbolRange), "Expanded, unhovered glyph remains hidden: \(message)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// Segmentation depends only on captured pixels, so this also runs against
    /// the former SwiftUI header and proves its centering defect independently
    /// of the new native view or its published geometry.
    func testDisclosureAxisFromIndependentWindowPixelSegmentation() async throws {
        let saved = DotistDesign.fontPreferences
        defer { DotistDesign.fontPreferences = saved }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-native-group-evidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var captures = ["profile,serif,title,collapsed,windowBacking,bitmapScale,drawScale,titleCenter,chevronCenter"]
        for (profileIndex, colorSpace) in [NSColorSpace.sRGB, .displayP3].enumerated() {
            for serif in ["newsreader", "source-serif-4", "system"] {
                DotistDesign.fontPreferences = .init(serifLatin: serif)
                for (title, language) in [("life", "en"), ("work", "en"), ("All", "en"), ("生活", "zh-CN"), ("仕事", "ja"), ("工作 Work", "zh-CN")] {
                    for collapsed in [false, true] {
                        let fixture = NativeRenderingFixture(
                            GroupCollapseHeader(title: title, language: language, collapsed: collapsed, hovered: true, toggle: {})
                                .background(Color.white).environment(\.colorScheme, .light), size: CGSize(width: 320, height: 30), colorSpace: colorSpace)
                        defer { fixture.close() }
                        for scale: CGFloat in [1, 2] {
                            let image = try await fixture.capture(scale: scale)
                            // The disclosure is the rightmost connected column run;
                            // the six-point gap separates it from the entire title.
                            let columns = (0..<image.pixelsWide).filter {
                                inkBounds(image, x: (CGFloat($0) / scale)..<(CGFloat($0 + 1) / scale)) != nil
                            }
                            let last = try XCTUnwrap(columns.last, "Window capture must contain title and disclosure")
                            var first = last
                            while columns.contains(first - 1) { first -= 1 }
                            let split = CGFloat(first) / scale
                            let titleInk = try XCTUnwrap(inkBounds(image, x: 0..<split), "Complete title must be nonempty")
                            let disclosure = try XCTUnwrap(inkBounds(image, x: split..<320), "Disclosure must be nonempty")
                            captures.append("\(profileIndex),\(serif),\(title),\(collapsed),\(fixture.window.backingScaleFactor),\(scale),\(fixture.lastDrawingScale.map { String(describing: $0) } ?? "cached"),\(titleInk.midY),\(disclosure.midY)")
                            if serif == "newsreader" && ["life", "work", "All"].contains(title) {
                                let name = "profile\(profileIndex)-\(title)-collapsed\(collapsed)-bitmap\(Int(scale)).png"
                                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
                            }
                            let message = "independent pixels, \(colorSpace.localizedName ?? "unknown profile"): \(serif), \(title), collapsed=\(collapsed), capture=\(scale)x, backing=\(fixture.window.backingScaleFactor)x"
                            XCTAssertEqual(titleInk.midY, 15, accuracy: 0.5, message)
                            XCTAssertEqual(disclosure.midY, 15, accuracy: 0.5, message)
                            XCTAssertEqual(disclosure.midY, titleInk.midY, accuracy: 0.5, message)
                        }
                    }
                }
            }
        }
        try captures.joined(separator: "\n").write(to: directory.appendingPathComponent("capture-scales.csv"), atomically: true, encoding: .utf8)
        print("Native group artifacts: \(directory.path); sRGB/P3 windows; screen backing=\(String(describing: NSScreen.main?.backingScaleFactor)).")
    }

    func testLongMixedTitleRemainsSingleLineAndKeepsDisclosureVisible() async throws {
        let header = GroupCollapseHeader(title: "生活と仕事 Projects gyp — a deliberately long group title", language: "ja",
                                         collapsed: true, hovered: true, toggle: {})
            .background(Color.white).environment(\.colorScheme, .light)
        let fixture = NativeRenderingFixture(header, size: CGSize(width: 160, height: 30))
        defer { fixture.close() }
        let glyphs = try XCTUnwrap(fixture.descendants(GroupHeaderInkView.self).first)
        for scale: CGFloat in [1, 2] {
            let image = try await fixture.capture(scale: scale)
            let frame = fixture.host.convert(glyphs.bounds, from: glyphs)
            XCTAssertLessThanOrEqual(frame.maxX, 128.5, "Preserve the header's 26pt trailing spacer and 6pt stack gap")
            let title = try XCTUnwrap(inkBounds(image, x: frame.minX..<(frame.minX + glyphs.titleInkFrame.maxX)))
            let symbol = try XCTUnwrap(inkBounds(image, x: (frame.minX + glyphs.symbolInkFrame.minX)..<(frame.minX + glyphs.symbolInkFrame.maxX)))
            XCTAssertEqual(title.midY, symbol.midY, accuracy: 0.5 / scale)
            XCTAssertLessThan(title.height, 30)
        }
    }
}
