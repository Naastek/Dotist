import AppKit
import SwiftUI
import XCTest
@testable import DotistApp

/// Every test captures separate horizontal masks (no glass, backgrounds or
/// shadows in the mask). Occupied pixel rows use RGB < .8 and alpha > .1;
/// center = (first + last + 1) / (2 * pixelsPerPoint). This is the ink bounding
/// box midpoint, not the shape's area centroid. Baseline calibration measures
/// uncorrected views before asserting corrected components, on the real fonts.
@MainActor final class OpticalAlignmentTests: XCTestCase {
    private var nativeWindows: [NSWindow] = []
    override func tearDown() async throws {
        for window in nativeWindows { window.makeFirstResponder(nil); window.close() }
        nativeWindows.removeAll()
    }
    override func setUp() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
        OpticalMetrics.reset()
    }

    func inkVerticalCenter(of image: NSBitmapImageRep, in rect: CGRect) throws -> CGFloat {
        let scale = CGFloat(image.pixelsWide) / image.size.width
        var first = image.pixelsHigh, last = -1
        for y in max(0, Int(rect.minY * scale))..<min(image.pixelsHigh, Int(rect.maxY * scale)) {
            for x in max(0, Int(rect.minX * scale))..<min(image.pixelsWide, Int(rect.maxX * scale)) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.1 && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.8 {
                    first = min(first, y); last = max(last, y)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(last, first, "No ink in \(rect)")
        return CGFloat(first + last + 1) / (2 * scale)
    }
    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).foregroundStyle(.black).background(.white).environment(\.colorScheme, .light))
        renderer.scale = scale
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        rep.size = CGSize(width: width, height: height)
        return rep
    }
    private func native<V: View>(_ view: V, width: CGFloat, height: CGFloat) async throws -> (NSBitmapImageRep, NSHostingView<some View>) {
        let host = NSHostingView(rootView: view.frame(width: width, height: height).foregroundStyle(.black).background(.white).environment(\.colorScheme, .light))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        nativeWindows.append(window)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        rep.size = host.bounds.size
        return (rep, host)
    }
    private func aligned(_ rep: NSBitmapImageRep, ranges: [Range<CGFloat>], center: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        var centers: [CGFloat] = []
        for range in ranges {
            let measured = try inkVerticalCenter(of: rep, in: CGRect(x: range.lowerBound, y: 0, width: range.upperBound - range.lowerBound, height: rep.size.height))
            centers.append(measured)
            XCTAssertEqual(measured, center, accuracy: 0.5, "ink axis \(range)", file: file, line: line)
        }
        if let first = centers.min(), let last = centers.max() {
            XCTAssertLessThanOrEqual(last - first, 0.5, "Pairwise icon/text difference: \(centers)", file: file, line: line)
        }
    }

    func testMeasuredCalibrationTableAndCorrectedFonts() throws {
        var rows = ["family,size,weight,script,inkOffsetPt,correctionPt"]
        for serif in [false, true] {
            for size: CGFloat in [10, 11, 12, 13, 14, 15, 16, 20, 22] {
                for weight in [NSFont.Weight.regular, .medium, .semibold] {
                    for script in OpticalMetrics.Script.allCases {
                        let font = DotistDesign.nativeFont(size, weight: weight, serif: serif, language: "zh-CN")
                        let measurement = OpticalMetrics.text(font, script: script)
                        rows.append("\(serif ? "Serif" : "Sans"),\(size),\(weight.rawValue),\(script.rawValue),\(measurement.inkOffset),\(measurement.correction)")
                        let image = try render(OpticalText(title: script.sample, size: size, weight: weight, serif: serif, language: "zh-CN"), width: 220, height: 40)
                        try aligned(image, ranges: [0..<220], center: 20)
                    }
                }
            }
        }
        for name in ["chevron.down", "chevron.right", "chevron.left", "calendar", "plus", "xmark", "ellipsis", "pin", "pin.fill", "lock.open", "lock.fill", "rectangle.split.2x1", "arrow.down.right.and.arrow.up.left", "magnifyingglass", "checkmark"] {
            for size: CGFloat in [7.5, 8, 9, 10, 11, 12, 13, 14] {
                var weights: [(Font.Weight, String)] = [(.regular, "regular")]
                if name.hasPrefix("chevron") { weights.append((.semibold, "semibold")) }
                if name == "checkmark" { weights += [(.bold, "bold"), (.heavy, "heavy")] }
                for (weight, label) in weights {
                    let measurement = OpticalMetrics.symbol(name, size: size, weight: weight)
                    rows.append("SF:\(name),\(size),\(label),symbol,\(measurement.inkOffset),\(measurement.correction)")
                }
            }
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wK1-optical-metrics.csv")
        try rows.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
        print("Measured optical table: \(path.path), \(rows.count - 1) profiles")
    }


    func testBeforeAndAfterDisclosureInkDifference() throws {
        let font = DotistDesign.nativeFont(12, language: "zh-CN")
        for title in ["已完成", "接下来 7 天"] {
            // This fixture intentionally preserves the pre-fix implementation:
            // 12pt inherited symbol font and layout-box center alignment.
            let previous = HStack(spacing: 8) {
                Image(systemName: "chevron.right").offset(x: -1).frame(width: 18)
                Text(title)
            }.font(Font(font)).frame(maxWidth: .infinity, alignment: .leading)
            let before = try render(previous, width: 220, height: 28)
            let arrow = try inkVerticalCenter(of: before, in: CGRect(x: 0, y: 0, width: 18, height: 28))
            let text = try inkVerticalCenter(of: before, in: CGRect(x: 26, y: 0, width: 194, height: 28))
            let after = try render(DisclosureRow(title: title, expanded: false, language: "zh-CN").frame(maxWidth: .infinity, alignment: .leading), width: 220, height: 28)
            try aligned(after, ranges: [0..<18, 26..<220], center: 14)
            print("Disclosure pre-correction \(title): icon=\(arrow), text=\(text), difference=\(arrow - text) pt; corrected <=0.5 pt")
        }
    }

    func testLocalizedLabelsAndSideTabs() throws {
        for (language, title) in [("en", "Completed"), ("zh-CN", "已完成"), ("zh-TW", "已完成"), ("ja", "完了")] {
            for expanded in [false, true] {
                let row = try render(DisclosureRow(title: title, expanded: expanded, language: language).frame(maxWidth: .infinity, alignment: .leading), width: 220, height: 28)
                try aligned(row, ranges: [0..<18, 26..<220], center: 14)
            }
            for selected in [false, true] {
                for right in [false, true] {
                    let label = SideTabLabel(name: title, language: language, selected: selected, hovered: false, right: right, width: 120, fullWidth: 120, textOpacity: 1)
                    let image = try render(label, width: 120, height: SideTabGeometry.height)
                    try aligned(image, ranges: [0..<120], center: SideTabGeometry.height / 2)
                }
            }
        }
    }

    func testDisclosureRows() throws {
        for title in ["已完成", "接下来 7 天", "Completed", "Upcoming", "完了", "已完成"] {
            for expanded in [false, true] {
                let rep = try render(DisclosureRow(title: title, expanded: expanded, language: "zh-CN").frame(maxWidth: .infinity, alignment: .leading), width: 220, height: 28)
                try aligned(rep, ranges: [0..<18, 26..<220], center: 14)
            }
        }
    }
    func testGroupHeaderAndHoverButton() throws {
        let header = OpticalText(title: "工作 Projects", size: 15, weight: .semibold, serif: true, language: "zh-CN")
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 30)
            .overlay(alignment: .trailing) { OpticalSymbol(name: "plus", size: 11).frame(width: 22, height: 22) }
            .padding(.top, 4)
        let rep = try render(header, width: 332, height: 34)
        try aligned(rep, ranges: [0..<200, 310..<332], center: 19)
    }
    func testTaskRowsDepthZeroThroughFour() throws {
        for depth in 0...4 {
            let row = TaskRowLayout(depth: depth) {
                TaskCheckmark(depth: depth, completed: false, children: [], emphasized: false)
                OpticalText(title: "任务正文", size: 13, language: "zh-CN").frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                IconTextRow { OpticalText(title: "明天", size: 12, language: "zh-CN"); OpticalText(title: "1/3", size: 12, language: "zh-CN") }
            }
            let height = TaskRowMetrics.height(depth, titleHeight: 20)
            let rep = try render(row, width: 332, height: height)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/dotist-wK1-row-\(depth).png"))
            let circle = TaskRowMetrics.circleX(depth) - 16
            let text = TaskRowMetrics.textX(depth) - 16
            try aligned(rep, ranges: [circle..<(circle + 17), text..<(text + 65), 270..<332], center: height / 2)
        }
    }
    func testUndoAndToolbarSymbols() throws {
        let row = IconTextRow {
            OpticalText(title: "已删除任务", size: 13, language: "zh-CN").frame(width: 140)
            OpticalText(title: "撤销", size: 13, weight: .medium, language: "zh-CN").frame(width: 40)
            OpticalSymbol(name: "xmark", size: 11).frame(width: 22, height: 22)
        }
        let rep = try render(row, width: 218, height: 36)
        try aligned(rep, ranges: [0..<140, 148..<188, 196..<218], center: 18)
        for name in ["pin", "pin.fill", "lock.open", "lock.fill", "rectangle.split.2x1", "arrow.down.right.and.arrow.up.left", "ellipsis"] {
            for scale: CGFloat in [1, 2] {
                let icon = try render(OpticalSymbol(name: name, size: 14).frame(width: 28, height: 28), width: 28, height: 28, scale: scale)
                try aligned(icon, ranges: [0..<28], center: 14)
            }
        }
    }
    func testComposerAndCommandSearchNativeMasks() async throws {
        let composer = ComposerLayout {
            Menu {} label: { ComposerGroupLabel(title: "Inbox", language: "zh-CN") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height: 24)
            ComposerInput(text: .constant(""), focused: .constant(false), placeholder: "写下一件小事", label: "新任务", font: DotistDesign.nativeFont(13, language: "zh-CN"), commit: {}, navigate: { _ in false }, complete: { _ in false }).frame(height: 24)
            ComposerCalendarIcon()
        }.padding(.leading, 16).padding(.trailing, 11)
        let (rep, _) = try await native(composer, width: 364, height: 52)
        try aligned(rep, ranges: [16..<64, 90..<250, 330..<351], center: 26)
        for size: CGFloat in [13, 16] {
            let (search, searchHost) = try await native(SearchRow(text: .constant(""), placeholder: "搜索任务", language: "zh-CN", size: size, iconSize: 14).padding(.horizontal, 12), width: 320, height: 44)
            func fields(_ view: NSView) -> [NSTextField] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields($0) } }
            for field in fields(searchHost) {
                print("SEARCH size=\(size), bounds=\(field.bounds), drawing=\(field.cell!.drawingRect(forBounds: field.bounds)), baseline=\(NSLayoutManager().defaultBaselineOffset(for: field.font!)), lineHeight=\(NSLayoutManager().defaultLineHeight(for: field.font!)), geometry=\(TextLineGeometry(font: field.font!, in: field.bounds))")
            }
            try search.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/dotist-wK1-search-\(size).png"))
            print("Search ink size=\(size): icon=\(try inkVerticalCenter(of: search, in: CGRect(x: 12, y: 0, width: 20, height: 44))), text=\(try inkVerticalCenter(of: search, in: CGRect(x: 44, y: 0, width: 176, height: 44)))")
            try aligned(search, ranges: [12..<32, 44..<220], center: 22)
        }
    }
    func testSettingsLabelAndNativeControlsLayout() async throws {
        let row = SettingsFormRow(title: "窗口置顶", language: "zh-CN") {
            Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        let (rep, host) = try await native(row, width: 420, height: 44)
        try aligned(rep, ranges: [14..<150], center: 22)
        // Native switch/menu/slider/segment surfaces may be composited out of
        // cacheDisplay. Their alignment frame, not a guessed pixel offset, is
        // the fallback assertion; pure SwiftUI glyph masks never skip.
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let controls = descendants(host).compactMap { $0 as? NSSwitch }
        for control in controls {
            let frame = host.convert(control.alignmentRect(forFrame: control.frame), from: control.superview)
            XCTAssertEqual(frame.midY, 22, accuracy: 0.5)
        }
        print("Native switch frame assertions: \(controls.count)")
    }

    func testNativeEditingQuickAddAndDragPreview() async throws {
        for title in ["任务内容", "Projects", "Inbox"] {
            let font = DotistDesign.nativeFont(13, language: "zh-CN")
            let (editing, editHost) = try await native(TaskEditor(text: .constant(title), height: .constant(20), font: font, label: title, commit: {}, cancel: {}, indent: { _ in }, blur: {}), width: 200, height: 20)
            // Match the native host's actual backing scale; comparing 1x native
            // rasterization to 2x SwiftUI adds an unrelated half-pixel rounding.
            let scale = CGFloat(editing.pixelsWide) / editing.size.width
            let reading = try render(OpticalText(title: title, size: 13, language: "zh-CN"), width: 200, height: 20, scale: scale)
            let readCenter = try inkVerticalCenter(of: reading, in: CGRect(x: 0, y: 0, width: 200, height: 20))
            let editCenter = try inkVerticalCenter(of: editing, in: CGRect(x: 0, y: 0, width: 200, height: 20))
            func editors(_ view: NSView) -> [TaskTextView] { view.subviews.flatMap { ($0 as? TaskTextView).map { [$0] } ?? editors($0) } }
            for editor in editors(editHost) {
                let glyph = editor.layoutManager!.location(forGlyphAt: 0)
                print("EDITOR \(title): geometry=\(TextLineGeometry(font: font, in: CGRect(x: 0, y: 0, width: 200, height: 20), sample: title)), glyph=\(glyph), origin=\(editor.textContainerOrigin), read=\(readCenter), edit=\(editCenter)")
            }
            XCTAssertEqual(readCenter, editCenter, accuracy: 0.5, "Reading/editing: \(title)")
        }
        for title in ["写下一件小事", "Inbox"] {
            let (quick, _) = try await native(QuickInput(text: .constant(""), placeholder: title, label: title, font: DotistDesign.nativeFont(22, language: "zh-CN"), commit: {}, cancel: {}, cycle: { _ in }), width: 300, height: 30)
            try aligned(quick, ranges: [0..<300], center: 15)
        }
        for size: CGFloat in [11, 12, 14] {
            let preview = TaskDragPreview.image(title: "任务正文", font: DotistDesign.nativeFont(size, language: "zh-CN"))
            let rep = try render(Image(nsImage: preview), width: preview.size.width, height: 32)
            try aligned(rep, ranges: [0..<18, 26..<preview.size.width], center: 16)
        }
    }


    func testNativeFieldFocusPreservesTextBaseline() async throws {
        for title in ["任务内容", "Projects"] {
            let (before, host) = try await native(ComposerInput(text: .constant(title), focused: .constant(false), placeholder: "写下一件小事", label: "新任务", font: DotistDesign.nativeFont(13, language: "zh-CN"), commit: {}, navigate: { _ in false }, complete: { _ in false }), width: 200, height: 24)
            func fields(_ view: NSView) -> [ComposerTextField] { view.subviews.flatMap { ($0 as? ComposerTextField).map { [$0] } ?? fields($0) } }
            let field = try XCTUnwrap(fields(host).first)
            let window = try XCTUnwrap(host.window)
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? ComposerFieldEditor)
            editor.insertionPointColor = .clear
            editor.setSelectedRange(NSRange(location: (title as NSString).length, length: 0))
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            let after = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: after)
            after.size = host.bounds.size
            let mask = CGRect(x: 0, y: 0, width: 38, height: 24)
            let a = try inkVerticalCenter(of: before, in: mask)
            let b = try inkVerticalCenter(of: after, in: mask)
            print("Native focus \(title): before=\(a), after=\(b), editor frame=\(editor.frame)")
            XCTAssertEqual(a, b, accuracy: 0.5, title)
        }
    }

    func testMenuSliderSegmentFramesOnSettingsAxis() async throws {
        var frames: [String: CGRect] = [:]
        func frame<V: View>(_ id: String, _ view: V) -> some View {
            view.background(GeometryReader { proxy in Color.clear.preference(key: OpticalControlRectKey.self, value: [id: proxy.frame(in: .named("optical-controls"))]) })
        }
        let matrix = VStack(spacing: 0) {
            SettingsFormRow(title: "开关标签", language: "zh-CN") { frame("switch", Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch).controlSize(.small)) }
            SettingsFormRow(title: "滑块标签", language: "zh-CN") { frame("slider", Slider(value: .constant(0.5)).frame(width: 110)); OpticalText(title: "50%", size: 13, language: "zh-CN") }
            SettingsFormRow(title: "分段标签", language: "zh-CN") { frame("segments", SettingsSegmentedPicker(selection: .constant("a"), options: [("a", "浅色"), ("b", "深色")], label: "主题", language: "zh-CN").frame(width: 200)) }
            SettingsFormRow(title: "菜单标签", language: "zh-CN") { frame("menu", Menu { Button("项目") {} } label: { OpticalText(title: "项目", size: 13, language: "zh-CN") }) }
        }.coordinateSpace(name: "optical-controls").onPreferenceChange(OpticalControlRectKey.self) { frames = $0 }
        let (_, host) = try await native(matrix, width: 420, height: 176)
        XCTAssertEqual(Set(frames.keys), ["switch", "slider", "segments", "menu"])
        for (index, id) in ["switch", "slider", "segments", "menu"].enumerated() {
            XCTAssertEqual(try XCTUnwrap(frames[id]).midY, CGFloat(index * 44 + 22), accuracy: 0.5, id)
        }
        XCTAssertGreaterThan(host.subviews.count, 0)
        print("Native control layout fallback verified: switch, slider, segments, menu")
    }

    func testGanttHeightAndTextLineGeometry() throws {
        for height: CGFloat in [56, 80, 120] {
            let row = GanttRowLayout {
                Color.clear.frame(width: 220, height: height)
                Rectangle().frame(height: 20).frame(maxHeight: .infinity)
            }
            let rep = try render(row, width: 600, height: height)
            try aligned(rep, ranges: [220..<600], center: height / 2)
        }
        for size: CGFloat in [13, 14, 16, 22] {
            let font = DotistDesign.nativeFont(size, language: "zh-CN")
            let geometry = TextLineGeometry(font: font, in: CGRect(x: 0, y: 0, width: 200, height: 30))
            XCTAssertEqual(geometry.inkBounds.midY, 15, accuracy: 0.01)
        }
    }
}

private struct OpticalControlRectKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}
