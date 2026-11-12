import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class TransientGlassTests: XCTestCase {
    func testCompactUsesSharedGlassHelper() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DotistApp/Design/TransientGlass.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)
        let compact = try XCTUnwrap(contents.components(separatedBy: "struct TransientGlassSurface:").last)
        XCTAssertTrue(compact.contains(".dotistGlass(Glass.regular.tint(tint)"))
        XCTAssertTrue(contents.contains("glassEffect(glass, in: shape).clipShape(shape.inset(by: 1))"))
    }

    func testThemeEdgeAndCompactWashMatchExpanded() throws {
        for scheme in [ColorScheme.light, .dark] {
            func pixel<V: View>(_ view: V) throws -> NSColor {
                let image = try bitmap(view.frame(width: 48, height: 48), scheme: scheme)
                return try XCTUnwrap(image.colorAt(x: 48, y: 48)?.usingColorSpace(.sRGB))
            }
            let white = try pixel(Color.white)
            let neutral = try pixel(GlassEdge.highlightColor(.none, scheme))
            XCTAssertEqual(neutral.redComponent, white.redComponent, accuracy: 0.001)
            XCTAssertEqual(neutral.greenComponent, white.greenComponent, accuracy: 0.001)
            XCTAssertEqual(neutral.blueComponent, white.blueComponent, accuracy: 0.001)
            for color in DotistGroupColor.allCases where color != .none {
                let edge = try pixel(GlassEdge.highlightColor(color, scheme))
                let swatch = try pixel(DotistTheme.swatch(color))
                let edgeLight = 0.2126 * edge.redComponent + 0.7152 * edge.greenComponent + 0.0722 * edge.blueComponent
                let swatchLight = 0.2126 * swatch.redComponent + 0.7152 * swatch.greenComponent + 0.0722 * swatch.blueComponent
                XCTAssertGreaterThan(edgeLight, swatchLight)
                XCTAssertLessThan(edgeLight, 0.999)
                let compact = try pixel(FloatingPanelSurface(opacity: 0, frost: 0, compact: true,
                    color: color, solid: false, scheme: scheme))
                let reference = try pixel(ZStack {
                    Color.clear.dotistGlass(.regular.tint(DotistTheme.tint(color, scheme)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .environment(\.appearsActive, true)
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(GlassTintMaterial.themeWash(color, scheme))
                    if scheme == .dark { Color.black.opacity(GlassTintMaterial.compactDarkProtection) }
                })
                XCTAssertEqual(compact.redComponent, reference.redComponent, accuracy: 0.02)
                XCTAssertEqual(compact.greenComponent, reference.greenComponent, accuracy: 0.02)
                XCTAssertEqual(compact.blueComponent, reference.blueComponent, accuracy: 0.02)
                let expanded = try pixel(ExpandedReadingMaterial(opacity: 0, frost: 0, color: color, scheme: scheme, cornerRadius: 24))
                let wash = try pixel(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(GlassTintMaterial.themeWash(color, scheme)))
                XCTAssertEqual(expanded.alphaComponent, wash.alphaComponent, accuracy: 0.01)
                XCTAssertEqual(expanded.greenComponent, wash.greenComponent, accuracy: 0.02)
            }
        }
    }

    private func bitmap<V: View>(_ view: V, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// Exercises the production surface, including its dark contrast backing. The
    /// raster comparison checks layout, not WindowServer refraction or clipping.
    func testFloatingSurfaceCompactOpticalInsetAndRevealGeometry() throws {
        for onRight in [false, true] {
            for (outerWidth, reveal): (CGFloat, CGFloat) in [(48, 0), (240, 0), (240, 0.5), (240, 1)] {
                let size = CGSize(width: outerWidth, height: 48)
                let visibleWidth = 48 + (outerWidth - 48) * reveal
                let actual = try bitmap(FloatingSurface(opacity: 60, frost: 40, compact: true,
                    transitioning: false, onRight: onRight, size: size, reveal: reveal, color: .none)
                    .frame(width: outerWidth, height: 48), scheme: .dark)
                // Build the reference at explicit material dimensions, positioned
                // within the unchanged outer frame, independently of padding.
                let expected = try bitmap(FloatingPanelMaterial(opacity: 60, frost: 40, compact: true, color: .none)
                    .frame(width: visibleWidth - 4, height: 44)
                    .frame(width: visibleWidth, height: 48)
                    .frame(width: outerWidth, height: 48, alignment: onRight ? .trailing : .leading), scheme: .dark)
                XCTAssertEqual(actual.pixelsWide, Int(outerWidth * 2))
                XCTAssertEqual(actual.pixelsHigh, 96)
                for y in stride(from: 0, to: 96, by: 2) {
                    for x in stride(from: 0, to: Int(outerWidth * 2), by: 2) {
                        let a = try XCTUnwrap(actual.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        let b = try XCTUnwrap(expected.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 0.02,
                            "Mismatch at \(x),\(y), width \(outerWidth), reveal \(reveal), right \(onRight)")
                    }
                }
                // Native optics may extend into padding. Compare the same
                // boundary pixel to an uninset material under identical conditions.
                let uninset = try bitmap(FloatingPanelMaterial(opacity: 60, frost: 40, compact: true, color: .none)
                    .frame(width: visibleWidth, height: 48)
                    .frame(width: outerWidth, height: 48, alignment: onRight ? .trailing : .leading), scheme: .dark)
                let left = onRight ? outerWidth - visibleWidth : 0
                let boundaryX = Int((left + 1) * 2)
                let insetAlpha = try XCTUnwrap(actual.colorAt(x: boundaryX, y: 48)).alphaComponent
                let uninsetAlpha = try XCTUnwrap(uninset.colorAt(x: boundaryX, y: 48)).alphaComponent
                XCTAssertLessThan(insetAlpha, uninsetAlpha,
                    "Inset must reduce boundary coverage: width \(outerWidth), reveal \(reveal), right \(onRight)")
                XCTAssertGreaterThan(try XCTUnwrap(actual.colorAt(x: Int((left + visibleWidth / 2) * 2), y: 48)).alphaComponent, 0.3)
                XCTAssertLessThan(try XCTUnwrap(actual.colorAt(x: Int((left + visibleWidth / 2) * 2), y: 1)).alphaComponent, 0.02)
            }
        }
    }

    func testFloatingSurfaceExpandedAndAccessibilitySilhouettesRemainUninset() throws {
        for compact in [false, true] {
            for protection in 0...2 where !compact || protection != 0 {
                let size = CGSize(width: compact ? 48 : 240, height: compact ? 48 : 120)
                let actual = try bitmap(FloatingSurface(opacity: 60, frost: 40, compact: compact,
                    transitioning: false, onRight: true, size: size, reveal: 1, color: .none)
                    .frame(width: size.width, height: size.height)
                    .environment(\._accessibilityReduceTransparency, protection == 1)
                    .environment(\._colorSchemeContrast, protection == 2 ? .increased : .standard), scheme: .dark)
                let expected = try bitmap(FloatingPanelMaterial(opacity: 60, frost: 40, compact: compact, color: .none)
                    .frame(width: size.width, height: size.height)
                    .clipShape(FloatingPanelShape(compact: compact, transitioning: false, onRight: true, reveal: 1))
                    .environment(\._accessibilityReduceTransparency, protection == 1)
                    .environment(\._colorSchemeContrast, protection == 2 ? .increased : .standard), scheme: .dark)
                XCTAssertEqual(actual.pixelsWide, Int(size.width * 2))
                XCTAssertEqual(actual.pixelsHigh, Int(size.height * 2))
                for (x, y) in [(Int(size.width), 1), (1, Int(size.height)), (Int(size.width), Int(size.height))] {
                    XCTAssertEqual(try XCTUnwrap(actual.colorAt(x: x, y: y)).alphaComponent,
                        try XCTUnwrap(expected.colorAt(x: x, y: y)).alphaComponent, accuracy: 0.02)
                }
            }
        }
    }

    /// Compact contrast treatment must remain independent of expanded-panel presets.
    /// Environment toggles compare composition with a matched reference; they do
    /// not reproduce real native glass deactivation in WindowServer.
    func testCompactGlassContrastBackingAndPresetIndependence() throws {
        for scheme in [ColorScheme.light, .dark] {
            for width in [48, 240] {
                let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
                let reference = try bitmap(ZStack {
                    Color.white
                    Color.clear.glassEffect(.regular, in: shape).environment(\.appearsActive, true)
                    if scheme == .dark { shape.fill(Color.black.opacity(0.4)) }
                }.frame(width: CGFloat(width), height: 48), scheme: scheme)
                for (opacity, frost): (UInt8, UInt8) in [(8, 4), (60, 40), (100, 100)] {
                    for active in [false, true] {
                        let actual = try bitmap(ZStack {
                            Color.white
                            FloatingPanelSurface(opacity: opacity, frost: frost, compact: true,
                                color: .none, solid: false, scheme: scheme)
                                .environment(\.appearsActive, active)
                        }.frame(width: CGFloat(width), height: 48), scheme: scheme)
                        let a = try XCTUnwrap(actual.colorAt(x: width, y: 48)?.usingColorSpace(.sRGB))
                        let b = try XCTUnwrap(reference.colorAt(x: width, y: 48)?.usingColorSpace(.sRGB))
                        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.025,
                            "Compact center must match the regular-glass composition; inherited active=\(active)")
                    }
                }
            }
        }
    }

    func testCompactAccessibilitySurfaceIsOpaqueAndThemeCorrectAtBothWidths() throws {
        for scheme in [ColorScheme.light, .dark] {
            for width in [48, 240] {
                let image = try bitmap(FloatingPanelSurface(opacity: 8, frost: 4, compact: true,
                    color: .none, solid: true, scheme: scheme).frame(width: CGFloat(width), height: 48), scheme: scheme)
                let center = try XCTUnwrap(image.colorAt(x: width, y: 48)?.usingColorSpace(.sRGB))
                XCTAssertEqual(center.alphaComponent, 1, accuracy: 0.01)
                if scheme == .dark { XCTAssertLessThan(center.redComponent, 0.2) }
                else { XCTAssertGreaterThan(center.redComponent, 0.9) }
                XCTAssertLessThan(try XCTUnwrap(image.colorAt(x: 0, y: 0)).alphaComponent, 0.05)
            }
        }
    }

    func testCompactHighlightsAreDirectionalAndLeaveInteriorClear() throws {
        for scheme in [ColorScheme.light, .dark] {
            for width in [48, 240] {
                let image = try bitmap(GlassEdge(cornerRadius: 24, compact: true, scheme: scheme)
                    .frame(width: CGFloat(width), height: 48), scheme: scheme)
                func light(_ x: Int, _ y: Int) throws -> CGFloat {
                    let c = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                    return c.alphaComponent * luminance
                }
                var upperLight: CGFloat = 0, lowerLight: CGFloat = 0
                let start = width == 48 ? 17 : 32
                let end = width == 48 ? 22 : 80
                for x in start...end {
                    for y in 0..<6 {
                        let top = try light(x * 2, y)
                        let bottom = try light((width - x - 1) * 2, image.pixelsHigh - 1 - y)
                        upperLight += top
                        lowerLight += bottom
                    }
                }
                XCTAssertGreaterThan(upperLight, lowerLight * 1.3, "Upper light must lead the secondary reflection: \(scheme), \(width)")
                XCTAssertGreaterThan(upperLight, CGFloat(end - start + 1) * 0.2, "The upper reflection must be visible")
                XCTAssertLessThan(try XCTUnwrap(image.colorAt(x: width, y: 48)).alphaComponent, 0.01,
                    "Reflection must not fill the glass interior")
            }
        }
    }

    func testLiftedTaskAddsNoOpaquePaperOverItsNativeSurface() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-glass-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let task = try store.addTask(title: "Readable task", category: "work")
        let row = TaskListRowFrame(task: task, frame: CGRect(x: 16, y: 100, width: 280, height: 32), region: "work")
        let drag = TaskListDrag(taskID: task.id, blockIDs: [task.id], visibleBlock: [row], startFrame: row.frame,
                                startLocation: CGPoint(x: 110, y: 116))
        let motion = TaskDragMotion(); motion.location = drag.startLocation
        for scheme in [ColorScheme.light, .dark] {
            let actual = try bitmap(TaskLiftedBlock(drag: drag, motion: motion) { _ in Color.clear }
                .frame(width: 320, height: 200, alignment: .topLeading), scheme: scheme)
            let reference = try bitmap(Color.clear.frame(width: 280, height: 32)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .offset(x: 16, y: 100).frame(width: 320, height: 200, alignment: .topLeading), scheme: scheme)
            let a = try XCTUnwrap(actual.colorAt(x: 150 * 2, y: 116 * 2))
            let b = try XCTUnwrap(reference.colorAt(x: 150 * 2, y: 116 * 2))
            XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 0.01, "Lifted rows must use native glass, with opaque paper only for accessibility")
        }
    }

    /// Captures are native window-hosted draws, with no ordered windows or
    /// desktop input. Normal glass may be absent from this rasterizer; retain
    /// that result and report it rather than substituting a blur or paper plate.
    func testNativeCircleStripAndLiftedCaptureMatrixWithAccessibility() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-glass-matrix-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        _ = try store.updateGroup("work", name: "Projects 工作")
        let task = try store.addTask(title: "Plan the next small thing", category: "work")
        let model = try AppModel(store: store)
        let panel = DotistPanel(contentRect: CGRect(x: 100, y: 100, width: 364, height: 620),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let input = PanelMotionTestEnvironment()
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" }, environment: input.environment)
        defer { motion.stop(); panel.close() }
        motion.toggleBubble(in: input.area, animated: false)
        let base = ProcessInfo.processInfo.environment["DOTIST_DRAG_EVIDENCE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("dotist-glass-evidence")
        let evidence = base.appendingPathComponent("glass")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        var records = ["scheme,protection,reveal,onRight,centerAlpha,nativeReferenceAlpha"]
        for scheme in [ColorScheme.light, .dark] {
            for protection in 0...2 {
                for onRight in [false, true] {
                    motion.bubbleOnRight = onRight
                    for reveal in [CGFloat(0), 0.4, 1] {
                        let surface = FloatingSurface(opacity: 60, frost: 40, compact: true,
                            transitioning: false, onRight: onRight, size: CGSize(width: 260, height: 48), reveal: reveal, color: .none)
                            .frame(width: 260, height: 48)
                            .environment(\.colorScheme, scheme)
                            // The SDK's backing environment setters are used
                            // only by fixtures, never by the shipped app.
                            .environment(\._accessibilityReduceTransparency, protection == 1)
                            .environment(\._colorSchemeContrast, protection == 2 ? .increased : .standard)
                        let fixture = NativeRenderingFixture(surface, size: CGSize(width: 260, height: 48))
                        let image = try await fixture.capture(scale: 2)
                        fixture.close()
                        let reference = NativeRenderingFixture(ZStack {
                            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 24)).environment(\.appearsActive, true)
                            if scheme == .dark { RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black.opacity(0.4)) }
                        }.frame(width: 260, height: 48).environment(\.colorScheme, scheme), size: CGSize(width: 260, height: 48))
                        let referenceImage = try await reference.capture(scale: 2)
                        reference.close()
                        let width = 48 + 212 * reveal
                        let centerX = onRight ? 260 - width / 2 : width / 2
                        let alpha = try XCTUnwrap(image.colorAt(x: Int(centerX * 2), y: 48)).alphaComponent
                        let referenceAlpha = try XCTUnwrap(referenceImage.colorAt(x: 260, y: 48)).alphaComponent
                        XCTAssertEqual(alpha, protection == 0 ? referenceAlpha : 1, accuracy: 0.01)
                        let name = "\(scheme)-protection\(protection)-reveal\(reveal)-right\(onRight)"
                        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: evidence.appendingPathComponent(name + "-surface.png"))
                        records.append("\(scheme),\(protection),\(reveal),\(onRight),\(alpha),\(referenceAlpha)")
                        let canvas = ZStack(alignment: .topLeading) {
                            // A native fixture backdrop, not a substitute material.
                            (scheme == .dark ? Color(white: 0.09) : Color(white: 0.83))
                            HStack(spacing: 13) {
                                ForEach(0..<22) { index in Rectangle().fill(index.isMultiple(of: 2) ? Color.orange.opacity(0.55) : Color.blue.opacity(0.5)).frame(width: 9) }
                            }.frame(width: 308, height: 88, alignment: .leading).clipped()
                                .offset(x: -10).rotationEffect(.degrees(16))
                            FloatingBubble(model: model, motion: motion, details: BubbleContent(model: model), groupName: nil,
                                contextMenu: { _, _ in }, width: 260, reveal: reveal)
                                .background(surface).frame(width: 260, height: 48).offset(x: 24, y: 20)
                        }.frame(width: 308, height: 88).clipped()
                            .environment(\.colorScheme, scheme)
                            .environment(\._accessibilityReduceTransparency, protection == 1)
                            .environment(\._colorSchemeContrast, protection == 2 ? .increased : .standard)
                        let contentFixture = NativeRenderingFixture(canvas, size: CGSize(width: 308, height: 88))
                        let contentImage = try await contentFixture.capture(scale: 2)
                        XCTAssertFalse(contentFixture.window.isVisible)
                        contentFixture.close()
                        try XCTUnwrap(contentImage.representation(using: .png, properties: [:])).write(to: evidence.appendingPathComponent(name + "-content.png"))
                    }
                }
                let row = TaskListRowFrame(task: task, frame: CGRect(x: 16, y: 32, width: 280, height: 32), region: "work")
                let drag = TaskListDrag(taskID: task.id, blockIDs: [task.id], visibleBlock: [row], startFrame: row.frame,
                    startLocation: CGPoint(x: 110, y: 48))
                let dragMotion = TaskDragMotion(); dragMotion.location = drag.startLocation
                let content = TaskLiftedBlock(drag: drag, motion: dragMotion) { _ in
                    HStack(spacing: 10) {
                        TaskCheckmark(depth: 0, completed: false, children: [], emphasized: false).frame(width: 16, height: 16)
                        Text(task.title).font(DotistDesign.font(13, language: "en")).foregroundStyle(DotistDesign.ink)
                        Spacer(minLength: 0)
                    }.frame(height: 32)
                }.frame(width: 312, height: 96, alignment: .topLeading)
                    .environment(\.colorScheme, scheme)
                    .environment(\._accessibilityReduceTransparency, protection == 1)
                    .environment(\._colorSchemeContrast, protection == 2 ? .increased : .standard)
                let fixture = NativeRenderingFixture(content, size: CGSize(width: 312, height: 96))
                let image = try await fixture.capture(scale: 2)
                fixture.close()
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: evidence.appendingPathComponent("lifted-\(scheme)-protection\(protection).png"))
                // Check blank interior, clear exterior and retained readable ink.
                let center = try XCTUnwrap(image.colorAt(x: 570, y: 96)).alphaComponent
                if protection > 0 { XCTAssertEqual(center, 1, accuracy: 0.01) }
                XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 4, y: 4)).alphaComponent, 0)
                var inkPixels = 0
                for y in 80..<112 {
                    for x in 88..<500 {
                        let pixel = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        if protection == 0 {
                            if pixel.alphaComponent > 0.5 { inkPixels += 1 }
                        } else if scheme == .dark ? pixel.redComponent > 0.65 : pixel.redComponent < 0.35 { inkPixels += 1 }
                    }
                }
                XCTAssertGreaterThan(inkPixels, 60, "Native ink must remain present in every material state")
            }
        }
        try records.joined(separator: "\n").write(to: evidence.appendingPathComponent("material-states.csv"), atomically: true, encoding: .utf8)
        print("GLASS CAPTURES \(evidence.path); offscreen normal-glass alpha is reported separately from opaque accessibility and ink")
        XCTAssertFalse(panel.isVisible)
    }

}
