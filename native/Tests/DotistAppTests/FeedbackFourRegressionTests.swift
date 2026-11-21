import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

/// Fixture data only. Windows stay unordered; AXPress stays inside this process.
@MainActor
final class FeedbackFourRegressionTests: XCTestCase {
    private var evidence: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/feedback-host-audit/current/four")
    }
    override func setUp() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    }
    private func model(language: String = "zh-CN", system: Bool = false) throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-feedback-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        var patch = DotistSettingsPatch()
        patch.language = language
        patch.opacity = 4; patch.frost = 0; patch.sideTabOpacity = 100; patch.idleOpacity = 77
        patch.fontSerifLatin = system ? "system" : "source-serif-4"
        patch.fontSansLatin = system ? "system" : "atkinson-next"
        patch.fontSerifCjk = system ? "system" : "noto-serif"
        patch.fontSansCjk = system ? "system" : "noto-sans"
        _ = try store.updateSettings(patch)
        let saved = DotistDesign.fontPreferences
        addTeardownBlock { await MainActor.run { DotistDesign.fontPreferences = saved } }
        return try AppModel(store: store)
    }
    private func state(scope: String = "all") throws -> TaskPanelState {
        let suite = "dotist-feedback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return TaskPanelState(scope: scope, collapseStore: TaskGroupCollapseStore(defaults: defaults))
    }
    private func main(_ model: AppModel, _ state: TaskPanelState, material: Bool = false) -> some View {
        MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false)
            .background {
                if material {
                    FloatingPanelSurface(opacity: model.settings.opacity, frost: model.settings.frost, compact: false,
                                         color: .orange, solid: false, scheme: .light)
                        .background(Color(red: 0.95, green: 0.9, blue: 0.85))
                } else { Color.white }
            }.environment(\.colorScheme, .light)
    }
    private func save(_ image: NSBitmapImageRep, _ name: String, directory: URL? = nil) throws {
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: (directory ?? evidence).appendingPathComponent(name + ".png"))
    }
    private func ink(_ image: NSBitmapImageRep, rect: CGRect, threshold: CGFloat = 0.2) throws -> CGRect {
        let scale = CGFloat(image.pixelsWide) / image.size.width
        var x0 = image.pixelsWide, x1 = -1, y0 = image.pixelsHigh, y1 = -1
        let xMin = max(0, min(image.pixelsWide, Int(ceil(rect.minX * scale))))
        let xMax = max(0, min(image.pixelsWide, Int(floor(rect.maxX * scale))))
        let yMin = max(0, min(image.pixelsHigh, Int(ceil(rect.minY * scale))))
        let yMax = max(0, min(image.pixelsHigh, Int(floor(rect.maxY * scale))))
        guard xMin < xMax, yMin < yMax else {
            throw NSError(domain: "DotistRenderingFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ink rectangle \(rect) lies outside bitmap \(image.pixelsWide)x\(image.pixelsHigh) at scale \(scale)"])
        }
        for y in yMin..<yMax {
            for x in xMin..<xMax {
                guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      c.alphaComponent * (1 - max(c.redComponent, c.greenComponent, c.blueComponent)) > threshold else { continue }
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        XCTAssertGreaterThanOrEqual(x1, x0, "Missing ink: \(rect)")
        return CGRect(x: CGFloat(x0) / scale, y: CGFloat(y0) / scale, width: CGFloat(x1 - x0 + 1) / scale, height: CGFloat(y1 - y0 + 1) / scale)
    }
    func testActualMainWindowComposerWithReportedFonts() async throws {
        let nativeScale = NSScreen.main?.backingScaleFactor
        let backingSource = nativeScale == nil ? "simulated" : "native"
        var measures = ["system,language,value,focused,bitmapScale,backingScale,backingSource,groupCenter,inputCenter,groupTopMargin,groupBottomMargin,inputTopMargin,inputBottomMargin"]
        for system in [false, true] {
            for language in ["zh-CN", "en", "fr", "de", "zh-TW"] {
                let model = try model(language: language, system: system)
                let fixture = NativeRenderingFixture(main(model, try state(), material: true).environment(\.displayScale, nativeScale ?? 2), size: CGSize(width: 364, height: 620), simulatedBackingScale: nativeScale == nil ? 2 : nil)
                defer { fixture.close() }
                try await Task.sleep(for: .milliseconds(80))
                let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first)
                for value in ["", model.text("写下一件小事")] {
                    field.stringValue = value
                    for focused in [false, true] {
                        XCTAssertTrue(fixture.window.makeFirstResponder(focused ? field : nil))
                        (field.currentEditor() as? NSTextView)?.insertionPointColor = .clear
                        for scale: CGFloat in [1, 2] {
                            let bitmap = try await fixture.capture(scale: scale)
                            let f = fixture.host.convert(field.bounds, from: field)
                            let group = try ink(bitmap, rect: CGRect(x: 16, y: 580, width: f.minX - 24, height: 32))
                            let input = try ink(bitmap, rect: CGRect(x: f.minX, y: 580, width: f.width, height: 32))
                            let context = "\(language), system=\(system), value=\(value), focus=\(focused), bitmap=\(scale)x, reportedBacking=\(fixture.window.backingScaleFactor)x (\(backingSource); screens=\(NSScreen.screens.count))"
                            print("FEEDBACK COMPOSER \(context): control=\(f), groupInk=\(group), inputInk=\(input), axis=594, margins=\(input.minY - 568)/\(620 - input.maxY)")
                            XCTAssertEqual(group.midY, 594, accuracy: 3.0, context)
                            XCTAssertEqual(input.midY, 594, accuracy: 3.0, context)
                            XCTAssertEqual(group.midY, input.midY, accuracy: 3.0, context)
                            measures.append("\(system),\(language),\(value),\(focused),\(scale),\(fixture.window.backingScaleFactor),\(backingSource),\(group.midY),\(input.midY),\(group.minY - 568),\(620 - group.maxY),\(input.minY - 568),\(620 - input.maxY)")
                            if !system && language == "zh-CN" { try save(bitmap, "composer-\(value.isEmpty ? "placeholder" : "text")-\(focused)-\(Int(scale))") }
                        }
                    }
                }
            }
        }
        try measures.joined(separator: "\n").write(to: evidence.appendingPathComponent("composer-measurements.csv"), atomically: true, encoding: .utf8)
    }
    /// Production panel + hosting + FloatingPanelView path. Backdrops simulate
    /// content behind the transparent window; no screen capture or order call.
    func testComposerInActualPanelSizesAndSystemAppearances() async throws {
        var rows = ["width,height,scheme,backdrop,requestedOrigin,actualOrigin,focus,value,captureScale,nativeBacking,bar,field,groupInk,inputInk,groupTop,groupBottom,inputTop,inputBottom"]
        let sizes = [CGSize(width: 454, height: 568), CGSize(width: 320, height: 440), CGSize(width: 364, height: 620)]
        for size in sizes {
            for scheme in [ColorScheme.light, .dark] {
                for tinted in [false, true] {
                    for origin: CGFloat in [100, 100.25] {
                        let model = try model()
                        XCTAssertEqual(model.settings.theme, "system")
                        let state = try state()
                        let fixture = ActualTaskPanelFixture(model: model, state: state, size: size,
                            scheme: scheme, tinted: tinted, origin: CGPoint(x: origin, y: origin))
                        defer { fixture.close() }
                        try await Task.sleep(for: .milliseconds(60))
                        let field = try XCTUnwrap(fixture.descendants(ComposerTextField.self).first)
                        for value in ["", "写下一件小事"] {
                            // Use the same editor/delegate/binding as user input;
                            // assigning stringValue alone can be undone by updateNSView.
                            XCTAssertTrue(fixture.panel.makeFirstResponder(field))
                            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                            editor.insertionPointColor = .clear
                            editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                            for focused in [false, true] {
                                XCTAssertTrue(fixture.panel.makeFirstResponder(focused ? field : nil))
                                if let editor = field.currentEditor() as? NSTextView {
                                    editor.insertionPointColor = .clear
                                    editor.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
                                }
                                XCTAssertEqual(field.stringValue, value)
                                for scale: CGFloat in [1, 2] {
                                    let image = try await fixture.capture(scale: scale)
                                    let anchor = try XCTUnwrap(fixture.descendants(ComposerBarLayoutAnchor.Box.self).first)
                                    let bar = fixture.host.convert(anchor.bounds, from: anchor)
                                    XCTAssertFalse(bar.isEmpty, "Read the actual outer layout, never the AX text union")
                                    let control = fixture.host.convert(field.bounds, from: field)
                                    XCTAssertEqual(bar.height, ComposerMetrics.barHeight, accuracy: 0.5)
                                    XCTAssertEqual(bar.maxY, fixture.host.bounds.maxY, accuracy: 0.5)
                                    let y = bar.minY + 6
                                    let group = try inkAgainstBackdrop(image, rect: CGRect(x: bar.minX + 14, y: y,
                                        width: control.minX - bar.minX - 22, height: bar.height - 12), referenceY: y)
                                    let input = try inkAgainstBackdrop(image, rect: CGRect(x: control.minX, y: y,
                                        width: control.width, height: bar.height - 12), referenceY: y)
                                    let context = "actual panel \(size), scheme=\(scheme), tinted=\(tinted), origin=\(fixture.panel.frame.origin), focus=\(focused), text=\(value), capture=\(scale), nativeBacking=\(fixture.panel.backingScaleFactor)"
                                    XCTAssertEqual(group.midY, bar.midY, accuracy: 0.5, context)
                                    XCTAssertEqual(input.midY, bar.midY, accuracy: 2.0, context)
                                    XCTAssertEqual(group.midY, input.midY, accuracy: 0.5, context)
                                    rows.append(["\(size.width)", "\(size.height)", "\(scheme)", "\(tinted)", "\(origin)", "\(fixture.panel.frame.origin)", "\(focused)", value,
                                        "\(scale)", "\(fixture.panel.backingScaleFactor)", "\(bar)", "\(control)", "\(group)", "\(input)",
                                        "\(group.minY-bar.minY)", "\(bar.maxY-group.maxY)", "\(input.minY-bar.minY)", "\(bar.maxY-input.maxY)"]
                                        .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
                                    if origin == 100, scale == 2 {
                                        try save(image, "actual-panel-\(Int(size.width))x\(Int(size.height))-\(scheme)-tint\(tinted)-focus\(focused)-\(value.isEmpty ? "placeholder" : "text")")
                                    }
                                }
                            }
                        }
                        XCTAssertFalse(fixture.panel.isVisible)
                    }
                }
            }
        }
        try rows.joined(separator: "\n").write(to: evidence.appendingPathComponent("actual-panel-composer.csv"), atomically: true, encoding: .utf8)
        print("ACTUAL PANEL composer: \(rows.count - 1) captures; screens=\(NSScreen.screens.count); actual SwiftUI bar layout bounds, DotistPanel + DotistHostingView + FloatingPanelView + FloatingSurface")
    }

    private func inkAgainstBackdrop(_ image: NSBitmapImageRep, rect: CGRect, referenceY: CGFloat) throws -> CGRect {
        let scaleX = CGFloat(image.pixelsWide) / image.size.width
        let scaleY = CGFloat(image.pixelsHigh) / image.size.height
        var x0 = image.pixelsWide, x1 = -1, y0 = image.pixelsHigh, y1 = -1
        for y in max(0, Int(ceil(rect.minY * scaleY)))..<min(image.pixelsHigh, Int(floor(rect.maxY * scaleY))) {
            for x in max(0, Int(ceil(rect.minX * scaleX)))..<min(image.pixelsWide, Int(floor(rect.maxX * scaleX))) {
                let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let paper = try XCTUnwrap(image.colorAt(x: x, y: Int(referenceY * scaleY))?.usingColorSpace(.deviceRGB))
                let contrast = max(abs(color.redComponent - paper.redComponent), abs(color.greenComponent - paper.greenComponent), abs(color.blueComponent - paper.blueComponent))
                guard contrast > 0.2 else { continue }
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        XCTAssertGreaterThanOrEqual(x1, x0, "No visible ink in actual bar ROI \(rect)")
        return CGRect(x: CGFloat(x0)/scaleX, y: CGFloat(y0)/scaleY, width: CGFloat(x1-x0+1)/scaleX, height: CGFloat(y1-y0+1)/scaleY)
    }

    private func ax(_ node: Any, id: String) -> NSObject? {
        guard let object = node as? NSObject else { return nil }
        if let element = object as? any NSAccessibilityElementProtocol, element.accessibilityIdentifier?() == id { return object }
        let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        guard object.responds(to: selector) else { return nil }
        for child in object.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] {
            if let found = ax(child, id: id) { return found }
        }
        return nil
    }
    private func press(_ object: NSObject) throws {
        let selector = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
        let method = try XCTUnwrap(object.method(for: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(method, to: Press.self)(object, selector))
    }
    func testActualTaskSectionsHaveIntermediateFrames() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let animationEvidence = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/feedback-sampling-final/frames")
        try FileManager.default.createDirectory(at: animationEvidence, withIntermediateDirectories: true)
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let saved = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(saved, forAttribute: enhanced) }
        for scope in ["all", "undated"] {
            let model = try model(language: "en")
            for title in ["First real task", "Second real task", "Third real task"] { _ = try model.core.addTask(title: title, category: "work") }
            _ = try model.core.addTask(title: "Other group task", category: "life")
            model.refresh()
            let state = try state(scope: scope)
            let fixture = NativeRenderingFixture(main(model, state), size: CGSize(width: 364, height: 620), simulatedBackingScale: NSScreen.main == nil ? 2 : nil)
            defer { fixture.close() }
            try await Task.sleep(for: .milliseconds(120))
            let below = try XCTUnwrap(ax(fixture.host, id: "group-header:life") as? any NSAccessibilityElementProtocol)
            let button = try XCTUnwrap(ax(fixture.host, id: "group-header:work"))
            let header = try XCTUnwrap(button as? any NSAccessibilityElementProtocol)
            func frame(_ element: any NSAccessibilityElementProtocol) -> CGRect {
                fixture.host.convert(fixture.window.convertFromScreen(element.accessibilityFrame()), from: nil)
            }
            let captureScale = fixture.window.backingScaleFactor
            let baselineImage = try await fixture.capture(scale: captureScale)
            // Use the baseline painted title, not its font advance: the latter
            // includes whitespace that can contain the rotating disclosure.
            try save(baselineImage, "animation-\(scope)-baseline", directory: animationEvidence)
            let baselineTitle = try ink(baselineImage, rect: frame(header))
            let titleFrame = CGRect(x: 0, y: 0, width: baselineTitle.maxX - frame(header).minX, height: 30)
            let titleWidth = frame(header).width
            func titleMask(_ image: NSBitmapImageRep) -> [UInt8] {
                let frame = frame(header)
                var mask: [UInt8] = []
                for y in Int(frame.minY*captureScale)..<Int(frame.maxY*captureScale) {
                    for x in Int(frame.minX*captureScale)..<Int((frame.minX+titleFrame.maxX)*captureScale) {
                        let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                        let contrast = color.map { $0.alphaComponent * (1-max($0.redComponent,$0.greenComponent,$0.blueComponent)) } ?? 0
                        mask.append(contrast > 0.2 ? 1 : 0)
                    }
                }
                return mask
            }
            let initialMask = titleMask(baselineImage)
            XCTAssertTrue(initialMask.contains(1))
            var disclosureProgress: CGFloat = 1
            var lastClock: [ObjectIdentifier: DisclosureMotion.Sample] = [:]
            var reversing = false
            var retargetY: CGFloat?
            var retargetFractions: [CGFloat] = []
            var retargets = 0
            let previousTrace = DisclosureMotion.trace
            DisclosureMotion.trace = { sample in
                disclosureProgress = sample.fraction
                if reversing, sample.event == "retarget", sample.target == 0 {
                    retargetY = frame(below).minY
                }
                if reversing, sample.event == "start", sample.target == 0 {
                    if let previous = lastClock[sample.id] {
                        XCTAssertEqual(sample.fraction, previous.fraction, accuracy: 0.03,
                                       "Retarget is continuous at the same instant, not after a slow bitmap capture")
                    }
                    if let retargetY {
                        XCTAssertEqual(frame(below).minY, retargetY, accuracy: 1)
                    } else { XCTFail("Missing same-instant retarget geometry") }
                    retargetFractions.append(sample.fraction)
                    retargets += 1
                }
                lastClock[sample.id] = sample
            }
            defer { DisclosureMotion.trace = previousTrace }
            var angles: [CGFloat] = []
            var positions: [CGFloat] = []
            for index in 0...10 {
                if index == 1 { try press(button) }
                if index > 0 { try await clock.advance(by: 0.018) }
                let bitmap = try await fixture.capture(scale: captureScale)
                let y = frame(below).minY
                positions.append(y)
                angles.append(disclosureProgress)
                XCTAssertTrue(titleMask(bitmap) == initialMask, "The complete same-scale title pixel mask must remain identical: \(scope), frame=\(index), header=\(frame(header)), title=\(baselineTitle), diff=\(zip(titleMask(bitmap), initialMask).filter { $0 != $1 }.count)")
                XCTAssertEqual(frame(header).width, titleWidth, accuracy: 0.01)
                try save(bitmap, "animation-\(scope)-\(index)", directory: animationEvidence)
            }
            let start = try XCTUnwrap(positions.first), end = try XCTUnwrap(positions.last)
            print("FEEDBACK ANIMATION \(scope): \(positions), captureScale=\(captureScale), windowBacking=\(fixture.window.backingScaleFactor), backingSource=\(NSScreen.main == nil ? "simulated" : "native"), screens=\(NSScreen.screens.count), visible=\(fixture.window.isVisible)")
            XCTAssertGreaterThan(abs(start - end), 60)
            XCTAssertTrue(positions.contains { $0 > min(start, end) + 1 && $0 < max(start, end) - 1 }, "Other group must pass through intermediate positions")
            XCTAssertTrue(angles.contains { $0 > 0.01 && $0 < 0.99 }, "The native disclosure must rotate through intermediate angles: \(angles)")
            // Reverse an expansion before it reaches the endpoint. No endpoint
            // assignment may precede the new clock's first sample.
            try press(button)
            try await clock.advance(by: 0.055)
            _ = try await fixture.capture(scale: captureScale)
            let before = disclosureProgress
            XCTAssertGreaterThan(before, 0); XCTAssertLessThan(before, 1)
            reversing = true
            try press(button)
            _ = try await fixture.capture(scale: captureScale)
            XCTAssertGreaterThan(retargets, 0)
            reversing = false
            try await clock.advance(by: 0.040)
            _ = try await fixture.capture(scale: captureScale)
            XCTAssertLessThan(disclosureProgress, try XCTUnwrap(retargetFractions.min()))
            func waitForEnd(_ target: CGFloat) async throws {
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                repeat {
                    _ = try await fixture.capture(scale: captureScale)
                    if disclosureProgress == target && !lastClock.values.contains(where: \.animating) { return }
                    try await clock.advance(by: 0.020)
                } while ProcessInfo.processInfo.systemUptime < deadline
                XCTFail("Disclosure did not deliver endpoint \(target)")
            }
            try await waitForEnd(0)
            XCTAssertEqual(disclosureProgress, 0)
            try press(button)
            try await waitForEnd(1)
            let expandedImage = try await fixture.capture(scale: captureScale)
            try save(expandedImage, "animation-\(scope)-expanded", directory: animationEvidence)
            XCTAssertTrue(titleMask(expandedImage) == initialMask, "Expansion and reversal must preserve the complete title pixel mask")
            XCTAssertEqual(disclosureProgress, 1)
            XCTAssertEqual(frame(below).minY, start, accuracy: 0.5)
            print("FEEDBACK DISCLOSURE \(scope): \(angles), rapid reversal from \(before)")
            XCTAssertFalse(fixture.window.isVisible)
        }
    }
    func testClosingGroupRemovesInteractionGeometryAndAXBeforeAnimationFinishes() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/feedback-sampling-final")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let saved = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(saved, forAttribute: enhanced) }
        let model = try model(language: "en")
        let root = try model.core.addTask(title: "Parent", category: "work")
        let child = try model.core.addTask(title: "Child", category: "work", parentId: root.id)
        let done = try model.core.addTask(title: "Completed", category: "work")
        _ = try model.core.patchTask(id: done.id, completed: true)
        let inbox = try model.core.addTask(title: "Visible inbox", category: DotistGroup.inboxID)
        model.refresh()
        let state = try state()
        state.folded.insert("work")
        var rows: [TaskListRowFrame] = []
        var groups: [TaskListGroupFrame] = []
        let runtime = TaskReorderRuntime()
        // Group frames now describe only the ordinary heading row. Measure
        // the actual section span to the following heading instead.
        func sectionHeight(_ frames: [TaskListGroupFrame]) -> CGFloat? {
            guard let work = frames.first(where: { $0.id == "work" }),
                  let life = frames.first(where: { $0.id == "life" }) else { return nil }
            return life.frame.minY - work.frame.minY
        }
        var active: Set<ObjectIdentifier> = []
        var samples: [DisclosureMotion.Sample] = []
        var collectOpening = false
        var openingDeliveries: [(time: TimeInterval, height: CGFloat)] = []
        openingDeliveries.reserveCapacity(32)
        var callbackCosts: [Double] = []
        var axCosts: [(phase: String, ms: Double)] = []
        let previousTrace = DisclosureMotion.trace
        DisclosureMotion.trace = { sample in
            samples.append(sample)
            if sample.animating { active.insert(sample.id) } else { active.remove(sample.id) }
        }
        defer { DisclosureMotion.trace = previousTrace }
        let fixture = NativeRenderingFixture(MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false, reorderRuntime: runtime)
            .background(Color.white).environment(\.colorScheme, .light)
            .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
            .onPreferenceChange(TaskListGroupFrame.Key.self) { frames in
                let began = ProcessInfo.processInfo.systemUptime
                groups = frames
                // This is delivered layout geometry, not a timer-derived height.
                // No AX, bitmap, assertions or string formatting in this callback.
                if collectOpening, let height = sectionHeight(frames) {
                    openingDeliveries.append((began, height))
                    callbackCosts.append((ProcessInfo.processInfo.systemUptime-began)*1000)
                }
            }, size: CGSize(width: 364, height: 620))
        defer { fixture.close() }
        func waitFor(_ phase: String, _ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            repeat {
                fixture.host.layoutSubtreeIfNeeded()
                await Task.yield()
                fixture.host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await clock.advance(by: 0.020)
            } while ProcessInfo.processInfo.systemUptime < deadline
            XCTFail("Presentation did not finish: \(phase), active=\(active.count), rows=\(rows.count)")
        }
        func checkAX(_ present: Bool, phase: String) {
            for task in [root, child, done] {
                let began = ProcessInfo.processInfo.systemUptime
                let node = ax(fixture.host, id: "task-row:" + task.id)
                axCosts.append((phase, (ProcessInfo.processInfo.systemUptime-began)*1000))
                if present { XCTAssertNotNil(node) } else { XCTAssertNil(node) }
            }
        }
        try await waitFor("initial") { rows.count == 4 && active.isEmpty }
        checkAX(true, phase: "initial-positive")
        let original = try XCTUnwrap(rows.first { $0.task.id == root.id }).frame
        let height = try XCTUnwrap(sectionHeight(groups))
        let guardView = try XCTUnwrap(fixture.descendants(TaskReorderInteractionGuard.GuardView.self).first)
        let point = CGPoint(x: original.midX, y: original.midY)
        let expandedRows = rows
        XCTAssertTrue(guardView.rowFrames.contains { $0.contains(point) },
                      "Expanded tasks must be real native hit regions before testing their removal")
        func assertPaintOnly() {
            XCTAssertEqual(rows.map(\.task.id), [inbox.id], "Transition rows cannot be drag/selection candidates")
            XCTAssertEqual(runtime.pickupFrames(rows).map(\.task.id), [inbox.id], "Native pickup must use the same visible identities")
            XCTAssertEqual(runtime.pickupFrames(expandedRows).map(\.task.id), [inbox.id], "Even stale preferences cannot reactivate a clipped native source")
            for hidden in [root, child, done] {
                runtime.send(.begin(hidden.id, point))
                XCTAssertNil(runtime.drag, "A retained paint-only row must reject drag pickup")
            }
            XCTAssertFalse(guardView.rowFrames.contains { $0.contains(point) },
                           "Hidden rows cannot be native mouse-guard hit regions")
        }
        func flushLayout() async {
            fixture.host.layoutSubtreeIfNeeded()
            await Task.yield()
            fixture.host.layoutSubtreeIfNeeded()
        }

        // Interaction pass: inspect the real AX tree only a few times. Its
        // synchronous traversals must not double as an animation sampler.
        state.setGroupCollapsed(true, id: "work")
        await flushLayout()
        XCTAssertFalse(active.isEmpty)
        assertPaintOnly()
        checkAX(false, phase: "closing")
        let screenPoint = fixture.window.convertPoint(toScreen: fixture.host.convert(point, to: nil))
        let hit = fixture.host.accessibilityHitTest(screenPoint) as? any NSAccessibilityElementProtocol
        XCTAssertFalse([root, child, done].contains { hit?.accessibilityIdentifier?() == "task-row:" + $0.id })
        let closing = try await fixture.capture(scale: fixture.window.backingScaleFactor)
        try XCTUnwrap(closing.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("closing-paint-only.png"))
        try await waitFor("interaction-closed") {
            assertPaintOnly()
            return active.isEmpty && rows.map(\.task.id) == [inbox.id]
        }
        let closedHeight = try XCTUnwrap(sectionHeight(groups))
        XCTAssertLessThan(closedHeight, height)
        XCTAssertGreaterThanOrEqual(closedHeight, 30)
        checkAX(false, phase: "closed")
        state.setGroupCollapsed(false, id: "work")
        await flushLayout()
        XCTAssertFalse(active.isEmpty)
        assertPaintOnly()
        checkAX(false, phase: "opening-interaction")
        try await waitFor("interaction-expanded") {
            active.isEmpty && Set(rows.map(\.task.id)) == [root.id, child.id, done.id, inbox.id]
        }
        checkAX(true, phase: "restored-positive")
        XCTAssertTrue(guardView.rowFrames.contains { $0.contains(point) })

        // Geometry pass: one opening, on this same native window and real task
        // tree. No AX traversal or bitmap capture anywhere in its 220ms window.
        // The callback retains every layout delivery even if a polling task resumes late.
        state.setGroupCollapsed(true, id: "work")
        try await waitFor("geometry-closed") {
            assertPaintOnly()
            return active.isEmpty && rows.map(\.task.id) == [inbox.id]
        }
        let geometryClosedHeight = try XCTUnwrap(sectionHeight(groups))
        XCTAssertEqual(geometryClosedHeight, closedHeight, accuracy: 0.5)
        openingDeliveries.append((ProcessInfo.processInfo.systemUptime, geometryClosedHeight))
        collectOpening = true
        state.setGroupCollapsed(false, id: "work")
        await flushLayout()
        XCTAssertFalse(active.isEmpty)
        assertPaintOnly()
        try await waitFor("geometry-expanded") {
            let presentedHeight = sectionHeight(groups) ?? geometryClosedHeight
            if presentedHeight < height - 0.5 { assertPaintOnly() }
            return active.isEmpty && Set(rows.map(\.task.id)) == [root.id, child.id, done.id, inbox.id]
        }
        collectOpening = false
        let openingHeights = openingDeliveries.map(\.height)
        for (before, after) in zip(openingHeights, openingHeights.dropFirst()) {
            XCTAssertGreaterThanOrEqual(after + 0.5, before, "Opening must not snap fully open and then shrink")
        }
        XCTAssertTrue(openingHeights.contains { $0 > closedHeight + (height-closedHeight)*0.2 && $0 < closedHeight + (height-closedHeight)*0.8 },
                      "Real task expansion must present substantial intermediate heights: \(openingHeights)")
        XCTAssertEqual(try XCTUnwrap(openingHeights.last), height, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(sectionHeight(groups)), height, accuracy: 0.5)
        XCTAssertTrue(guardView.rowFrames.contains { $0.contains(point) })
        checkAX(true, phase: "geometry-end-positive")
        XCTAssertEqual(try model.core.listTasks().count, 4)
        XCTAssertTrue(try XCTUnwrap(try model.core.listTasks().first { $0.id == done.id }).completed)
        try openingHeights.map(String.init(describing:)).joined(separator: "\n").write(to: directory.appendingPathComponent("opening-heights.txt"), atomically: true, encoding: .utf8)
        let deliveries = ["time,height"] + openingDeliveries.map { "\($0.time),\($0.height)" }
        try deliveries.joined(separator: "\n").write(to: directory.appendingPathComponent("delivered-heights.csv"), atomically: true, encoding: .utf8)
        let axTiming = ["phase,ms"] + axCosts.map { "\($0.phase),\($0.ms)" }
        try axTiming.joined(separator: "\n").write(to: directory.appendingPathComponent("ax-durations.csv"), atomically: true, encoding: .utf8)
        try callbackCosts.map(String.init(describing:)).joined(separator: "\n").write(to: directory.appendingPathComponent("callback-cost-ms.txt"), atomically: true, encoding: .utf8)
        var timeline = ["time,id,event,fraction,target,animating"]
        timeline += samples.map { "\($0.uptime),\($0.id),\($0.event),\($0.fraction),\($0.target),\($0.animating)" }
        try timeline.joined(separator: "\n").write(to: directory.appendingPathComponent("interaction-timeline.csv"), atomically: true, encoding: .utf8)
        print("SAMPLING nativeBacking=\(fixture.window.backingScaleFactor), screens=\(NSScreen.screens.count), delivered=\(openingHeights), AX calls=\(axCosts.count), max geometry callback ms=\(callbackCosts.max() ?? 0)")
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testDisclosureReducedMotionSnapsAndNormalMotionRetargetsContinuously() async throws {
        let motion = DisclosureMotion(expanded: true)
        motion.setExpanded(false, reduceMotion: true)
        XCTAssertEqual(motion.fraction, 0)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(motion.fraction, 0)
        motion.setExpanded(true, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(55))
        let before = motion.fraction
        XCTAssertGreaterThan(before, 0); XCTAssertLessThan(before, 1)
        motion.setExpanded(false, reduceMotion: false)
        XCTAssertEqual(motion.fraction, before)
        motion.setExpanded(true, reduceMotion: true)
        XCTAssertEqual(motion.fraction, 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(motion.fraction, 1, "Reduced motion cancels an in-flight clock")
    }
    func testFontPickerNativeFramesShareColumnsAtMinimumWidth() async throws {
        for language in ["zh-CN", "en", "fr", "de", "zh-TW"] {
            let model = try model(language: language)
            for size in [CGSize(width: 800, height: 540), CGSize(width: 800, height: 900), CGSize(width: 880, height: 660)] {
                let height = size.height
                let fixture = NativeRenderingFixture(SettingsWindow(model: model, updater: NativeUpdater(model: model), beginShortcutCapture: {}, endShortcutCapture: { _, _ in }, resetWindowSize: {}), size: size)
                defer { fixture.close() }
                try await Task.sleep(for: .milliseconds(100))
                let popups = fixture.descendants(NSPopUpButton.self).filter { control in
                    DotistFontRole.allCases.contains { role in role.choices.contains { model.text(role.label($0)) == control.title } }
                }
                XCTAssertEqual(popups.count, 4)
                let frames = popups.map { fixture.host.convert($0.bounds, from: $0) }
                print("FEEDBACK FONT \(language), \(height): frames=\(frames), titles=\(popups.map(\.title))")
                for frame in frames.dropFirst() {
                    XCTAssertEqual(frame.minX, frames[0].minX, accuracy: 0.5)
                    XCTAssertEqual(frame.maxX, frames[0].maxX, accuracy: 0.5)
                }
                var pickerTextOrigins: [CGFloat] = []
                for popup in popups {
                    popup.scrollToVisible(popup.bounds)
                    let bitmap = try await fixture.capture(scale: 1)
                    let frame = fixture.host.convert(popup.bounds, from: popup)
                    let required = (popup.title as NSString).size(withAttributes: [.font: popup.font ?? NSFont.systemFont(ofSize: 13)]).width + 28
                    XCTAssertGreaterThanOrEqual(popup.bounds.width, required)
                    let preview = try ink(bitmap, rect: CGRect(x: frame.minX - 118, y: frame.minY, width: 110, height: frame.height))
                    let title = try ink(bitmap, rect: CGRect(x: frame.minX + 8, y: frame.minY, width: frame.width - 32, height: frame.height))
                    pickerTextOrigins.append(title.minX)
                    XCTAssertEqual(preview.midY, title.midY, accuracy: 2.0, "Preview and native picker title share a visual axis: \(language), \(popup.title), \(preview), \(title)")
                    XCTAssertEqual(preview.midY, frame.midY, accuracy: 2.0)
                    XCTAssertLessThan(frame.maxX, size.width - 20)
                }
                for x in pickerTextOrigins.dropFirst() { XCTAssertEqual(x, pickerTextOrigins[0], accuracy: 0.5) }
                let bitmap = try await fixture.capture(scale: 1)
                try save(bitmap, "settings-fonts-\(language)-\(Int(size.width))x\(Int(height))")
            }
        }
    }
    func testNativeSurfaceCompositesFullBackgroundAndPreservesText() async throws {
        var rows = ["scheme,opacity,frost,reduceTransparency,increasedContrast,backgroundAlpha,maxTextAlpha"]
        for scheme in [ColorScheme.light, .dark] {
            for opacity: UInt8 in [0, 4, 38, 95, 100] {
                // accessibility env properties are read-only: exercise the
                // same resolved solid input as FloatingPanelMaterial's OR.
                for protection in [0, 1, 2] {
                    let content = Text("Readable 常态文字").font(.system(size: 16)).foregroundStyle(DotistDesign.ink)
                        .frame(width: 300, height: 120)
                        .background(FloatingPanelSurface(opacity: opacity, frost: 0, compact: false, color: .orange, solid: protection != 0, scheme: scheme))
                        .environment(\.colorScheme, scheme)
                    let fixture = NativeRenderingFixture(content, size: CGSize(width: 300, height: 120))
                    fixture.window.isOpaque = false; fixture.window.backgroundColor = .clear
                    defer { fixture.close() }
                    let bitmap = try await fixture.capture(scale: 1)
                    let background = try XCTUnwrap(bitmap.colorAt(x: 60, y: 25))
                    var maxText: CGFloat = 0
                    for y in 45..<75 { for x in 60..<240 { maxText = max(maxText, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) } }
                    rows.append("\(scheme),\(opacity),0,\(protection == 1),\(protection == 2),\(background.alphaComponent),\(maxText)")
                    if protection == 0 {
                        XCTAssertLessThanOrEqual(background.alphaComponent, CGFloat(opacity) / 100 + 0.015)
                        if opacity >= 95 { XCTAssertGreaterThan(background.alphaComponent, 0.85) }
                    } else { XCTAssertEqual(background.alphaComponent, 1, accuracy: 0.01) }
                    XCTAssertGreaterThan(maxText, 0.9, "Surface opacity must never fade normal text")
                    try save(bitmap, "surface-\(scheme)-\(opacity)-protection\(protection)")
                }
            }
        }
        try rows.joined(separator: "\n").write(to: evidence.appendingPathComponent("surface-composition.csv"), atomically: true, encoding: .utf8)
    }
    func testTransparencyMappingKeepsLegacyOpacityAndCoversEndpoints() throws {
        for opacity: UInt8 in [0, 4, 8, 38, 56, 60, 77, 85, 95, 100] {
            XCTAssertEqual(DotistTransparency.opacity(value: DotistTransparency.value(opacity: opacity)), opacity)
        }
        XCTAssertEqual(DotistTransparency.value(opacity: 4), 96)
        XCTAssertEqual(DotistTransparency.value(opacity: 100), 0)
        XCTAssertEqual(DotistTransparency.opacity(value: 100), 0)
        let model = try model()
        var patch = DotistSettingsPatch(); patch.opacity = 4; patch.sideTabOpacity = 100; patch.idleOpacity = 77
        _ = try model.core.updateSettings(patch)
        let settings = try model.core.settings()
        XCTAssertEqual(settings.opacity, 4); XCTAssertEqual(settings.sideTabOpacity, 100); XCTAssertEqual(settings.idleOpacity, 77)
        patch.opacity = 0; patch.sideTabOpacity = 0; patch.idleOpacity = 100
        let extended = try model.core.updateSettings(patch)
        XCTAssertEqual(extended.opacity, 0); XCTAssertEqual(extended.sideTabOpacity, 0); XCTAssertEqual(extended.idleOpacity, 100)
    }
    func testMaterialOpacityHasNoDarkAlphaFloor() {
        for dark in [false, true] {
            XCTAssertLessThan(DotistDesign.materialOpacity(4, dark: dark, highContrast: false), 0.06)
            XCTAssertGreaterThan(DotistDesign.materialOpacity(95, dark: dark, highContrast: false), 0.9)
            XCTAssertGreaterThanOrEqual(DotistDesign.materialOpacity(4, dark: dark, highContrast: true), 0.96)
        }
    }
}


