import AppKit
import CoreGraphics
import DotistCore
import QuartzCore
import SwiftUI
import XCTest
@testable import DotistApp

/// Opt-in WindowServer experiment. Every image contains only synthetic fixture content.
@MainActor
final class ExpandedGlassDesktopCaptureTests: XCTestCase {
    nonisolated private static var artifactRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/expanded-glass")
    }

    /// Synchronous stderr and JSONL records survive XCTest's buffered output and
    /// identify the exact call boundary even if the runner fails during teardown.
    private final class Trace {
        let directory: URL
        private let file: FileHandle
        private var sequence = 0
        init(kind: String) throws {
            directory = ExpandedGlassDesktopCaptureTests.artifactRoot
                .appendingPathComponent(kind + "/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("events.jsonl")
            guard FileManager.default.createFile(atPath: path.path, contents: nil) else {
                throw CompactGlassDesktopEvidence.Failure("Cannot create fixture trace")
            }
            file = try FileHandle(forWritingTo: path)
            mark("trace.started", facts: ["directory": directory.path,
                "os": ProcessInfo.processInfo.operatingSystemVersionString])
        }
        func mark(_ stage: String, facts: [String: String] = [:]) {
            sequence += 1
            let record: [String: Any] = ["sequence": sequence, "time": Date().timeIntervalSince1970,
                "stage": stage, "mainThread": Thread.isMainThread, "facts": facts]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                var line = data; line.append(0x0a)
                try? file.write(contentsOf: line)
                try? file.synchronize()
                try? FileHandle.standardError.write(contentsOf: line)
            }
        }
        deinit { try? file.close() }
    }

    /// Isolates Foundation.Process from SwiftUI, WindowServer and capture TCC.
    /// Running this under both build systems tests the runner hypothesis.
    func testChildProcessExecution() throws {
        let trace = try Trace(kind: "process-smoke")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        trace.mark("process.run.begin")
        do {
            try process.run()
            trace.mark("process.run.end")
            process.waitUntilExit()
            trace.mark("process.wait.end", facts: ["status": String(process.terminationStatus)])
            XCTAssertEqual(process.terminationStatus, 0)
        } catch {
            trace.mark("process.failed", facts: ["error": String(reflecting: error), "type": String(reflecting: type(of: error))])
            throw error
        }
    }

    /// Separates the throwing async clock used for material settling from both
    /// window creation and child-process execution.
    func testAsyncSettleExecution() async throws {
        let trace = try Trace(kind: "async-smoke")
        trace.mark("settle.begin")
        do {
            try await Task.sleep(for: .milliseconds(500))
            trace.mark("settle.end")
        } catch {
            trace.mark("settle.failed", facts: ["error": String(reflecting: error), "type": String(reflecting: type(of: error))])
            throw error
        }
    }

    /// Exercises the exact native hosting/order/ownership path independently of
    /// capture permission. This is a lifecycle diagnostic, never glass evidence.
    func testWindowLifecycleWithoutCapture() async throws {
        guard ProcessInfo.processInfo.environment["DOTIST_EXPANDED_GLASS_DESKTOP"] == "1" else {
            throw XCTSkip("Set DOTIST_EXPANDED_GLASS_DESKTOP=1 on the visual-review host")
        }
        let trace = try Trace(kind: "window-smoke")
        do {
            try await captureComparisons(trace: trace, capturesEnabled: false)
            trace.mark("window-smoke.completed")
        } catch {
            trace.mark("window-smoke.failed", facts: ["error": String(reflecting: error), "type": String(reflecting: type(of: error))])
            throw error
        }
    }

    private enum Variant: String, CaseIterable {
        case original, reconstructed, noReadingOverlays, noWholeOpacity, noClips, noReadingOverlaysOrClips, productionCandidate
        case productionLowOpacity, productionLowFrost, productionHighFrost, productionNeutral
        case productionTransparent, productionOpaque, backdropControl
        case focusNoManualEdge, focusNativeOnly, focusUniformNativeOpacity
        var focusControl: Bool { self == .focusNoManualEdge || self == .focusNativeOnly || self == .focusUniformNativeOpacity }
        var renderLabel: String {
            switch self {
            case .original: return "frozen-original"
            case .productionCandidate: return "production-current-not-final"
            default: return rawValue
            }
        }
        var overlays: Bool { self == .original || self == .reconstructed || self == .noClips || self == .noWholeOpacity }
        var clips: Bool { self == .original || self == .reconstructed || self == .noReadingOverlays || self == .noWholeOpacity }
        var productionInputs: (opacity: UInt8, frost: UInt8, color: DotistGroupColor)? {
            switch self {
            case .productionCandidate: return (80, 40, .pink)
            case .productionLowOpacity: return (20, 40, .pink)
            case .productionLowFrost: return (20, 0, .pink)
            case .productionHighFrost: return (20, 100, .pink)
            case .productionNeutral: return (80, 40, .none)
            case .productionTransparent: return (0, 40, .pink)
            case .productionOpaque: return (100, 40, .pink)
            default: return nil
            }
        }
    }

    private enum FocusState: String, CaseIterable {
        case unchanged, activeKey = "active-key", activeNonKey = "active-non-key", inactive = "inactive-non-key"
        @MainActor
        func matches(app: NSApplication, panel: NSWindow) -> Bool {
            switch self {
            case .unchanged: return true
            case .activeKey: return app.isActive && panel.isKeyWindow
            case .activeNonKey: return app.isActive && !panel.isKeyWindow
            case .inactive: return !app.isActive && !panel.isKeyWindow
            }
        }
    }

    /// Diagnostic controls only. Production captures always use FloatingSurface.
    /// Reconstruct the current composition to remove one contributor at a time.
    private struct FocusControlSurface: View {
        let variant: Variant
        let scheme: ColorScheme
        var body: some View {
            let clearance = ExpandedReadingMaterial.opticalClearance
            let radius = DotistDesign.windowCornerRadius - clearance
            let amount = DotistDesign.materialOpacity(80, dark: scheme == .dark, highContrast: false)
            let glassAlpha = ExpandedReadingMaterial.glassInteriorAlpha(opacity: 80, frost: 40, dark: scheme == .dark)
            let native = Color.clear.dotistGlass(.regular.tint(DotistTheme.tint(.pink, scheme)),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .padding(clearance)
            ZStack {
                if variant == .focusNativeOnly {
                    native
                } else {
                    if variant == .focusUniformNativeOpacity {
                        native.opacity(amount)
                    } else if glassAlpha >= 0.999 {
                        native
                    } else {
                        native.mask {
                            Color.white.overlay {
                                ExpandedReadingMaterial.interiorMask(cornerRadius: radius)
                                    .padding(clearance)
                                    .opacity(1 - glassAlpha)
                                    .blendMode(.destinationOut)
                            }.compositingGroup()
                        }
                    }
                    ExpandedReadingMaterial(opacity: 80, frost: 40, color: .pink, scheme: scheme, cornerRadius: radius)
                        .applyingBackgroundOpacity(amount).padding(clearance)
                    GlassGloss(shape: RoundedRectangle(cornerRadius: radius, style: .continuous).inset(by: GlassSilhouette.glassClip), intensity: .expanded, scheme: scheme)
                        .padding(clearance)
                    if variant != .focusNoManualEdge {
                        GlassEdge(cornerRadius: radius, compact: false, scheme: scheme, color: .pink).padding(clearance)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DotistDesign.windowCornerRadius, style: .continuous).inset(by: GlassSilhouette.expandedInset))
            .clipShape(FloatingPanelShape(compact: false, transitioning: false, onRight: true, reveal: 1))
        }
    }

    /// Frozen from FloatingSurface.swift before the material change. Keep the
    /// captured original available when productionCandidate evolves.
    private struct OriginalExpandedSurface: View {
        let scheme: ColorScheme
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DotistDesign.windowCornerRadius, style: .continuous)
            Color.clear.glassEffect(.regular.tint(DotistTheme.tint(.pink, scheme)), in: shape)
                .overlay {
                    DotistDesign.paper.opacity(0.8)
                        .overlay(DotistDesign.paper.opacity(0.4 * GlassTintMaterial.expandedFrostScale))
                }
                .overlay(DotistTheme.swatch(.pink).opacity(scheme == .dark ? GlassTintMaterial.expandedDarkTint : GlassTintMaterial.expandedLightTint))
                .overlay { GlassEdge(cornerRadius: DotistDesign.windowCornerRadius, compact: false, scheme: scheme) }
                .opacity(0.8)
                .clipShape(shape)
                .frame(width: 364, height: 620)
                .frame(width: 364, height: 620, alignment: .topTrailing)
                .clipShape(FloatingPanelShape(compact: false, transitioning: false, onRight: true, reveal: 1))
        }
    }

    private struct SyntheticBackdrop: View {
        var body: some View {
            ZStack {
                LinearGradient(colors: [.blue, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 25) { ForEach(0..<20) { _ in Rectangle().fill(.white.opacity(0.22)).frame(width: 10) } }.rotationEffect(.degrees(18))
            }.frame(width: 520, height: 720).clipped()
            // The stripe row's minimum width is 675pt. Attach markers after
            // the final frame so that row cannot expand their layout bounds.
            .overlay {
                VStack {
                    HStack { Color(red: 1, green: 0, blue: 0).frame(width: 32, height: 32); Spacer(); Color(red: 0, green: 1, blue: 0).frame(width: 32, height: 32) }
                    Spacer()
                    HStack { Color(red: 0, green: 0, blue: 1).frame(width: 32, height: 32); Spacer(); Color(red: 1, green: 1, blue: 0).frame(width: 32, height: 32) }
                }.frame(width: 520, height: 720)
            }
        }
    }

    /// Fixed top-left bitmap coordinates, expressed in backdrop points. These
    /// are unchanged from the original 2x capture guard, including its tolerance.
    private let markerPoints: [(name: String, point: CGPoint, rgb: [CGFloat])] = [
        ("top-left", CGPoint(x: 8, y: 8), [1, 0, 0]),
        ("top-right", CGPoint(x: 512, y: 8), [0, 1, 0]),
        ("bottom-left", CGPoint(x: 8, y: 712), [0, 0, 1]),
        ("bottom-right", CGPoint(x: 512, y: 712), [1, 1, 0])
    ]

    /// colorAt returns NSCalibratedRGBColorSpace even for an sRGB bitmap on
    /// this SDK. Converting that NSColor again applies the wrong source profile.
    /// Convert the actual tagged CGImage pixel into explicit sRGB bytes instead.
    private func sRGBPixel(_ image: CGImage, x: Int, y: Int) throws -> [CGFloat] {
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { CGFloat(bytes[$0]) / 255 }
    }

    func testBackdropMarkerLayoutAtCaptureCoordinates() throws {
        let trace = try Trace(kind: "layout-calibration")
        for scale: CGFloat in [1, 2] {
            let renderer = ImageRenderer(content: SyntheticBackdrop())
            renderer.scale = scale
            let cgImage = try XCTUnwrap(renderer.cgImage)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
            try data.write(to: trace.directory.appendingPathComponent("synthetic-layout-\(Int(scale))x.png"))
            // Use the same PNG decode path as the desktop capture, rather than
            // assuming an in-memory render and a tagged screenshot sample alike.
            let image = try XCTUnwrap(NSBitmapImageRep(data: data))
            trace.mark("layout.profiles", facts: ["cgImage": String(describing: image.cgImage?.colorSpace), "bitmap": image.colorSpace.localizedName ?? "unknown"])
            for marker in markerPoints {
                let x = Int(marker.point.x * scale), y = Int(marker.point.y * scale)
                let actual = try sRGBPixel(try XCTUnwrap(image.cgImage), x: x, y: y)
                trace.mark("layout.sample", facts: ["marker": marker.name, "x": String(x), "y": String(y), "scale": String(describing: scale),
                    "actualSRGB": String(describing: actual), "expectedSRGB": String(describing: marker.rgb), "raw": String(describing: image.colorAt(x: x, y: y))])
                for channel in 0..<3 {
                    XCTAssertLessThan(abs(actual[channel] - marker.rgb[channel]), 0.12,
                        "Marker \(marker.name) is not at its fixed capture coordinate \(x),\(y), \(scale)x; actual sRGB \(actual)")
                }
                XCTAssertGreaterThan(actual[3], 0.98)
            }
        }
    }

    /// Reconstructs the existing expanded branch so each switch changes only
    /// one of the two suspected causes. The baseline is the frozen original.
    private struct Experiment: View {
        let variant: Variant
        let scheme: ColorScheme
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DotistDesign.windowCornerRadius, style: .continuous)
            let glass = Color.clear.glassEffect(.regular.tint(DotistTheme.tint(.pink, scheme)), in: shape)
                .overlay {
                    if variant.overlays {
                        DotistDesign.paper.opacity(0.8)
                            .overlay(DotistDesign.paper.opacity(0.4 * GlassTintMaterial.expandedFrostScale))
                    }
                }
                .overlay {
                    if variant.overlays {
                        DotistTheme.swatch(.pink).opacity(scheme == .dark ? GlassTintMaterial.expandedDarkTint : GlassTintMaterial.expandedLightTint)
                    }
                }
                .overlay { GlassEdge(cornerRadius: DotistDesign.windowCornerRadius, compact: false, scheme: scheme) }
                .opacity(variant == .noWholeOpacity ? 1 : 0.8)
            if variant.clips {
                glass.clipShape(shape)
                    .clipShape(FloatingPanelShape(compact: false, transitioning: false, onRight: true, reveal: 1))
            } else {
                glass
            }
        }
    }

    /// Checks that the experimental control preserves the original reading
    /// composition. ImageRenderer is useful for this equality only; it cannot
    /// establish WindowServer glass refraction or the optical edge.
    func testReconstructedControlMatchesOriginalComposition() throws {
        let size = CGSize(width: 364, height: 620)
        for scheme in [ColorScheme.light, .dark] {
            func bitmap<V: View>(_ view: V) throws -> NSBitmapImageRep {
                let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, scheme))
                renderer.scale = 2
                var image: CGImage?
                NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    image = renderer.cgImage
                }
                return NSBitmapImageRep(cgImage: try XCTUnwrap(image))
            }
            let original = try bitmap(OriginalExpandedSurface(scheme: scheme))
            let reconstructed = try bitmap(Experiment(variant: .reconstructed, scheme: scheme))
            var maximum: CGFloat = 0
            for y in stride(from: 0, to: 1240, by: 3) {
                for x in stride(from: 0, to: 728, by: 3) {
                    let a = try XCTUnwrap(original.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let b = try XCTUnwrap(reconstructed.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    maximum = max(maximum, abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                        abs(a.blueComponent - b.blueComponent), abs(a.alphaComponent - b.alphaComponent))
                }
            }
            XCTAssertLessThanOrEqual(maximum, 1.0 / 255, "Experimental control changed the frozen original composition: \(scheme)")
        }
    }

    func testSyntheticExpandedWindowComparisons() async throws {
        guard ProcessInfo.processInfo.environment["DOTIST_EXPANDED_GLASS_DESKTOP"] == "1" else {
            throw XCTSkip("Set DOTIST_EXPANDED_GLASS_DESKTOP=1 on the visual-review host")
        }
        let trace = try Trace(kind: "production-no-shadow")
        do {
            try await captureComparisons(trace: trace)
            trace.mark("test.completed")
        } catch {
            trace.mark("test.failed", facts: ["error": String(reflecting: error), "type": String(reflecting: type(of: error))])
            throw error
        }
    }

    func testProductionExpandedRealFocusStatesWithoutWindowShadow() async throws {
        guard ProcessInfo.processInfo.environment["DOTIST_EXPANDED_GLASS_FOCUS"] == "1" else {
            throw XCTSkip("Set DOTIST_EXPANDED_GLASS_FOCUS=1 on the desktop host")
        }
        let trace = try Trace(kind: "expanded-focus-no-shadow")
        do {
            try await captureComparisons(trace: trace, focusMode: true)
            trace.mark("focus-captures.completed", facts: ["acceptance": "diagnostic evidence only; current material is not final"])
        } catch {
            trace.mark("focus-captures.failed", facts: ["error": String(reflecting: error)])
            throw error
        }
    }

    /// This establishes the diagnostic reconstruction's composition only. Real
    /// focus and WindowServer glass behavior are checked by the opt-in capture.
    func testFocusControlReconstructionMatchesProductionComposition() throws {
        let size = CGSize(width: 364, height: 620)
        for scheme in [ColorScheme.light, .dark] {
            func image<V: View>(_ view: V) throws -> NSBitmapImageRep {
                let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme))
                renderer.scale = 2
                return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            }
            let actual = try image(FloatingPanelSurface(opacity: 80, frost: 40, compact: false, color: .pink, solid: false, scheme: scheme)
                .clipShape(FloatingPanelShape(compact: false, transitioning: false, onRight: true, reveal: 1)))
            let control = try image(FocusControlSurface(variant: .productionCandidate, scheme: scheme))
            for bitmap in [actual, control] {
                let center = try XCTUnwrap(bitmap.colorAt(x: 364, y: 620)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(center.alphaComponent, 0.5, "Composition equality needs a rendered reading backing")
            }
            var maximum: CGFloat = 0
            for y in stride(from: 0, to: 1240, by: 4) { for x in stride(from: 0, to: 728, by: 4) {
                let a = try XCTUnwrap(actual.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let b = try XCTUnwrap(control.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                maximum = max(maximum, abs(a.alphaComponent - b.alphaComponent))
                for (aa, bb) in [(a.redComponent, b.redComponent), (a.greenComponent, b.greenComponent), (a.blueComponent, b.blueComponent)] {
                    maximum = max(maximum, abs(aa * a.alphaComponent - bb * b.alphaComponent))
                }
            } }
            XCTAssertLessThanOrEqual(maximum, 1.0 / 255, "Focus control reconstruction changed production composition: \(scheme)")
        }
    }

    private func captureComparisons(trace: Trace, capturesEnabled: Bool = true, focusMode: Bool = false) async throws {
        trace.mark("application.init.begin")
        let app = NSApplication.shared
        let initiallyActive = app.isActive
        defer { if focusMode && !initiallyActive { app.deactivate() } }
        trace.mark("application.init.end")
        if capturesEnabled {
            trace.mark("capture.preflight.begin")
            guard CGPreflightScreenCaptureAccess() else { throw CompactGlassDesktopEvidence.Failure("Screen Recording permission unavailable; no permission request was made") }
            trace.mark("capture.preflight.passed")
        }
        if focusMode, NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            throw CompactGlassDesktopEvidence.Failure("System accessibility requests an opaque fallback; native-glass focus comparison unavailable. No settings were changed")
        }
        trace.mark("screen.query.begin")
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let primary = try XCTUnwrap(NSScreen.screens.first)
        trace.mark("screen.query.end", facts: ["frame": NSStringFromRect(screen.frame), "visibleFrame": NSStringFromRect(screen.visibleFrame),
            "scale": String(describing: screen.backingScaleFactor)])
        let area = NSRect(x: (screen.visibleFrame.midX - 260).rounded(.down), y: (screen.visibleFrame.midY - 360).rounded(.down), width: 520, height: 720)
        guard screen.visibleFrame.contains(area), screen.backingScaleFactor == 2 else {
            throw CompactGlassDesktopEvidence.Failure("A visible 520x720 point area on a 2x primary display is required")
        }
        let output = trace.directory
        let scheme: ColorScheme = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        print("EXPANDED_GLASS output=\(output.path) capturesEnabled=\(capturesEnabled) systemScheme=\(scheme) opacity=80 frost=40 color=pink displayScale=2")
        trace.mark("conditions", facts: ["scheme": String(describing: scheme), "opacity": "80", "frost": "40", "color": "pink", "scale": "2",
            "reduceTransparency": String(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency),
            "increaseContrast": String(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast),
            "reduceMotion": String(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)])
        trace.mark("backdrop.window.init.begin")
        let background = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        trace.mark("backdrop.window.init.end")
        background.isReleasedWhenClosed = false
        background.hasShadow = false
        defer { trace.mark("backdrop.window.close.begin"); background.close(); trace.mark("backdrop.window.close.end") }
        trace.mark("backdrop.host.init.begin")
        let backdrop = NSHostingView(rootView: SyntheticBackdrop())
        trace.mark("backdrop.host.init.end")
        backdrop.sizingOptions = []; backdrop.frame = NSRect(origin: .zero, size: area.size)
        trace.mark("backdrop.host.attach.begin")
        background.contentView = backdrop
        CompactGlassDesktopEvidence.configure(background, frame: area)
        trace.mark("backdrop.host.attach.end")
        let rect = NSRect(x: area.midX - 182, y: area.midY - 310, width: 364, height: 620)
        trace.mark("foreground.window.init.begin")
        let panel = DotistPanel(contentRect: rect, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        trace.mark("foreground.window.init.end")
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.title = "Synthetic expanded glass fixture (not a Dotist instance)"
        panel.minSize = NSSize(width: 320, height: 440)
        panel.isMovableByWindowBackground = true
        let productionHidesOnDeactivate = panel.hidesOnDeactivate
        let store = try TaskStore(databasePath: trace.directory.appendingPathComponent("synthetic-fixture.sqlite").path)
        let model = try AppModel(store: store)
        let originalActivationPolicy = app.activationPolicy()
        let productionActivationPolicy: NSApplication.ActivationPolicy = model.settings.showDock ? .regular : .accessory
        if focusMode {
            // Match DotistDelegate's isolated-default policy, never a running
            // Dotist instance's preferences. This changes this test process only.
            guard app.setActivationPolicy(productionActivationPolicy) else {
                throw CompactGlassDesktopEvidence.Failure("Cannot establish the fixture process's production activation policy")
            }
        }
        defer { if focusMode { app.setActivationPolicy(originalActivationPolicy) } }
        var motionEnvironment = PanelMotion.Environment()
        motionEnvironment.pointerEventsEnabled = false
        motionEnvironment.mouseLocation = { NSPoint(x: -10000, y: -10000) }
        let motion = PanelMotion(model: model, panel: panel, size: rect.size, title: { "Synthetic fixture" }, environment: motionEnvironment)
        defer { motion.stop() }
        let productionLevel: NSWindow.Level = model.settings.alwaysOnTop ? .floating : .normal
        XCTAssertFalse(panel.hasShadow, "Use PanelMotion's actual production shadow policy")
        let keySink = DotistPanel(contentRect: NSRect(x: screen.visibleFrame.minX + 12, y: screen.visibleFrame.minY + 12, width: 140, height: 60),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        keySink.isReleasedWhenClosed = false; keySink.hasShadow = false
        keySink.title = "Synthetic focus control"
        keySink.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        keySink.ignoresMouseEvents = true
        keySink.contentView = NSHostingView(rootView: Text("Focus control").padding().frame(width: 140, height: 60))
        defer { keySink.close() }
        if focusMode, keySink.frame.intersects(area) {
            throw CompactGlassDesktopEvidence.Failure("Display needs space outside the evidence region for an owned focus-control window")
        }
        func configureProductionPanel() {
            CompactGlassDesktopEvidence.configure(panel, frame: rect)
            // The generic capture helper forces test-only focus defaults. Restore
            // the real DotistPanel defaults and production foreground behavior.
            panel.hidesOnDeactivate = productionHidesOnDeactivate
            panel.ignoresMouseEvents = false
            panel.level = productionLevel
            background.level = productionLevel
        }
        configureProductionPanel()
        trace.mark("production-window-configuration", facts: ["class": "DotistPanel", "windowShadow": String(panel.hasShadow),
            "hidesOnDeactivate": String(panel.hidesOnDeactivate), "canBecomeKey": String(panel.canBecomeKey),
            "canBecomeMain": String(panel.canBecomeMain), "becomesKeyOnlyIfNeeded": String(panel.becomesKeyOnlyIfNeeded),
            "isFloatingPanel": String(panel.isFloatingPanel), "level": String(panel.level.rawValue), "styleMask": String(panel.styleMask.rawValue),
            "role": "production configuration; current rendering not final", "activationPolicy": String(app.activationPolicy().rawValue)])
        defer { trace.mark("foreground.window.close.begin"); panel.close(); trace.mark("foreground.window.close.end") }
        let surfaceSize = rect.size
        var nativeMeans: [Variant: [CGFloat]] = [:]
        var nativePixels: [Variant: [[CGFloat]]] = [:]
        var focusMeasurements: [String: Any] = [:]
        let variants: [Variant] = focusMode ? [.original, .productionCandidate, .focusNoManualEdge, .focusNativeOnly, .focusUniformNativeOpacity]
            : Variant.allCases.filter { !$0.focusControl }
        for variant in variants {
            trace.mark("variant.begin", facts: ["variant": variant.rawValue])
            let surface: AnyView
            switch variant {
            case .original: surface = AnyView(OriginalExpandedSurface(scheme: scheme))
            case .focusNoManualEdge, .focusNativeOnly, .focusUniformNativeOpacity:
                surface = AnyView(FocusControlSurface(variant: variant, scheme: scheme))
            case .backdropControl: surface = AnyView(Color.clear)
            case .productionCandidate, .productionLowOpacity, .productionLowFrost, .productionHighFrost, .productionNeutral, .productionTransparent, .productionOpaque:
                let inputs = try XCTUnwrap(variant.productionInputs)
                trace.mark("variant.production-inputs", facts: ["opacity": String(inputs.opacity), "frost": String(inputs.frost), "color": inputs.color.rawValue])
                surface = AnyView(FloatingSurface(opacity: inputs.opacity, frost: inputs.frost, compact: false, transitioning: false,
                    onRight: true, size: surfaceSize, reveal: 1, color: inputs.color))
            default: surface = AnyView(Experiment(variant: variant, scheme: scheme))
            }
            let content = ZStack(alignment: .topLeading) {
                surface
                VStack(alignment: .leading, spacing: 18) {
                    Text("Reading list").font(.system(size: 25, weight: .semibold))
                    Text("A quiet place for the next small things").font(.system(size: 13))
                    Divider()
                    ForEach(["Review the project notes", "Read a chapter", "Plan the next step", "Send the weekly update"], id: \.self) { title in
                        HStack(spacing: 12) { Image(systemName: "circle"); Text(title); Spacer() }
                            .font(.system(size: 14)).padding(.vertical, 6)
                    }
                    Spacer()
                    Text("Synthetic fixture · no personal tasks").font(.system(size: 11))
                }.foregroundStyle(DotistDesign.ink).padding(24)
            }.frame(width: 364, height: 620).environment(\.colorScheme, scheme)
            trace.mark("foreground.host.init.begin")
            let host = DotistHostingView(rootView: content)
            trace.mark("foreground.host.init.end")
            host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: rect.size)
            trace.mark("foreground.host.attach.begin")
            let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            panel.contentView = container
            configureProductionPanel()
            trace.mark("foreground.host.attach.end")
            for focus in focusMode ? [FocusState.activeKey, .activeNonKey, .inactive] : [.unchanged] {
                let captureName = focusMode ? "\(variant.renderLabel)-\(focus.rawValue)-no-shadow" : variant.rawValue
                trace.mark("backdrop.order.begin")
                background.orderFrontRegardless()
                trace.mark("backdrop.order.end")
                trace.mark("foreground.order.begin")
                panel.orderFrontRegardless(); panel.invalidateShadow()
                trace.mark("foreground.order.end")
                if focusMode {
                    // Only this XCTest process and its owned windows are activated,
                    // resigned or deactivated. Never target another running app/PID.
                    trace.mark("focus.transition.begin", facts: ["requested": focus.rawValue, "variant": variant.renderLabel])
                    switch focus {
                    case .activeKey:
                        keySink.orderOut(nil)
                        app.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
                    case .activeNonKey:
                        app.activate(ignoringOtherApps: true); keySink.makeKeyAndOrderFront(nil)
                    case .inactive:
                        panel.resignKey(); keySink.resignKey(); keySink.orderOut(nil); app.deactivate()
                    case .unchanged: break
                    }
                    for _ in 0..<20 {
                        if focus.matches(app: app, panel: panel), focus != .activeNonKey || keySink.isKeyWindow { break }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    trace.mark("focus.transition.end", facts: ["requested": focus.rawValue, "appActive": String(app.isActive),
                        "panelKey": String(panel.isKeyWindow), "focusControlKey": String(keySink.isKeyWindow),
                        "frontmostPID": String(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)])
                    guard focus.matches(app: app, panel: panel), focus != .activeNonKey || keySink.isKeyWindow else {
                        throw CompactGlassDesktopEvidence.Failure("Could not establish actual native focus state \(focus.rawValue); no environment override was used")
                    }
                }
                trace.mark("render.flush.begin")
                backdrop.layoutSubtreeIfNeeded(); host.layoutSubtreeIfNeeded()
                background.displayIfNeeded(); panel.displayIfNeeded()
                CATransaction.flush()
                trace.mark("render.flush.end")
                trace.mark("settle.begin")
                try await Task.sleep(for: .milliseconds(500))
                trace.mark("settle.end")
                let captureRect = CompactGlassDesktopEvidence.screenRect(area, primaryFrame: primary.frame)
                func checkWindows() throws {
                    guard !panel.hasShadow, panel.alphaValue == 1, background.alphaValue == 1 else {
                        throw CompactGlassDesktopEvidence.Failure("Production no-shadow/alpha configuration changed")
                    }
                    guard focus.matches(app: app, panel: panel), focus != .activeNonKey || keySink.isKeyWindow else {
                        throw CompactGlassDesktopEvidence.Failure("Actual native focus state changed during capture")
                    }
                    guard background.frame == area, panel.frame == rect, background.isVisible, panel.isVisible,
                          background.isOnActiveSpace, panel.isOnActiveSpace,
                          let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
                        trace.mark("ownership.fixture-unavailable", facts: ["backgroundVisible": String(background.isVisible),
                            "panelVisible": String(panel.isVisible), "hidesOnDeactivate": String(panel.hidesOnDeactivate),
                            "requestedFocus": focus.rawValue, "appActive": String(app.isActive), "panelKey": String(panel.isKeyWindow)])
                        throw CompactGlassDesktopEvidence.Failure("Fixture windows unavailable or moved")
                    }
                    func number(_ item: [String: Any], _ key: CFString) -> Int { (item[key as String] as? NSNumber)?.intValue ?? -1 }
                    func bounds(_ item: [String: Any]) -> CGRect? {
                        guard let b = item[kCGWindowBounds as String] as? [String: Any] else { return nil }
                        return CGRect(dictionaryRepresentation: b as CFDictionary)
                    }
                    guard let back = windows.firstIndex(where: { number($0, kCGWindowNumber) == background.windowNumber }),
                          let front = windows.firstIndex(where: { number($0, kCGWindowNumber) == panel.windowNumber }), front < back,
                          bounds(windows[back]) == captureRect,
                          bounds(windows[front]) == CompactGlassDesktopEvidence.screenRect(rect, primaryFrame: primary.frame),
                          [back, front].allSatisfy({ number(windows[$0], kCGWindowOwnerPID) == Int(ProcessInfo.processInfo.processIdentifier) }) else {
                        throw CompactGlassDesktopEvidence.Failure("WindowServer fixture geometry, ownership or ordering differs")
                    }
                    let blockers = windows[..<back].filter { item in
                        number(item, kCGWindowNumber) != panel.windowNumber &&
                        ((item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) != 0 &&
                        (bounds(item)?.intersects(captureRect) ?? true)
                    }
                    guard blockers.isEmpty else {
                        trace.mark("ownership.external-occlusion", facts: ["blockers": blockers.map {
                            "id=\(number($0, kCGWindowNumber)) pid=\(number($0, kCGWindowOwnerPID)) layer=\(number($0, kCGWindowLayer)) bounds=\(bounds($0).map(NSStringFromRect) ?? "unknown")"
                        }.joined(separator: "; "), "action": "clear external interference and rerun on host; capture rejected"])
                        throw CompactGlassDesktopEvidence.Failure("External window interference occludes the synthetic region; capture rejected. Clear the region and rerun on host")
                    }
                }
                trace.mark("ownership.preCapture.begin")
                try checkWindows()
                trace.mark("ownership.preCapture.passed", facts: ["backgroundID": String(background.windowNumber), "foregroundID": String(panel.windowNumber),
                    "backgroundFrame": NSStringFromRect(area), "foregroundFrame": NSStringFromRect(rect), "key": String(panel.isKeyWindow), "active": String(NSApp.isActive),
                    "windowShadow": String(panel.hasShadow)])
                if !capturesEnabled { trace.mark("window-smoke.variant.completed"); continue }
                let path = output.appendingPathComponent(captureName + ".png")
                let pending = output.appendingPathComponent(captureName + ".pending.png")
                defer { try? FileManager.default.removeItem(at: pending) }
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-R\(Int(captureRect.minX)),\(Int(captureRect.minY)),520,720", pending.path]
                trace.mark("capture.process.run.begin")
                try process.run()
                trace.mark("capture.process.run.end")
                process.waitUntilExit()
                trace.mark("capture.process.wait.end", facts: ["status": String(process.terminationStatus)])
                do {
                    guard process.terminationStatus == 0 else { throw CompactGlassDesktopEvidence.Failure("screencapture failed") }
                    trace.mark("ownership.postCapture.begin")
                    try checkWindows()
                    trace.mark("ownership.postCapture.passed")
                    let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: pending)))
                    guard image.pixelsWide == 1040, image.pixelsHigh == 1440 else { throw CompactGlassDesktopEvidence.Failure("Unexpected screenshot dimensions") }
                    let cgImage = try XCTUnwrap(image.cgImage)
                    var samples: [[String: Any]] = []
                    var invalid: [String] = []
                    for marker in markerPoints {
                        let x = Int(marker.point.x * 2), y = Int(marker.point.y * 2)
                        let actual = try sRGBPixel(cgImage, x: x, y: y)
                        let flipped = try sRGBPixel(cgImage, x: x, y: image.pixelsHigh - 1 - y)
                        let matches = (0..<3).allSatisfy { abs(actual[$0] - marker.rgb[$0]) < 0.12 } && actual[3] > 0.98
                        if !matches { invalid.append(marker.name) }
                        samples.append(["marker": marker.name, "bitmapX": x, "bitmapY": y,
                            "backdropPointX": marker.point.x, "backdropPointY": marker.point.y,
                            "expectedSRGB": marker.rgb, "actualSRGBA": actual, "flippedYSRGBA": flipped, "matches": matches])
                        trace.mark("capture.marker.sample", facts: ["marker": marker.name, "x": String(x), "y": String(y),
                            "expectedSRGB": String(describing: marker.rgb), "actualSRGBA": String(describing: actual),
                            "flippedYSRGBA": String(describing: flipped), "matches": String(matches)])
                    }
                    let report: [String: Any] = ["status": invalid.isEmpty ? "verified" : "rejected-not-visual-acceptance",
                        "variant": variant.rawValue, "renderRole": variant.renderLabel,
                        "actualFocus": focus.rawValue, "appActive": app.isActive, "panelKey": panel.isKeyWindow,
                        "windowShadow": panel.hasShadow, "coordinateOrigin": "bitmap-top-left", "scale": 2,
                        "imageWidth": image.pixelsWide, "imageHeight": image.pixelsHigh,
                        "bitmapProfile": image.colorSpace.localizedName ?? "unknown",
                        "cgImageProfile": cgImage.colorSpace?.name.map { $0 as String } ?? "unknown",
                        "screenProfile": screen.colorSpace?.localizedName ?? "unknown", "samples": samples]
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: output.appendingPathComponent(captureName + "-marker-samples.json"))
                    if !invalid.isEmpty {
                        // Retain only four 32pt corner crops, wholly inside the
                        // synthetic backdrop and outside the foreground/shadow.
                        // Recheck ownership immediately before retaining them.
                        try checkWindows()
                        for (name, x, y) in [("top-left", 0, 0), ("top-right", 976, 0),
                                             ("bottom-left", 0, 1376), ("bottom-right", 976, 1376)] {
                            let crop = try XCTUnwrap(cgImage.cropping(to: CGRect(x: x, y: y, width: 64, height: 64)))
                            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]))
                            try data.write(to: output.appendingPathComponent("rejected-not-visual-acceptance-\(captureName)-\(name).png"))
                        }
                        trace.mark("capture.marker.rejected", facts: ["invalidMarkers": invalid.joined(separator: ","),
                            "diagnostics": "four synthetic corner crops only; not visual acceptance"])
                        throw CompactGlassDesktopEvidence.Failure("Backdrop marker missing at \(invalid.joined(separator: ",")); capture rejected; see marker-samples.json")
                    }
                    if focusMode || variant.productionInputs != nil || variant == .backdropControl {
                        // Blank interior ROI, in top-left backdrop points: avoids
                        // text, rim and shadow. Compare RGB, never composite alpha.
                        var sum = [CGFloat](repeating: 0, count: 3), count: CGFloat = 0
                        var pixels: [[CGFloat]] = []
                        for y in stride(from: 400, to: 560, by: 20) {
                            for x in stride(from: 150, to: 370, by: 20) {
                                let pixel = try sRGBPixel(cgImage, x: x * 2, y: y * 2)
                                pixels.append(Array(pixel.prefix(3)))
                                for channel in 0..<3 { sum[channel] += pixel[channel] }
                                count += 1
                            }
                        }
                        let mean = sum.map { $0 / count }
                        nativeMeans[variant] = mean
                        nativePixels[variant] = pixels
                        if focusMode {
                            var edgeRows: [[String: Any]] = []
                            for offset in [-6, 0, 1, 2, 3, 4, 6, 8, 12] {
                                var row = [CGFloat](repeating: 0, count: 3)
                                for x in stride(from: 150, to: 370, by: 20) {
                                    let pixel = try sRGBPixel(cgImage, x: x * 2, y: (50 + offset) * 2)
                                    for channel in 0..<3 { row[channel] += pixel[channel] / 11 }
                                }
                                edgeRows.append(["pointsFromWindowTop": offset, "meanSRGB": row])
                            }
                            let luminance = pixels.map { $0[0] * 0.2126 + $0[1] * 0.7152 + $0[2] * 0.0722 }
                            let average = luminance.reduce(0, +) / CGFloat(luminance.count)
                            let deviation = sqrt(luminance.reduce(0) { $0 + pow($1 - average, 2) } / CGFloat(luminance.count))
                            let measurement: [String: Any] = ["interiorMeanSRGB": mean, "interiorLuminanceDeviation": deviation,
                                "topEdgeProfile": edgeRows, "appActive": app.isActive, "panelKey": panel.isKeyWindow,
                                "windowShadow": panel.hasShadow, "role": variant.renderLabel]
                            focusMeasurements[captureName] = measurement
                            // Preserve each validated case's measurements if a
                            // later focus transition encounters interference.
                            try JSONSerialization.data(withJSONObject: measurement, options: [.prettyPrinted, .sortedKeys])
                                .write(to: output.appendingPathComponent(captureName + "-measurements.json"))
                        }
                        trace.mark("capture.production-interior-rgb", facts: ["variant": variant.rawValue,
                            "meanSRGB": String(describing: mean), "samples": String(describing: count)])
                    }
                    try FileManager.default.moveItem(at: pending, to: path)
                    trace.mark("capture.validated", facts: ["image": path.lastPathComponent])
                } catch { try? FileManager.default.removeItem(at: pending); throw error }
            }
        }
        if capturesEnabled && focusMode {
            try JSONSerialization.data(withJSONObject: ["acceptance": "diagnostic only; current production is not final",
                "purpose": "Separate native focus policy, manual edge and optical-band masking under production no-shadow window semantics",
                "cases": focusMeasurements], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("production-focus-measurements.json"))
        }
        if capturesEnabled && !focusMode {
            func distance(_ a: Variant, _ b: Variant) throws -> CGFloat {
                let a = try XCTUnwrap(nativeMeans[a]), b = try XCTUnwrap(nativeMeans[b])
                return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) }
            }
            let opacity = try distance(.productionCandidate, .productionLowOpacity)
            let frost = try distance(.productionLowFrost, .productionHighFrost)
            let tint = try distance(.productionCandidate, .productionNeutral)
            let transparentPixels = try XCTUnwrap(nativePixels[.productionTransparent])
            let backdropPixels = try XCTUnwrap(nativePixels[.backdropControl])
            XCTAssertEqual(transparentPixels.count, 88); XCTAssertEqual(backdropPixels.count, 88)
            let clearDifference = zip(transparentPixels, backdropPixels).reduce(CGFloat(0)) { total, pair in
                total + zip(pair.0, pair.1).reduce(CGFloat(0)) { $0 + abs($1.0 - $1.1) }
            } / CGFloat(transparentPixels.count)
            let opaquePixels = try XCTUnwrap(nativePixels[.productionOpaque])
            XCTAssertEqual(opaquePixels.count, 88)
            let spreads = try (0..<3).map { channel -> CGFloat in
                let values = opaquePixels.map { $0[channel] }
                return try XCTUnwrap(values.max()) - XCTUnwrap(values.min())
            }
            let opaqueSpread = try XCTUnwrap(spreads.max())
            let report: [String: Any] = ["meanSRGB": Dictionary(uniqueKeysWithValues: nativeMeans.map { ($0.key.rawValue, $0.value) }),
                "opacityRGBDistance": opacity, "frostRGBDistance": frost, "tintRGBDistance": tint,
                "zeroOpacityBackdropPixelDifference": clearDifference, "opaqueInteriorRGBSpread": opaqueSpread,
                "roiInBackdropPoints": [150, 400, 220, 160], "note": "Full native WindowServer composite; alpha is intentionally not the density oracle"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("production-preference-appearance.json"))
            XCTAssertGreaterThan(opacity, 0.03, "Opacity must change the final native appearance")
            XCTAssertGreaterThan(frost, 0.01, "Frost must change the final native appearance")
            XCTAssertGreaterThan(tint, 0.01, "Group tint must change the final native appearance")
            XCTAssertLessThan(opaqueSpread, 0.015, "Full-opacity interior must suppress the patterned backdrop")
        }
    }
}
