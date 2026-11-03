import AppKit
import SwiftUI
import XCTest
@testable import DotistApp

/// Window-hosted AppKit captures only. Never order/activate a window or send
/// desktop events. Missing glyph pixels are failures, not a passing skip.
@MainActor
final class NativeRenderingFixture<Content: View> {
    let host: NSHostingView<Content>
    let window: NSWindow
    private let captureView = NSView()
    private let scaleProbe = DrawingScaleProbe()
    // Capture-context scale; private AppKit glyph layers may retain a raster
    // made at window.backingScaleFactor. These are separate measurements.
    var lastDrawingScale: CGFloat? { scaleProbe.scale }

    private final class DrawingScaleProbe: NSView {
        var scale: CGFloat?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            if let transform = NSGraphicsContext.current?.cgContext.ctm { scale = hypot(transform.a, transform.b) }
        }
    }

    private final class FixtureWindow: NSWindow {
        var simulatedBackingScale: CGFloat?
        override var backingScaleFactor: CGFloat { simulatedBackingScale ?? super.backingScaleFactor }
    }
    init(_ content: Content, size: CGSize, colorSpace: NSColorSpace? = nil, simulatedBackingScale: CGFloat? = nil) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: size)
        let fixtureWindow = FixtureWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: NSScreen.main)
        fixtureWindow.simulatedBackingScale = simulatedBackingScale
        window = fixtureWindow
        window.isReleasedWhenClosed = false
        if let colorSpace { window.colorSpace = colorSpace }
        captureView.frame = host.frame
        window.contentView = captureView
        captureView.addSubview(host)
        host.layoutSubtreeIfNeeded()
        scaleProbe.frame = captureView.bounds
        scaleProbe.autoresizingMask = [.width, .height]
        captureView.addSubview(scaleProbe) // A sibling; never mutate NSHostingView's managed hierarchy.
    }
    func close() { window.makeFirstResponder(nil); window.close() }
    func descendants<T: NSView>(_ type: T.Type) -> [T] {
        func visit(_ view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap(visit)
        }
        return visit(host)
    }
    func capture(scale: CGFloat) async throws -> NSBitmapImageRep {
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(host.bounds.width * scale), pixelsHigh: Int(host.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = raw.retagging(with: window.colorSpace ?? .sRGB) ?? raw
        image.size = host.bounds.size
        // Transparent subtrees may paint nothing; do not expose allocator bytes.
        image.bitmapData?.initialize(repeating: 0, count: image.bytesPerRow * image.pixelsHigh)
        scaleProbe.scale = nil
        scaleProbe.needsDisplay = true
        captureView.cacheDisplay(in: captureView.bounds, to: image)
        return image
    }
}

/// Advances the real layout timers on explicit logical time. Slow AX queries
/// and bitmap captures cannot consume the transition before it is inspected.
@MainActor
final class LayoutMotionTestClock {
    private var time: TimeInterval = 1_000
    private let saved = LayoutMotionInputs.testOverride
    init(reduceMotion: Bool = false) {
        LayoutMotionInputs.testOverride = .init(now: { [unowned self] in self.time }, reduceMotion: reduceMotion)
    }
    func advance(by interval: TimeInterval) async throws {
        time += interval
        // Let the unchanged production run-loop timers deliver this instant.
        // Logical time stays fixed even if this task resumes much later.
        try await Task.sleep(for: .milliseconds(25))
    }
    func restore() { LayoutMotionInputs.testOverride = saved }
}

