import AppKit
import CoreGraphics
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

private final class ProbeVisibility: ObservableObject { @Published var show = true }

private struct ControlProbe<Content: View>: View {
    @ObservedObject var visibility: ProbeVisibility
    let bubble: Content
    let dark: Bool
    var body: some View {
        ZStack { (dark ? Color.black : Color.white); bubble.opacity(visibility.show ? 1 : 0) }
    }
}

private struct ProductionProbe<Content: View>: View {
    @ObservedObject var visibility: ProbeVisibility
    let bubble: Content
    let surface: FloatingSurface
    var body: some View {
        bubble.opacity(visibility.show ? 1 : 0)
            .clipShape(FloatingPanelShape(compact: true, transitioning: false, onRight: true, reveal: 1, base: 48))
            .background(surface)
    }
}

/// Desktop-only diagnostic, using isolated data and the production FloatingBubble.
@MainActor
final class CompactGlassActivationProbeTests: XCTestCase {
    private var artifactRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".cache/glass-tint-material")
    }

    func testContrastMathControls() {
        XCTAssertEqual(ratio(0, 1), 21, accuracy: 0.001)
        XCTAssertEqual(ratio(0.5, 0.5), 1, accuracy: 0.001)
        XCTAssertLessThan(ratio(0.1, 0.12), 4.5)
    }

    func testWeakGlyphUsesIndependentControlMask() throws {
        let dir = artifactRoot.appendingPathComponent("dotist-mask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func bitmap(background: UInt8, ink: UInt8) throws -> URL {
            let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let data = try XCTUnwrap(image.bitmapData)
            for y in 0..<120 { for x in 0..<320 {
                let value = (55..<60).contains(y) && (155..<160).contains(x) ? ink : background
                let offset = y * image.bytesPerRow + x * 4
                data[offset] = value; data[offset + 1] = value; data[offset + 2] = value; data[offset + 3] = 255
            } }
            let file = dir.appendingPathComponent(UUID().uuidString + ".png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: file)
            return file
        }
        let weak = try bitmap(background: 0, ink: 5)
        let blank = try bitmap(background: 0, ink: 0)
        let control = try bitmap(background: 255, ink: 0)
        let controlBlank = try bitmap(background: 255, ink: 255)
        let ordinary = try glyphContrast(image: weak, blank: blank, width: 48)
        let strong = try glyphContrast(image: control, blank: controlBlank, width: 48)
        let masked = try glyphContrast(image: weak, blank: blank, width: 48, maskImage: control, maskBlank: controlBlank)
        XCTAssertLessThan(ordinary.strength, 0.01)
        XCTAssertGreaterThan(strong.ratio, 20)
        XCTAssertLessThan(masked.ratio, 1.1)
    }

    func testDesktopActivationProbe() async throws {
        guard ProcessInfo.processInfo.environment["DOTIST_COMPACT_ACTIVATION_PROBE"] == "1" else {
            throw XCTSkip("Set DOTIST_COMPACT_ACTIVATION_PROBE=1 on the visual-review host")
        }
        let app = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw CompactGlassDesktopEvidence.Failure("No WindowServer screen") }
        guard CGPreflightScreenCaptureAccess() else { throw CompactGlassDesktopEvidence.Failure("Screen Recording permission required; no prompt requested") }
        let original = NSWorkspace.shared.frontmostApplication
        guard let original, original.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw CompactGlassDesktopEvidence.Failure("An independently running frontmost app is required to test real app deactivation")
        }
        let output = artifactRoot.appendingPathComponent("activation-probe-runs/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let events = output.appendingPathComponent("events.log")
        let measurements = output.appendingPathComponent("measurements.txt")
        FileManager.default.createFile(atPath: events.path, contents: nil)
        FileManager.default.createFile(atPath: measurements.path, contents: nil)
        func record(_ file: URL, _ message: String) throws {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((message + "\n").utf8))
            try handle.synchronize()
        }
        func step(_ message: String) throws {
            print("PROBE \(message)")
            try record(events, "\(Date().timeIntervalSince1970) \(message)")
        }
        print("PROBE output=\(output.path)")
        try step("output=\(output.path)")
        let selected = ProcessInfo.processInfo.environment["DOTIST_COMPACT_PROBE_CASE"]
        var selectedCount = 0
        let temp = artifactRoot.appendingPathComponent("dotist-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp); original.activate(options: []) }
        let store = try TaskStore(databasePath: temp.appendingPathComponent("fixture.sqlite").path)
        for _ in 0..<7 { try store.addTask(title: "Review the next small thing") }
        let model = try AppModel(store: store)
        DotistDesign.registerFonts()
        let area = NSRect(x: (screen.visibleFrame.midX - 160).rounded(.down),
                          y: (screen.visibleFrame.midY - 60).rounded(.down), width: 320, height: 120)
        var baselineFailures: [String] = []
        for theme in ["light", "dark"] {
            let scheme: ColorScheme = theme == "light" ? .light : .dark
            for backdrop in ["white", "black", "pattern"] {
                for width in [48, 240] {
                    for variant in ["production", "regular-hosted"] {
                        for activation in ["active-key", "inactive"] {
                            let id = "\(theme)-\(backdrop)-\(width)-\(variant)-\(activation)"
                            if let selected, selected != id { continue }
                            selectedCount += 1
                            try step("\(id) begin")
                            let background = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                            background.isReleasedWhenClosed = false
                            let backdropHost = NSHostingView(rootView: backdropView(backdrop).frame(width: 320, height: 120))
                            backdropHost.sizingOptions = []; backdropHost.frame = NSRect(origin: .zero, size: area.size)
                            background.contentView = backdropHost
                            background.hasShadow = false
                            CompactGlassDesktopEvidence.configure(background, frame: area)
                            let identity = try CompactGlassDesktopEvidence.markBackdrop(background)
                            let rect = NSRect(x: area.midX - CGFloat(width) / 2, y: area.midY - 24, width: CGFloat(width), height: 48)
                            let panel = DotistPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                            panel.isReleasedWhenClosed = false
                            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
                            panel.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
                            var environment = PanelMotion.Environment(); environment.pointerEventsEnabled = false
                            let motion = PanelMotion(model: model, panel: panel, size: rect.size, title: { "Fixture" }, environment: environment)
                            defer {
                                try? step("\(id) cleanup begin")
                                motion.stop(); panel.close(); background.close()
                                try? step("\(id) cleanup end")
                            }
                            let bubble = FloatingBubble(model: model, motion: motion, details: BubbleContent(model: model), groupName: nil, contextMenu: { _, _ in }, width: CGFloat(width), reveal: width == 48 ? 0 : 1)
                                .frame(width: CGFloat(width), height: 48).environment(\.colorScheme, scheme)
                            let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
                            let visibility = ProbeVisibility()
                            let foregroundView: NSView
                            if variant == "production" {
                                let surface = FloatingSurface(opacity: 60, frost: 40, compact: true, transitioning: false, onRight: true, size: rect.size, reveal: 1, color: .none)
                                let host = DotistHostingView(rootView: ProductionProbe(visibility: visibility, bubble: bubble, surface: surface).environment(\.colorScheme, scheme))
                                host.sizingOptions = []; host.frame = container.bounds; host.autoresizingMask = [.width, .height]
                                container.addSubview(host); foregroundView = host
                            } else {
                                let label = DotistHostingView(rootView: bubble)
                                label.sizingOptions = []; label.frame = container.bounds
                                let glass = NSGlassEffectView(frame: container.bounds)
                                glass.style = .regular; glass.cornerRadius = 24; glass.contentView = label
                                glass.autoresizingMask = [.width, .height]; container.addSubview(glass); foregroundView = label
                            }
                            panel.contentView = container
                            CompactGlassDesktopEvidence.configure(panel, frame: rect)
                            background.orderFrontRegardless(); panel.orderFrontRegardless()
                            if activation == "active-key" {
                                app.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
                            } else { original.activate(options: []) }
                            try step("\(id) activation settle await begin")
                            try await Task.sleep(for: .milliseconds(500))
                            try step("\(id) activation settle await end key=\(panel.isKeyWindow) appActive=\(app.isActive)")
                            guard activation == "active-key" ? (app.isActive && panel.isKeyWindow) : !app.isActive else {
                                try step("\(id) activation state unavailable")
                                throw CompactGlassDesktopEvidence.Failure("Could not establish requested real activation state: \(id)")
                            }
                            var foreground: NSColor?
                            panel.effectiveAppearance.performAsCurrentDrawingAppearance { foreground = NSColor(DotistDesign.ink).usingColorSpace(.sRGB) }
                            let ink = foreground.map { "\($0.redComponent),\($0.greenComponent),\($0.blueComponent),\($0.alphaComponent)" } ?? "unresolved"
                            func describeTextViews(_ view: NSView) -> [String] {
                                let own = String(describing: type(of: view)).contains("BubbleTextView")
                                    ? ["type=\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) hidden=\(view.isHidden) appearance=\(view.effectiveAppearance.name.rawValue)"] : []
                                return own + view.subviews.flatMap { describeTextViews($0) }
                            }
                            try step("\(id) textViews=\(describeTextViews(container).joined(separator: " | "))")
                            let path = output.appendingPathComponent(id + ".png")
                            let blank = output.appendingPathComponent(id + "-blank.png")
                            let workspace = NSWorkspace.shared
                            let metadata = "\(id) key=\(panel.isKeyWindow) appActive=\(app.isActive) appearance=\(panel.effectiveAppearance.name.rawValue) hostAppearance=\(foregroundView.effectiveAppearance.name.rawValue) alpha=\(panel.alphaValue) foregroundSRGB=\(ink) reduceTransparency=\(workspace.accessibilityDisplayShouldReduceTransparency) increaseContrast=\(workspace.accessibilityDisplayShouldIncreaseContrast)"
                            try record(measurements, metadata + " status=capture-started")
                            do {
                                try step("\(id) foreground capture begin")
                                try await CompactGlassDesktopEvidence.capture(background: background, foreground: panel,
                                    expectedForegroundFrame: rect, identity: identity, screen: screen,
                                    activeKey: activation == "active-key", to: path)
                                try step("\(id) foreground capture end")
                                if variant == "production" { visibility.show = false } else { foregroundView.isHidden = true }
                                try step("\(id) blank settle await begin")
                                try await Task.sleep(for: .milliseconds(250))
                                try step("\(id) blank settle await end")
                                try step("\(id) blank capture begin")
                                try await CompactGlassDesktopEvidence.capture(background: background, foreground: panel,
                                    expectedForegroundFrame: rect, identity: identity, screen: screen,
                                    activeKey: activation == "active-key", to: blank)
                                try step("\(id) blank capture end")
                                try step("\(id) contrast begin")
                                var result = try glyphContrast(image: path, blank: blank, width: width)
                                try step("\(id) contrast end ratio=\(result.ratio) strength=\(result.strength)")
                                var evidence = "direct"
                                if result.strength <= 0.01 {
                                    // Rehost the same production bubble on an opaque, contrasting control.
                                    // Its pixels locate the real glyph even if the original has near-zero contrast.
                                    try step("\(id) weak signal control setup begin")
                                    let controlVisibility = ProbeVisibility()
                                    let control = DotistHostingView(rootView: ControlProbe(visibility: controlVisibility, bubble: bubble, dark: theme == "dark").environment(\.colorScheme, scheme))
                                    control.sizingOptions = []; control.frame = container.bounds
                                    panel.contentView = control
                                    try step("\(id) weak signal control setup end")
                                    try step("\(id) control settle await begin")
                                    try await Task.sleep(for: .milliseconds(250))
                                    try step("\(id) control settle await end")
                                    let controlPath = output.appendingPathComponent(id + "-control.png")
                                    let controlBlank = output.appendingPathComponent(id + "-control-blank.png")
                                    try step("\(id) control capture begin")
                                    try await CompactGlassDesktopEvidence.capture(background: background, foreground: panel,
                                        expectedForegroundFrame: rect, identity: identity, screen: screen,
                                        activeKey: activation == "active-key", to: controlPath)
                                    try step("\(id) control capture end")
                                    controlVisibility.show = false
                                    try step("\(id) control blank settle await begin")
                                    try await Task.sleep(for: .milliseconds(250))
                                    try step("\(id) control blank settle await end")
                                    try step("\(id) control blank capture begin")
                                    try await CompactGlassDesktopEvidence.capture(background: background, foreground: panel,
                                        expectedForegroundFrame: rect, identity: identity, screen: screen,
                                        activeKey: activation == "active-key", to: controlBlank)
                                    try step("\(id) control blank capture end")
                                    try step("\(id) control contrast begin")
                                    let controlResult = try glyphContrast(image: controlPath, blank: controlBlank, width: width)
                                    try step("\(id) control contrast end ratio=\(controlResult.ratio) strength=\(controlResult.strength)")
                                    guard controlResult.strength > 0.1 && controlResult.ratio >= 4.5 else {
                                        try record(measurements, metadata + " status=inconclusive-control ratio=\(controlResult.ratio) strength=\(controlResult.strength)")
                                        XCTFail("Real label control missing or unreadable: \(id)")
                                        continue
                                    }
                                    try step("\(id) masked contrast begin")
                                    result = try glyphContrast(image: path, blank: blank, width: width, maskImage: controlPath, maskBlank: controlBlank)
                                    try step("\(id) masked contrast end ratio=\(result.ratio) strength=\(result.strength)")
                                    evidence = "control-mask-review-original-foreground"
                                }
                                try record(measurements, metadata + " status=measured contrast=\(result.ratio) signal=\(result.strength) evidence=\(evidence)")
                                if variant == "production" {
                                    if result.ratio < 4.5 { baselineFailures.append("\(id) count: \(result.ratio)") }
                                    if width > 48 {
                                        try step("\(id) title contrast begin")
                                        let title = try glyphContrast(image: path, blank: blank, width: width, title: true)
                                        try record(measurements, metadata + " status=title-measured contrast=\(title.ratio) signal=\(title.strength)")
                                        try step("\(id) title contrast end ratio=\(title.ratio) strength=\(title.strength)")
                                        if title.strength <= 0.01 { baselineFailures.append("\(id) title missing or indiscernible") }
                                        else if title.ratio < 4.5 { baselineFailures.append("\(id) title: \(title.ratio)") }
                                    }
                                    if backdrop == "black" {
                                        try step("\(id) silhouette check begin")
                                        let edge = try silhouetteDifference(blank, width: width)
                                        try record(measurements, metadata + " status=silhouette-measured edgeMinusCorner=\(edge)")
                                        try step("\(id) silhouette check end edgeMinusCorner=\(edge)")
                                        if edge < 0.02 { baselineFailures.append("\(id) top edge indistinguishable from outside corner: \(edge)") }
                                    }
                                }
                                try step("\(id) complete")
                            } catch {
                                try? step("\(id) error=\(String(reflecting: error))")
                                try? record(measurements, metadata + " status=error detail=\(String(reflecting: error))")
                                throw error
                            }
                        }
                    }
                }
            }
        }
        if selected != nil && selectedCount == 0 { XCTFail("Unknown DOTIST_COMPACT_PROBE_CASE: \(selected!)") }
        try step("run complete selectedCount=\(selectedCount) baselineFailures=\(baselineFailures.count)")
        XCTAssertTrue(baselineFailures.isEmpty, "Production count ink contrast below 4.5:1 (core glyph pixels): \(baselineFailures.joined(separator: "; "))")
    }

    private func glyphContrast(image: URL, blank: URL, width: Int, maskImage: URL? = nil, maskBlank: URL? = nil, title: Bool = false) throws -> (ratio: Double, strength: Double) {
        let a = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: image)))
        let b = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: blank)))
        let maskA = try maskImage.map { try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: $0))) } ?? a
        let maskB = try maskBlank.map { try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: $0))) } ?? b
        guard [b, maskA, maskB].allSatisfy({ $0.pixelsWide == a.pixelsWide && $0.pixelsHigh == a.pixelsHigh }) else {
            throw NSError(domain: "capture-dimension-mismatch", code: 1)
        }
        let scale = Double(a.pixelsWide) / 320
        let centerX = (160.0 + Double(width) / 2 - 24) * scale
        let centerY = 60.0 * scale
        var samples: [(mask: Double, delta: Double, ratio: Double)] = []
        let minX = title ? (160.0 - Double(width) / 2 + 12) * scale : centerX - 10 * scale
        let maxX = title ? (160.0 + Double(width) / 2 - 66) * scale : centerX + 10 * scale
        for y in Int(centerY - 14 * scale)..<Int(centerY + 14 * scale) {
            for x in Int(minX)..<Int(maxX) {
                guard let ac = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let bc = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let mc = maskA.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let mb = maskB.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let la = luminance(ac), lb = luminance(bc)
                samples.append((abs(luminance(mc) - luminance(mb)), abs(la - lb), ratio(la, lb)))
            }
        }
        samples.sort { $0.mask > $1.mask }
        guard samples.count >= 10 else { throw NSError(domain: "insufficient-capture-pixels", code: 1) }
        let core = samples.prefix(10)
        return (core.map(\.ratio).sorted()[5], core.map(\.delta).sorted()[5])
    }
    /// On a black backdrop the top-center rim must be distinct from the
    /// outside of the rounded corner. This checks a visible silhouette, not
    /// whether the system's active and inactive optics are identical.
    private func silhouetteDifference(_ path: URL, width: Int) throws -> Double {
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: path)))
        let scale = Double(image.pixelsWide) / 320
        let left = 160.0 - Double(width) / 2
        func sample(_ x: Double, _ y: Double) throws -> Double {
            let color = try XCTUnwrap(image.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
            return luminance(color)
        }
        var edge = 0.0
        for dx in -3...3 { edge += try sample(160 + Double(dx), 37) }
        return edge / 7 - (try sample(left + 1, 37))
    }
    private func luminance(_ color: NSColor) -> Double {
        func linear(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }
    private func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
    private func backdropView(_ name: String) -> some View {
        ZStack {
            name == "black" ? Color.black : Color.white
            if name == "pattern" {
                LinearGradient(colors: [.black, .blue, .orange, .white], startPoint: .leading, endPoint: .trailing)
                HStack(spacing: 16) { ForEach(0..<14) { _ in Rectangle().fill(.white.opacity(0.45)).frame(width: 6) } }.rotationEffect(.degrees(20))
            }
        }.clipped()
    }
}