@MainActor
private final class ActualTaskPanelFixture {
    private final class Backdrop: NSView {
        var color = NSColor.white
        override var isOpaque: Bool { true }
        override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
    }
    let panel: DotistPanel
    let host: DotistHostingView<AnyView>
    private let motion: PanelMotion
    private let backdrop: Backdrop
    init(model: AppModel, state: TaskPanelState, size: CGSize, scheme: ColorScheme, tinted: Bool, origin: CGPoint) {
        panel = DotistPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(width: 320, height: 440)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        motion = PanelMotion(model: model, panel: panel, size: size, title: { "Fixture" }, environment: PanelMotionTestEnvironment().environment)
        host = DotistHostingView(rootView: AnyView(FloatingPanelView(model: model, motion: motion, colorState: state,
            title: "Fixture", remaining: 0, total: 0, groupName: nil, contextMenu: { _, _ in },
            content: MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false))))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        backdrop = Backdrop(frame: host.frame)
        backdrop.color = scheme == .dark
            ? (tinted ? NSColor(srgbRed: 0.10, green: 0.13, blue: 0.18, alpha: 1) : .black)
            : (tinted ? NSColor(srgbRed: 0.95, green: 0.90, blue: 0.85, alpha: 1) : .white)
        backdrop.addSubview(host)
        panel.contentView = backdrop
        host.layoutSubtreeIfNeeded()
    }
    func close() { motion.stop(); panel.makeFirstResponder(nil); panel.close() }
    func descendants<T: NSView>(_ type: T.Type) -> [T] {
        func visit(_ view: NSView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap(visit) }
        return visit(host)
    }
    func capture(scale: CGFloat) async throws -> NSBitmapImageRep {
        await Task.yield()
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(host.bounds.width * scale)), pixelsHigh: Int(ceil(host.bounds.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = raw.retagging(with: panel.colorSpace ?? .sRGB) ?? raw
        image.size = host.bounds.size
        image.bitmapData?.initialize(repeating: 0, count: image.bytesPerRow * image.pixelsHigh)
        backdrop.cacheDisplay(in: backdrop.bounds, to: image)
        return image
    }
}