@MainActor
final class ComposerRenderingRegressionTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
    }
    private struct FieldHost: NSViewRepresentable {
        let field: NSTextField
        func makeNSView(context: Context) -> NSTextField { field }
        func updateNSView(_ view: NSTextField, context: Context) {}
    }
    private func field(value: String, placeholder: String, reference: Bool, size: CGFloat = 13, language: String = "en") -> NSTextField {
        let field: NSTextField = reference ? NSTextField(frame: .zero) : ComposerTextField()
        let sample = value.isEmpty ? placeholder : value
        field.isEditable = true; field.isSelectable = true
        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false
        field.maximumNumberOfLines = 1; field.usesSingleLineMode = false; field.cell?.wraps = false; field.cell?.isScrollable = true; field.lineBreakMode = .byClipping
        let font = DotistDesign.nativeFont(size, language: language)
        if let composer = field as? ComposerTextField {
            composer.rowHeight = size == 22 ? 30 : 24
            composer.configure(font: font, reference: sample)
        } else { field.font = font }
        field.focusRingType = .none
        field.textColor = .black
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: NSColor.gray])
        field.stringValue = value
        return field
    }
    private func ink(_ image: NSBitmapImageRep) -> [UInt8] {
        (0..<image.pixelsHigh).flatMap { y in
            (0..<image.pixelsWide).map { x in
                guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return UInt8(0) }
                return UInt8((255 * c.alphaComponent * (1 - min(c.redComponent, c.greenComponent, c.blueComponent))).rounded())
            }
        }
    }

    private func hostedReference(value: String, placeholder: String) -> NSTextField {
        let field = field(value: value, placeholder: placeholder, reference: true)
        let font = DotistDesign.nativeFont(13, language: "en")
        field.textColor = NSColor(DotistDesign.ink)
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: NSColor(DotistDesign.faint)])
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.identifier = NSUserInterfaceItemIdentifier("composer-native-reference")
        return field
    }
    @ViewBuilder private func hostedScene(search: Bool, value: String, placeholder: String, reference: Bool) -> some View {
        if search {
            Group {
                if reference {
                    IconTextRow(spacing: 12) {
                        OpticalSymbol(name: "magnifyingglass", size: 12).foregroundStyle(DotistDesign.faint).frame(width: 20, height: 24)
                        FieldHost(field: self.hostedReference(value: value, placeholder: placeholder)).frame(height: 24)
                    }
                } else { SearchRow(text: .constant(value), placeholder: placeholder, language: "en") }
            }.padding(.horizontal, 12).frame(height: 34)
                .background { Color.clear.glassEffect(.regular, in: .capsule) }
                .frame(width: 364, height: 52).background(Color.white).environment(\.colorScheme, .light)
        } else {
            GlassEffectContainer(spacing: 12) {
                ComposerLayout {
                    Menu {} label: { ComposerGroupLabel(title: "All", language: "en") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height: 24)
                    Group {
                        if reference {
                            FieldHost(field: self.hostedReference(value: value, placeholder: placeholder))
                        } else {
                            ComposerInput(text: .constant(value), focused: .constant(false), placeholder: placeholder,
                                label: "New task", font: DotistDesign.nativeFont(13, language: "en"), commit: {},
                                navigate: { _ in false }, complete: { _ in false })
                        }
                    }.frame(height: 24)
                    ComposerCalendarIcon()
                }.padding(.leading, 16).padding(.trailing, 11).frame(height: 52)
            }.frame(width: 364, height: 52).background(Color.white).environment(\.colorScheme, .light)
        }
    }

    private struct GlyphMask {
        let bounds: CGRect
        let visibleBounds: CGRect
        let pixels: [UInt8]
    }
    private func glyphMask(_ image: NSBitmapImageRep, xRange: Range<Int>? = nil, material: Bool = false) -> GlyphMask? {
        let pixels = ink(image)
        let columns = xRange ?? 0..<image.pixelsWide
        var left = image.pixelsWide, right = -1, top = image.pixelsHigh, bottom = -1
        var visibleTop = image.pixelsHigh, visibleBottom = -1
        for y in 0..<image.pixelsHigh {
            for x in columns {
                let value = pixels[y * image.pixelsWide + x]
                if value > (material ? 63 : 24) {
                    left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                }
                if value > 51 { visibleTop = min(visibleTop, y); visibleBottom = max(visibleBottom, y) }
            }
        }
        guard right >= left else { return nil }
        let cropped = (top...bottom).flatMap { y in (left...right).map { x -> UInt8 in
            let value = pixels[y * image.pixelsWide + x]
            return material ? (value >= 64 ? 255 : 0) : value
        } }
        return GlyphMask(bounds: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1),
                         visibleBounds: CGRect(x: left, y: visibleTop, width: right - left + 1, height: visibleBottom - visibleTop + 1), pixels: cropped)
    }
    private func differingPixels(_ actual: GlyphMask, _ expected: GlyphMask, allowContourCoverage: Bool = false) -> Int {
        guard actual.bounds.size == expected.bounds.size, actual.pixels.count == expected.pixels.count else {
            return max(actual.pixels.count, expected.pixels.count)
        }
        let width = Int(actual.bounds.width), height = Int(actual.bounds.height)
        func unoccupied(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return true }
            return min(actual.pixels[y * width + x], expected.pixels[y * width + x]) == 0
        }
        return actual.pixels.indices.filter { index in
            let a = actual.pixels[index], b = expected.pixels[index]
            guard abs(Int(a) - Int(b)) > 2 else { return false }
            // Two gray levels are the existing bitmap noise tolerance. Missing
            // or additional stroke samples remain failures at every scale.
            // Occupancy means nonzero coverage, including very faint contours;
            // the noise tolerance applies to differences, not to occupancy.
            guard allowContourCoverage, min(a, b) > 0 else { return true }
            let x = index % width, y = index / width
            let contour = unoccupied(x - 1, y) || unoccupied(x + 1, y)
                || unoccupied(x, y - 1) || unoccupied(x, y + 1)
            return !contour // Interior tones must still match exactly.
        }.count
    }

    private func assertSingleNativeRun(_ actual: NSBitmapImageRep, reference: NSBitmapImageRep,
                                       fieldFrame: CGRect, scale: CGFloat, material: Bool, backingScale: CGFloat? = nil, message: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let columns = max(0, Int(fieldFrame.minX * scale))..<min(actual.pixelsWide, Int(fieldFrame.maxX * scale))
        let observed = glyphMask(actual, xRange: columns, material: material)
        let expected = try XCTUnwrap(glyphMask(reference, xRange: columns, material: material), "Independent native reference must render glyphs: " + message, file: file, line: line)
        let actualMask = try XCTUnwrap(observed, message, file: file, line: line)
        // The stock reference has no production geometry overrides. At the
        // physical window's backing scale every glyph tone and the absolute
        // optical axis must match. Alternate capture scales retain full support,
        // bounds and interior-tone checks; contour coverage is sample-phase
        // dependent, as the fractional-raster witness below demonstrates.
        XCTAssertGreaterThan(expected.pixels.filter { $0 > 24 }.count, 30, "Native reference must render glyphs", file: file, line: line)
        XCTAssertEqual(actualMask.bounds.size, expected.bounds.size, message, file: file, line: line)
        let nativeScale = backingScale == nil || backingScale == scale
        let differences = differingPixels(actualMask, expected, allowContourCoverage: !nativeScale)
        XCTAssertEqual(actualMask.pixels.count, expected.pixels.count, message, file: file, line: line)
        XCTAssertEqual(differences, 0, message, file: file, line: line)
        if nativeScale {
            XCTAssertEqual(actualMask.visibleBounds.midY / scale, fieldFrame.midY, accuracy: 2.0, message, file: file, line: line)
        }
        if differences != 0 || actualMask.bounds.size != expected.bounds.size {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-composer-mismatch-" + UUID().uuidString)
            try XCTUnwrap(actual.representation(using: .png, properties: [:])).write(to: path.appendingPathExtension("actual.png"))
            try XCTUnwrap(reference.representation(using: .png, properties: [:])).write(to: path.appendingPathExtension("reference.png"))
            print("Composer mismatch \(message): actual=\(actualMask.bounds), reference=\(expected.bounds), artifacts=\(path.path)")
        }
    }

    func testComposerAndSettingsSearchTopologyMatchNativePainter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-native-composer-evidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for search in [false, true] {
            for value in ["", "Existing gyp"] {
                let a = NativeRenderingFixture(hostedScene(search: search, value: value, placeholder: "Jot something down", reference: false), size: CGSize(width: 364, height: 52))
                let b = NativeRenderingFixture(hostedScene(search: search, value: value, placeholder: "Jot something down", reference: true), size: CGSize(width: 364, height: 52))
                defer { a.close(); b.close() }
                let actual = try XCTUnwrap(a.descendants(ComposerTextField.self).first)
                let reference = try XCTUnwrap(b.descendants(NSTextField.self).first { $0.identifier?.rawValue == "composer-native-reference" })
                for focused in [false, true, false] {
                    for (fixture, field) in [(a, actual as NSTextField), (b, reference)] {
                        XCTAssertTrue(fixture.window.makeFirstResponder(focused ? field : nil))
                        if focused {
                            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "\(field === actual ? "production" : "reference") field must own its editor; first responder=\(String(describing: fixture.window.firstResponder))")
                            editor.insertionPointColor = .clear
                            editor.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
                        }
                    }
                    for scale: CGFloat in [1, 2] {
                        let expected = try await b.capture(scale: scale)
                        let observed = try await a.capture(scale: scale)
                        let frame = a.host.convert(actual.bounds, from: actual)
                        if value.isEmpty && focused {
                            let name = "search\(search)-placeholder-focused-bitmap\(Int(scale))"
                            try XCTUnwrap(observed.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + "-actual.png"))
                            try XCTUnwrap(expected.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + "-reference.png"))
                        }
                        try assertSingleNativeRun(observed, reference: expected, fieldFrame: frame, scale: scale, material: true,
                            message: "search=\(search), value=\(value), focused=\(focused), capture=\(scale)x, backing=\(a.window.backingScaleFactor)x")
                    }
                }
            }
        }
        print("Native composer/search artifacts: \(directory.path)")
    }

    func testEmptyPlaceholderAndValueMatchSingleNativePainterAcrossFocusAndScales() async throws {
        let saved = DotistDesign.fontPreferences
        defer { DotistDesign.fontPreferences = saved }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-native-input-evidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var captures = ["family,size,case,focused,windowBacking,bitmapScale,drawScale,actualCenter,referenceCenter,pixelDifferences,nativeScale,comparisonDifferences"]
        for family in ["atkinson-next", "source-sans-3", "system"] {
            DotistDesign.fontPreferences = .init(sansLatin: family)
            for size: CGFloat in [13, 14, 22] {
                for (caseIndex, (value, placeholder, language)) in [("", "", "en"), ("", "Jot something down", "en"), ("", "写下一件小事", "zh-CN"),
                    ("", "Notez quelque chose", "fr"), ("Jot something down", "placeholder", "en"), ("Arbeit gyp", "placeholder", "de")].enumerated() {
                    let actual = field(value: value, placeholder: placeholder, reference: false, size: size, language: language)
                    let reference = field(value: value, placeholder: placeholder, reference: true, size: size, language: language)
                    let height: CGFloat = size == 22 ? 30 : 24
                    let a = NativeRenderingFixture(FieldHost(field: actual).frame(height: height).background(Color.white), size: CGSize(width: 280, height: height))
                    let b = NativeRenderingFixture(FieldHost(field: reference).frame(height: height).background(Color.white), size: CGSize(width: 280, height: height))
                    defer { a.close(); b.close() }
                    let alignment = actual.alignmentRect(forFrame: actual.frame)
                    XCTAssertEqual(alignment.height, height, accuracy: 0.01, "Native line padding must preserve the SwiftUI row")
                    XCTAssertNotNil(actual.hitTest(CGPoint(x: alignment.midX, y: alignment.midY)))
                    XCTAssertNil(actual.hitTest(CGPoint(x: alignment.midX, y: alignment.minY - 1)), "Line-box padding must not intercept adjacent rows")
                    for focused in [false, true, false] {
                        for (fixture, field) in [(a, actual as NSTextField), (b, reference)] {
                            XCTAssertTrue(fixture.window.makeFirstResponder(focused ? field : nil))
                            if focused {
                                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                                XCTAssertTrue(fixture.window.firstResponder === editor)
                                if field === actual {
                                    let composerEditor = try XCTUnwrap(editor as? ComposerFieldEditor)
                                    XCTAssertTrue(composerEditor.composer === actual)
                                }
                                editor.insertionPointColor = .clear
                                editor.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
                            } else { XCTAssertNil(field.currentEditor()) }
                        }
                        let backingScale = a.window.backingScaleFactor
                        // Inspect the actual UI raster before requesting any
                        // alternative sampling of that same native hierarchy.
                        for scale in [backingScale] + [CGFloat(1), 2].filter({ $0 != backingScale }) {
                            let expected = try await b.capture(scale: scale)
                            let observed = try await a.capture(scale: scale)
                            let frame = a.host.convert(actual.bounds, from: actual)
                            let am = glyphMask(observed), bm = glyphMask(expected)
                            let differences = zip(am?.pixels ?? [], bm?.pixels ?? []).filter { abs(Int($0.0) - Int($0.1)) > 2 }.count
                            let comparisonDifferences = am.flatMap { actualMask in bm.map { differingPixels(actualMask, $0, allowContourCoverage: scale != backingScale) } } ?? 0
                            captures.append("\(family),\(size),\(caseIndex),\(focused),\(a.window.backingScaleFactor),\(scale),\(a.lastDrawingScale.map { String(describing: $0) } ?? "cached"),\(am.map { $0.visibleBounds.midY / scale } ?? -1),\(bm.map { $0.visibleBounds.midY / scale } ?? -1),\(differences),\(scale == backingScale),\(comparisonDifferences)")
                            if family == "system" && size == 14 {
                                let name = "system14-case\(caseIndex)-focus\(focused)-bitmap\(Int(scale))"
                                try XCTUnwrap(observed.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + "-actual.png"))
                                try XCTUnwrap(expected.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + "-reference.png"))
                            }
                            if value.isEmpty && placeholder.isEmpty {
                                XCTAssertNil(glyphMask(expected), "Empty native field must have no glyphs")
                                XCTAssertNil(glyphMask(observed), "Empty production field must have no glyphs")
                            } else {
                                try assertSingleNativeRun(observed, reference: expected, fieldFrame: frame, scale: scale, material: false, backingScale: backingScale,
                                    message: "\(family), \(size)pt, value=\(value), placeholder=\(placeholder), focused=\(focused), capture=\(scale)x, backing=\(a.window.backingScaleFactor)x")
                            }
                        }
                    }
                }
            }
        }
        try captures.joined(separator: "\n").write(to: directory.appendingPathComponent("capture-scales.csv"), atomically: true, encoding: .utf8)
        print("Native input artifacts: \(directory.path); actual screen backing=\(String(describing: NSScreen.main?.backingScaleFactor)). Window backing, bitmap size and draw-context scale are recorded separately.")
    }

    func testFractionalRasterPhaseChangesContourCoverageWithoutChangingShape() throws {
        let sourceScale: CGFloat = 2
        func raster(scale: CGFloat, phase: CGFloat, missingStroke: Bool = false, ghost: Bool = false) throws -> GlyphMask {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(32 * scale), pixelsHigh: Int(32 * scale), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = CGSize(width: 32, height: 32)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.current = graphics
            graphics.shouldAntialias = true
            NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 32, height: 32).fill()
            let rect = CGRect(x: 4, y: 5 + phase, width: 10, height: 13 + 1 / sourceScale)
            NSColor.black.setFill(); NSBezierPath(rect: rect).fill()
            if missingStroke {
                NSColor.white.setFill(); NSBezierPath(rect: CGRect(x: 8, y: 10 + phase, width: 1, height: 1)).fill()
            }
            if ghost {
                NSColor.black.withAlphaComponent(0.5).setFill()
                NSBezierPath(rect: rect.offsetBy(dx: 1, dy: 0)).fill()
            }
            return try XCTUnwrap(glyphMask(bitmap))
        }
        // This is a controlled bitmap witness, not a claim of a Retina screen.
        // An integer native-pixel translation becomes fractional at 1x.
        let nativeA = try raster(scale: sourceScale, phase: 0)
        let nativeB = try raster(scale: sourceScale, phase: 1 / sourceScale)
        XCTAssertEqual(differingPixels(nativeA, nativeB), 0)
        let sampledA = try raster(scale: 1, phase: 0)
        let sampledB = try raster(scale: 1, phase: 1 / sourceScale)
        XCTAssertEqual(sampledA.bounds.size, sampledB.bounds.size)
        XCTAssertGreaterThan(differingPixels(sampledA, sampledB), 0, "Fractional sampling changes edge coverage")
        XCTAssertNotEqual(sampledA.visibleBounds.midY, nativeA.visibleBounds.midY / sourceScale,
                          "Thresholded ink bounds are not invariant under sampling")
        XCTAssertEqual(differingPixels(sampledA, sampledB, allowContourCoverage: true), 0)
        XCTAssertGreaterThan(differingPixels(try raster(scale: 1, phase: 0, missingStroke: true), sampledA, allowContourCoverage: true), 0)
        XCTAssertGreaterThan(differingPixels(try raster(scale: 1, phase: 0, ghost: true), sampledA, allowContourCoverage: true), 0)
    }

    func testBindingRefreshPreservesMarkedTextSelectionAndNativeCommands() async throws {
        var text = ""
        var focused = false
        var commits = 0
        var completions: [Bool] = []
        func input() -> ComposerInput {
            ComposerInput(text: Binding(get: { text }, set: { text = $0 }),
                focused: Binding(get: { focused }, set: { focused = $0 }), placeholder: "Jot something down", label: "New task",
                font: DotistDesign.nativeFont(13, language: "fr"), commit: { commits += 1 }, navigate: { _ in false },
                complete: { completions.append($0); return false })
        }
        let fixture = NativeRenderingFixture(input(), size: CGSize(width: 280, height: 24))
        defer { fixture.close() }
        let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first)
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? ComposerFieldEditor)
        editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        let selection = editor.selectedRanges
        text = "stale binding" // Exercise a genuinely conflicting update during composition.
        fixture.host.rootView = input() // Simulate an unrelated SwiftUI update.
        _ = try await fixture.capture(scale: 2)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(editor.selectedRanges, selection)
        XCTAssertEqual(editor.string, "にほん")
        let coordinator = try XCTUnwrap(field.delegate as? ComposerInput.Coordinator)
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(commits, 0); XCTAssertTrue(completions.isEmpty)
        editor.unmarkText()
        editor.setSelectedRange(NSRange(location: 1, length: 1))
        let selected = editor.selectedRanges
        text = editor.string
        fixture.host.rootView = input()
        _ = try await fixture.capture(scale: 2)
        XCTAssertEqual(editor.selectedRanges, selected)
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(commits, 1); XCTAssertEqual(completions, [false, true])
        XCTAssertTrue(editor.allowsUndo)
        let undo = try XCTUnwrap(editor.undoManager)
        undo.removeAllActions()
        let before = editor.string
        editor.insertText("undo", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(editor.string, before)
    }
}
