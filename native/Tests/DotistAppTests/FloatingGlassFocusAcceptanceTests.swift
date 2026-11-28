import AppKit
import CoreGraphics
import DotistCore
import QuartzCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class FloatingGlassFocusAcceptanceTests: XCTestCase {
    @MainActor
    private struct FormSpec {
        let id: String
        let size: CGSize
        let compact: Bool
        var radius: CGFloat { compact ? 24 : DotistDesign.windowCornerRadius - ExpandedReadingMaterial.opticalClearance }
    }

    private let forms = [
        FormSpec(id: "button", size: CGSize(width: 48, height: 48), compact: true),
        FormSpec(id: "strip", size: CGSize(width: 240, height: 48), compact: true),
        FormSpec(id: "card", size: CGSize(width: 364, height: 620), compact: false)
    ]

    private func fixedBitmap<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let scale: CGFloat = 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: info))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.render { _, draw in draw(context) }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }

    private func alpha(_ image: NSBitmapImageRep, x: Int, y: Int) throws -> CGFloat {
        try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)).alphaComponent
    }

    private func bandPeakAlpha(_ image: NSBitmapImageRep, xs: ClosedRange<Int>, ys: ClosedRange<Int>) throws -> CGFloat {
        var peak: CGFloat = 0
        for y in ys { for x in xs { peak = max(peak, try alpha(image, x: x, y: y)) } }
        return peak
    }

    /// Unified GlassEdge must render identically regardless of focus state while
    /// preserving visible top and bottom specular rims, quiet vertical sides,
    /// pure white pigment, and a completely clear interior across all three forms.
    func testUnifiedGlassEdgeIsFocusInvariantWithTopAndBottomRims() throws {
        for scheme in [ColorScheme.light, .dark] {
            for form in forms {
                let active = try fixedBitmap(
                    GlassEdge(cornerRadius: form.radius, scheme: scheme)
                        .frame(width: form.size.width, height: form.size.height)
                        .environment(\.appearsActive, true),
                    size: form.size
                )
                let inactive = try fixedBitmap(
                    GlassEdge(cornerRadius: form.radius, scheme: scheme)
                        .frame(width: form.size.width, height: form.size.height)
                        .environment(\.appearsActive, false),
                    size: form.size
                )
                let w = active.pixelsWide, h = active.pixelsHigh
                let centerAlpha = try alpha(active, x: w / 2, y: h / 2)
                XCTAssertLessThan(centerAlpha, 0.01, "Unified \(scheme) \(form.id) must not paint interior")

                let activeTop = try bandPeakAlpha(active, xs: (w / 2 - 4)...(w / 2 + 4), ys: 0...5)
                let inactiveTop = try bandPeakAlpha(inactive, xs: (w / 2 - 4)...(w / 2 + 4), ys: 0...5)
                let activeBottom = try bandPeakAlpha(active, xs: (w / 2 - 4)...(w / 2 + 4), ys: (h - 6)...(h - 1))
                let inactiveBottom = try bandPeakAlpha(inactive, xs: (w / 2 - 4)...(w / 2 + 4), ys: (h - 6)...(h - 1))
                let activeRight = try bandPeakAlpha(active, xs: (w - 6)...(w - 1), ys: (h / 2 - 4)...(h / 2 + 4))
                let inactiveRight = try bandPeakAlpha(inactive, xs: (w - 6)...(w - 1), ys: (h / 2 - 4)...(h / 2 + 4))

                XCTAssertEqual(activeTop, inactiveTop, accuracy: 0.005, "\(scheme) \(form.id) top rim must be identical across focus states")
                XCTAssertEqual(activeBottom, inactiveBottom, accuracy: 0.005, "\(scheme) \(form.id) bottom rim must be identical across focus states")
                XCTAssertEqual(activeRight, inactiveRight, accuracy: 0.005, "\(scheme) \(form.id) side rim must be identical across focus states")

                let minTop: CGFloat = scheme == .dark ? 0.30 : 0.70
                let minBottom: CGFloat = scheme == .dark ? 0.20 : 0.50
                XCTAssertGreaterThan(activeTop, minTop, "Unified \(scheme) \(form.id) top rim must remain visible")
                XCTAssertGreaterThan(activeBottom, minBottom, "Unified \(scheme) \(form.id) bottom rim must remain visible")
                XCTAssertGreaterThan(activeBottom, activeRight * 1.4, "Unified \(scheme) \(form.id) bottom rim must lead quiet vertical side")

                var checked = 0
                for y in stride(from: 0, to: h, by: 2) {
                    for x in stride(from: 0, to: w, by: 2) {
                        let a = try XCTUnwrap(active.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        let b = try XCTUnwrap(inactive.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 0.005,
                            "Unified \(scheme) \(form.id) must not differ by focus at (\(x), \(y))")
                        guard a.alphaComponent >= 0.15 else { continue }
                        checked += 1
                        XCTAssertGreaterThan(a.redComponent, 0.95)
                        XCTAssertGreaterThan(a.greenComponent, 0.95)
                        XCTAssertGreaterThan(a.blueComponent, 0.95)
                    }
                }
                XCTAssertGreaterThan(checked, 0)
            }
        }
    }

    /// Opt-in desktop acceptance capture of the three real production floating forms
    /// (button, hover strip, expanded task card) in both light and dark modes,
    /// comparing focused (key) vs unfocused (Finder frontmost).
    func testDesktopProductionFocusAcceptance() throws {
        guard ProcessInfo.processInfo.environment["DOTIST_GLASS_FOCUS_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Set DOTIST_GLASS_FOCUS_ACCEPTANCE=1 on a desktop host with Screen Recording permission")
        }
        let app = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else {
            throw CompactGlassDesktopEvidence.Failure("Screen Recording permission unavailable")
        }
        guard let screen = NSScreen.screens.first, let primary = NSScreen.screens.first else {
            throw CompactGlassDesktopEvidence.Failure("No display available")
        }
        let settledOnly = ProcessInfo.processInfo.environment["DOTIST_GLASS_SETTLED_ONLY"] == "1"
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        func spin(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let event = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
            }
        }
        defer {
            app.setActivationPolicy(originalPolicy)
            previousFrontmost?.activate(options: [])
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let outDir: URL
        if let custom = ProcessInfo.processInfo.environment["DOTIST_GLASS_ACCEPTANCE_OUT"], !custom.isEmpty {
            outDir = URL(fileURLWithPath: custom)
        } else {
            outDir = repoRoot.appendingPathComponent(".cache/glass-focus-acceptance/" + UUID().uuidString)
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let dbDir = outDir.appendingPathComponent("fixture-db")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dbDir) }

        let store = try TaskStore(databasePath: dbDir.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addTask(title: "Review glass rim reflections")
        _ = try store.addTask(title: "Compare focused and unfocused states")
        _ = try store.addTask(title: "Verify dark and light appearances")
        let model = try AppModel(store: store)
        DotistDesign.registerFonts()

        let backdropSize = NSSize(width: 460, height: 700)
        let backdropFrame = NSRect(
            x: (screen.visibleFrame.midX - backdropSize.width / 2).rounded(.down),
            y: (screen.visibleFrame.midY - backdropSize.height / 2).rounded(.down),
            width: backdropSize.width,
            height: backdropSize.height
        )
        let background = NSPanel(contentRect: backdropFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        background.isReleasedWhenClosed = false
        background.hasShadow = false
        background.hidesOnDeactivate = false
        background.level = .statusBar
        background.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        background.ignoresMouseEvents = true
        defer { background.close() }

        var reportLines: [String] = []
        let schemes: [(String, ColorScheme, NSAppearance.Name)] = [
            ("light", .light, .aqua),
            ("dark", .dark, .darkAqua)
        ]

        for (schemeName, scheme, appearanceName) in schemes {
            var patch = DotistSettingsPatch()
            patch.theme = schemeName
            patch.opacity = ProcessInfo.processInfo.environment["DOTIST_CAPTURE_OPACITY"].flatMap(UInt8.init) ?? 80
            patch.frost = ProcessInfo.processInfo.environment["DOTIST_CAPTURE_FROST"].flatMap(UInt8.init) ?? 40
            patch.alwaysOnTop = true
            model.updateSettings(patch)

            let backdrop = ProcessInfo.processInfo.environment["DOTIST_GLASS_BACKDROP"]
            let usePatternBackdrop = backdrop == "pattern"
            let useWarmBackdrop = backdrop == "warm"
            let useGridBackdrop = backdrop == "grid"
            let useDenseTextBackdrop = backdrop == "denseText"
            let useColorfulBackdrop = backdrop == "colorful"
            let backdropView = ZStack {
                if useColorfulBackdrop {
                    LinearGradient(
                        colors: scheme == .dark
                            ? [Color(red: 0.08, green: 0.14, blue: 0.28), Color(red: 0.26, green: 0.12, blue: 0.34), Color(red: 0.08, green: 0.28, blue: 0.26)]
                            : [Color(red: 0.18, green: 0.46, blue: 0.88), Color(red: 0.92, green: 0.42, blue: 0.34), Color(red: 0.16, green: 0.72, blue: 0.58)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    HStack(spacing: 22) {
                        ForEach(0..<14, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(index.isMultiple(of: 2) ? Color.white.opacity(scheme == .dark ? 0.22 : 0.48) : Color.yellow.opacity(scheme == .dark ? 0.28 : 0.52))
                                .frame(width: 18)
                        }
                    }
                    .frame(width: backdropSize.width * 1.5, height: backdropSize.height * 1.5)
                    .rotationEffect(.degrees(-22))
                } else if useDenseTextBackdrop {
                    (scheme == .dark ? Color(red: 0.10, green: 0.11, blue: 0.13) : Color.white)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(0..<38, id: \.self) { row in
                            Text(String(format: "%02d  func compositeLiquidGlass(rim: CGFloat, blur: Double) -> Pixel { // 密集代码窗口对照 #%d", row + 1, row))
                                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                                .foregroundStyle(scheme == .dark
                                    ? (row.isMultiple(of: 3) ? Color.cyan : Color.white.opacity(0.86))
                                    : (row.isMultiple(of: 3) ? Color(red: 0.10, green: 0.28, blue: 0.68) : Color.black.opacity(0.85)))
                                .lineLimit(1)
                        }
                    }
                    .padding(10)
                    .frame(width: backdropSize.width, height: backdropSize.height, alignment: .topLeading)
                } else {
                    (useGridBackdrop ? (scheme == .dark ? Color(red: 0.14, green: 0.16, blue: 0.20) : Color.white)
                     : useWarmBackdrop ? Color(red: 0.95, green: 0.93, blue: 0.90)
                     : scheme == .dark ? Color(red: 0.14, green: 0.16, blue: 0.20)
                     : Color(red: 0.24, green: 0.27, blue: 0.33))
                    if useGridBackdrop {
                        Canvas { context, size in
                            let lineColor = scheme == .dark
                                ? Color.white.opacity(0.08)
                                : Color(red: 226.0 / 255.0, green: 224.0 / 255.0, blue: 220.0 / 255.0)
                            var path = Path()
                            for x in stride(from: CGFloat(23), through: size.width, by: 56) {
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: size.height))
                            }
                            for y in stride(from: CGFloat(14), through: size.height, by: 19) {
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: size.width, y: y))
                            }
                            context.stroke(path, with: .color(lineColor), lineWidth: 1)
                        }
                    }
                    if usePatternBackdrop {
                        HStack(spacing: 18) {
                            ForEach(0..<16, id: \.self) { index in
                                Rectangle()
                                    .fill(index.isMultiple(of: 2) ? Color.orange.opacity(0.75) : Color.cyan.opacity(0.70))
                                    .frame(width: 14)
                            }
                        }
                        .frame(width: backdropSize.width * 1.6, height: backdropSize.height * 1.6)
                        .rotationEffect(.degrees(18))
                    }
                }
            }.frame(width: backdropSize.width, height: backdropSize.height).clipped()
            let backdropHost = NSHostingView(rootView: backdropView)
            backdropHost.sizingOptions = []
            backdropHost.frame = NSRect(origin: .zero, size: backdropSize)
            background.contentView = backdropHost
            background.setFrame(backdropFrame, display: true)
            background.orderFrontRegardless()

            let cardSize = NSSize(width: 364, height: 620)
            let cardOrigin = NSPoint(
                x: (backdropFrame.midX - cardSize.width / 2).rounded(.down),
                y: (backdropFrame.midY - cardSize.height / 2).rounded(.down)
            )
            let panel = DotistPanel(
                contentRect: NSRect(origin: cardOrigin, size: cardSize),
                styleMask: [.borderless, .resizable, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.minSize = NSSize(width: 320, height: 440)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.appearance = NSAppearance(named: appearanceName)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .fullScreenDisallowsTiling]

            let panelState = TaskPanelState()
            var env = PanelMotion.Environment()
            env.pointerEventsEnabled = false
            env.visibleFrame = { _ in backdropFrame }
            let motion = PanelMotion(
                model: model, panel: panel, size: cardSize,
                title: { BubbleContent(model: model, groupID: nil, fallbackTitle: "Dotist", state: panelState).title },
                bubbleContent: { BubbleContent(model: model, groupID: nil, fallbackTitle: "Dotist", state: panelState) },
                environment: env
            )
            defer { motion.stop(); panel.close() }

            let root = FloatingPanelView(
                model: model, motion: motion, colorState: panelState,
                title: "Dotist", remaining: 3, total: 3, groupName: nil,
                contextMenu: { _, _ in },
                content: MainWindow(
                    model: model, state: panelState,
                    showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in },
                    collapse: {}, close: nil, primary: true
                )
            ).environment(\.colorScheme, scheme)

            let host = DotistHostingView(rootView: root)
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: cardSize)
            host.autoresizingMask = [.width, .height]
            let container = NSView(frame: host.frame)
            container.addSubview(host)
            panel.contentView = container
            panel.setFrame(NSRect(origin: cardOrigin, size: cardSize), display: true)
            panel.orderFrontRegardless()

            func setFocus(active: Bool) throws {
                if active {
                    app.activate(ignoringOtherApps: true)
                    panel.makeKeyAndOrderFront(nil)
                } else {
                    panel.resignKey()
                    if let finder {
                        finder.activate(options: [])
                    } else {
                        app.deactivate()
                    }
                }
                for _ in 0..<25 {
                    if active ? (app.isActive && panel.isKeyWindow) : (!app.isActive && !panel.isKeyWindow) { break }
                    spin(0.05)
                }
                guard active ? (app.isActive && panel.isKeyWindow) : (!app.isActive && !panel.isKeyWindow) else {
                    throw CompactGlassDesktopEvidence.Failure("Could not reach active=\(active) state (appActive=\(app.isActive), key=\(panel.isKeyWindow))")
                }
                panel.contentView?.layoutSubtreeIfNeeded()
                panel.displayIfNeeded()
                CATransaction.flush()
                spin(0.35)
            }

            func capturePanel(name: String, margin: CGFloat = 10) throws -> (URL, NSBitmapImageRep) {
                let captureFrame = panel.frame.insetBy(dx: -margin, dy: -margin).integral
                let rect = CompactGlassDesktopEvidence.screenRect(captureFrame, primaryFrame: primary.frame)
                let url = outDir.appendingPathComponent("\(name).png")
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                proc.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", url.path]
                try proc.run()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    throw CompactGlassDesktopEvidence.Failure("screencapture failed for \(name)")
                }
                let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
                return (url, rep)
            }

            func stitch(active: NSBitmapImageRep, inactive: NSBitmapImageRep, vertical: Bool, to url: URL) throws {
                let gap = 16
                let w = vertical ? max(active.pixelsWide, inactive.pixelsWide) : active.pixelsWide + inactive.pixelsWide + gap
                let h = vertical ? active.pixelsHigh + inactive.pixelsHigh + gap : max(active.pixelsHigh, inactive.pixelsHigh)
                let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
                let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info))
                ctx.setFillColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                let aCG = try XCTUnwrap(active.cgImage)
                let bCG = try XCTUnwrap(inactive.cgImage)
                if vertical {
                    ctx.draw(aCG, in: CGRect(x: 0, y: inactive.pixelsHigh + gap, width: active.pixelsWide, height: active.pixelsHigh))
                    ctx.draw(bCG, in: CGRect(x: 0, y: 0, width: inactive.pixelsWide, height: inactive.pixelsHigh))
                } else {
                    ctx.draw(aCG, in: CGRect(x: 0, y: 0, width: active.pixelsWide, height: active.pixelsHigh))
                    ctx.draw(bCG, in: CGRect(x: active.pixelsWide + gap, y: 0, width: inactive.pixelsWide, height: inactive.pixelsHigh))
                }
                let outRep = NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
                try XCTUnwrap(outRep.representation(using: .png, properties: [:])).write(to: url)
            }

            func luma(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Double {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
                return (0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)) * 255.0
            }

            func measure(_ label: String, active a: NSBitmapImageRep, inactive b: NSBitmapImageRep) -> String {
                let w = a.pixelsWide, h = a.pixelsHigh
                let scale = CGFloat(w) / (panel.frame.width + 20)
                let opticalInset = Int((10 + FloatingSurface.compactOpticalInset) * scale + 1)
                let x0 = opticalInset, x1 = w - opticalInset - 1
                let y0 = opticalInset, y1 = h - opticalInset - 1
                let mx = w / 2, my = h / 2
                func peak(_ rep: NSBitmapImageRep, _ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>) -> Double {
                    var m = 0.0
                    for y in ys { for x in xs { m = max(m, luma(rep, x, y)) } }
                    return m
                }
                let topA = peak(a, (mx - 4)...(mx + 4), y0...(y0 + 10))
                let topB = peak(b, (mx - 4)...(mx + 4), y0...(y0 + 10))
                let botA = peak(a, (mx - 4)...(mx + 4), (y1 - 10)...y1)
                let botB = peak(b, (mx - 4)...(mx + 4), (y1 - 10)...y1)
                let leftA = peak(a, x0...(x0 + 10), (my - 4)...(my + 4))
                let leftB = peak(b, x0...(x0 + 10), (my - 4)...(my + 4))
                let rightA = peak(a, (x1 - 10)...x1, (my - 4)...(my + 4))
                let rightB = peak(b, (x1 - 10)...x1, (my - 4)...(my + 4))
                if usePatternBackdrop || useWarmBackdrop || useGridBackdrop {
                    for (edge, focused, unfocused) in [("top", topA, topB), ("bottom", botA, botB),
                                                        ("left", leftA, leftB), ("right", rightA, rightB)] {
                        XCTAssertEqual(focused, unfocused, accuracy: 1, "\(label) \(edge) reflection changed on focus switch")
                    }
                }
                return String(format: "%-13@ | top %5.1f -> %5.1f (%+5.1f) | bot %5.1f -> %5.1f (%+5.1f) | left %5.1f -> %5.1f (%+5.1f) | right %5.1f -> %5.1f (%+5.1f)",
                    label, topA, topB, topB - topA, botA, botB, botB - botA, leftA, leftB, leftB - leftA, rightA, rightB, rightB - rightA)
            }

            func captureForm(_ form: String, compareVertically: Bool = false) throws -> (NSBitmapImageRep, NSBitmapImageRep?) {
                let label = "\(schemeName)-\(form)"
                if settledOnly {
                    panel.orderFrontRegardless()
                    panel.contentView?.layoutSubtreeIfNeeded()
                    panel.displayIfNeeded()
                    CATransaction.flush()
                    spin(0.35)
                    let (_, image) = try capturePanel(name: label)
                    return (image, nil)
                }
                try setFocus(active: true)
                let (_, active) = try capturePanel(name: label + "-active")
                try setFocus(active: false)
                let (_, inactive) = try capturePanel(name: label + "-inactive")
                try stitch(active: active, inactive: inactive, vertical: compareVertically,
                    to: outDir.appendingPathComponent(label + "-compare.png"))
                reportLines.append(measure(label, active: active, inactive: inactive))
                return (active, inactive)
            }

            let (cardActive, cardInactive) = try captureForm("card")
            motion.toggleBubble(in: backdropFrame, animated: false)
            let buttonOrigin = NSPoint(x: (backdropFrame.midX - 24).rounded(.down), y: (backdropFrame.midY - 24).rounded(.down))
            panel.setFrame(NSRect(origin: buttonOrigin, size: NSSize(width: 48, height: 48)), display: true)
            let (btnActive, btnInactive) = try captureForm("button")

            motion.setHover(true, in: backdropFrame)
            spin(0.50)
            let stripSize = panel.frame.size
            XCTAssertGreaterThan(stripSize.width, 48, "The hover strip must open before capture")
            let stripOrigin = NSPoint(x: (backdropFrame.midX - stripSize.width / 2).rounded(.down),
                                      y: (backdropFrame.midY - stripSize.height / 2).rounded(.down))
            panel.setFrame(NSRect(origin: stripOrigin, size: stripSize), display: true)
            let (stripActive, stripInactive) = try captureForm("strip", compareVertically: true)

            if useWarmBackdrop, let cardInactive, let btnInactive, let stripInactive {
                // A small ink-free patch 8 pt left of the common screen center
                // samples the same location in all three production forms.
                func centerRGB(_ image: NSBitmapImageRep, formWidth: CGFloat) throws -> [CGFloat] {
                    let scale = CGFloat(image.pixelsWide) / (formWidth + 20)
                    let x = image.pixelsWide / 2 - Int(8 * scale), y = image.pixelsHigh / 2
                    var sum: [CGFloat] = [0, 0, 0]
                    for sy in (y - 1)...(y + 1) {
                        for sx in (x - 1)...(x + 1) {
                            let c = try XCTUnwrap(image.colorAt(x: sx, y: sy)?.usingColorSpace(.sRGB))
                            sum[0] += c.redComponent
                            sum[1] += c.greenComponent
                            sum[2] += c.blueComponent
                        }
                    }
                    return sum.map { $0 / 9 * 255 }
                }

                let specimens = [("card", cardSize.width, cardActive, cardInactive),
                                 ("button", CGFloat(48), btnActive, btnInactive),
                                 ("strip", stripSize.width, stripActive, stripInactive)]
                let card = try centerRGB(cardActive, formWidth: cardSize.width)
                for (name, width, focused, unfocused) in specimens {
                    let a = try centerRGB(focused, formWidth: width)
                    let b = try centerRGB(unfocused, formWidth: width)
                    for index in a.indices {
                        XCTAssertEqual(a[index], b[index], accuracy: 1, "\(schemeName) \(name) center changed with focus")
                        XCTAssertEqual(a[index], card[index], accuracy: 3, "\(schemeName) \(name) center differs from the expanded card")
                    }
                    reportLines.append("\(schemeName)-\(name) center RGB \(a.map { Int($0.rounded()) })")
                }
            }

            if ProcessInfo.processInfo.environment["DOTIST_GLASS_LAYER_PROBE"] == "1" {
                panel.setFrame(NSRect(origin: cardOrigin, size: cardSize), display: true)
                let radius = DotistDesign.windowCornerRadius - ExpandedReadingMaterial.opticalClearance
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                let amount = Double(model.settings.opacity) / 100
                let reading = ExpandedReadingMaterial(opacity: model.settings.opacity, frost: model.settings.frost,
                    color: .none, scheme: scheme, cornerRadius: radius)
                let specimens: [(String, AnyView)] = [
                    ("bare-material", AnyView(FloatingGlassBackdrop().clipShape(shape))),
                    ("masked-material", AnyView(FloatingGlassBackdrop().clipShape(shape).opacity(amount))),
                    ("reading-only", AnyView(reading.compositingGroup().opacity(amount)))
                ]
                for (label, specimen) in specimens {
                    let probeHost = NSHostingView(rootView: specimen
                        .frame(width: cardSize.width, height: cardSize.height).environment(\.colorScheme, scheme))
                    probeHost.sizingOptions = []
                    panel.contentView = probeHost
                    probeHost.layoutSubtreeIfNeeded()
                    try setFocus(active: true)
                    _ = try capturePanel(name: "\(schemeName)-\(label)")
                }
            }
        }

        let summary = reportLines.joined(separator: "\n") + "\n"
        try summary.write(to: outDir.appendingPathComponent("measurements.txt"), atomically: true, encoding: .utf8)
        print("GLASS_FOCUS_ACCEPTANCE output=\(outDir.path)\n\(summary)")
    }

    /// Opt-in real-screen consecutive frame capture of the visible glass silhouette
    /// during collapse and expand transitions (pre, Frame 0, intermediate frames, end),
    /// measuring the rendered contour pixels rather than NSWindow.frame geometry alone.
    func testDesktopConsecutiveToggleSilhouetteCapture() throws {
        guard ProcessInfo.processInfo.environment["DOTIST_TOGGLE_SILHOUETTE_CAPTURE"] == "1" else {
            throw XCTSkip("Set DOTIST_TOGGLE_SILHOUETTE_CAPTURE=1 on a desktop host with Screen Recording permission")
        }
        let app = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else {
            throw CompactGlassDesktopEvidence.Failure("Screen Recording permission unavailable")
        }
        guard let screen = NSScreen.screens.first else {
            throw CompactGlassDesktopEvidence.Failure("No display available")
        }
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        func spin(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let event = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
            }
        }
        defer {
            app.setActivationPolicy(originalPolicy)
            previousFrontmost?.activate(options: [])
        }

        let outPath = ProcessInfo.processInfo.environment["DOTIST_TOGGLE_SILHOUETTE_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("dotist-toggle-silhouette-\(UUID().uuidString)").path
        let outDir = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let dbDir = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-toggle-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dbDir) }

        let store = try TaskStore(databasePath: dbDir.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addTask(title: "检查开合首帧与连续轮廓")
        _ = try store.addTask(title: "对照 Codex Mini 水光玻璃与薄边")
        let model = try AppModel(store: store)
        var patch = DotistSettingsPatch()
        patch.theme = "light"
        patch.opacity = UInt8(ProcessInfo.processInfo.environment["DOTIST_CAPTURE_OPACITY"].flatMap(Int.init) ?? 100)
        patch.frost = UInt8(ProcessInfo.processInfo.environment["DOTIST_CAPTURE_FROST"].flatMap(Int.init) ?? 31)
        patch.alwaysOnTop = true
        model.updateSettings(patch)
        DotistDesign.registerFonts()

        let backdropSize = NSSize(width: 560, height: 680)
        let backdropFrame = NSRect(
            x: (screen.visibleFrame.midX - backdropSize.width / 2).rounded(.down),
            y: (screen.visibleFrame.midY - backdropSize.height / 2).rounded(.down),
            width: backdropSize.width,
            height: backdropSize.height
        )
        let background = NSPanel(contentRect: backdropFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        background.isReleasedWhenClosed = false
        background.hasShadow = false
        background.hidesOnDeactivate = false
        background.level = .statusBar
        background.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        background.ignoresMouseEvents = true
        defer { background.close() }

        let warmColor = Color(red: 0.90, green: 0.88, blue: 0.83)
        let bgHost = NSHostingView(rootView: warmColor.frame(width: backdropSize.width, height: backdropSize.height))
        bgHost.sizingOptions = []
        bgHost.frame = NSRect(origin: .zero, size: backdropSize)
        background.contentView = bgHost
        background.setFrame(backdropFrame, display: true)
        background.orderFrontRegardless()

        let cardSize = NSSize(width: 454, height: 568)
        let cardOrigin = NSPoint(
            x: (backdropFrame.midX - cardSize.width / 2).rounded(.down),
            y: (backdropFrame.midY - cardSize.height / 2).rounded(.down)
        )
        let panel = DotistPanel(
            contentRect: NSRect(origin: cardOrigin, size: cardSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.minSize = NSSize(width: 320, height: 440)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.appearance = NSAppearance(named: .aqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        defer { panel.close() }

        let panelState = TaskPanelState()
        var pendingDriver: (target: NSRect, completion: @MainActor () -> Void)?
        var env = PanelMotion.Environment()
        env.pointerEventsEnabled = false
        env.visibleFrame = { _ in backdropFrame }
        env.mouseLocation = { NSPoint(x: -10_000, y: -10_000) }
        env.animateFrame = { _, target, _, completion in
            pendingDriver = (target, completion)
        }
        let motion = PanelMotion(model: model, panel: panel, size: cardSize, title: { "Dotist" }, environment: env)
        defer { motion.stop() }

        let root = FloatingPanelView(
            model: model, motion: motion, colorState: panelState,
            title: "Dotist", remaining: 2, total: 2, groupName: nil,
            contextMenu: { _, _ in },
            content: MainWindow(
                model: model, state: panelState,
                showViews: {}, showSearch: {}, showSettings: {},
                showGroupPanel: { _ in }, collapse: { motion.toggleBubble() }
            )
        )
        let host = DotistHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: cardSize)
        host.autoresizingMask = [.width, .height]
        let container = NSView(frame: host.frame)
        container.addSubview(host)
        panel.contentView = container
        panel.setFrame(NSRect(origin: cardOrigin, size: cardSize), display: true)
        app.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        spin(0.35)

        // Fixed anchor crop around the top-right corner of the card/bubble (110x110 pt).
        let anchorRect = NSRect(x: panel.frame.maxX - 96, y: panel.frame.maxY - 96, width: 110, height: 110)
        let screenAnchor = CompactGlassDesktopEvidence.screenRect(anchorRect, primaryFrame: screen.frame)

        func captureAnchor(tag: String) throws -> NSBitmapImageRep {
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
            spin(0.08)
            let tmp = outDir.appendingPathComponent("tmp-\(tag).png")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-x", "-R\(Int(screenAnchor.minX)),\(Int(screenAnchor.minY)),\(Int(screenAnchor.width)),\(Int(screenAnchor.height))", tmp.path]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw CompactGlassDesktopEvidence.Failure("screencapture failed for \(tag)")
            }
            return try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: tmp)))
        }

        // Measure the visible glass contour (brighter than warm backdrop) in pixel coords
        // along the top-right anchor crop (top edge at x = center of bubble, right edge at y = center of bubble).
        func measureVisibleContour(_ img: NSBitmapImageRep) throws -> (topPx: Int, rightPx: Int) {
            let bg = try XCTUnwrap(img.colorAt(x: img.pixelsWide - 4, y: 4)?.usingColorSpace(.sRGB))
            func isGlass(_ x: Int, _ y: Int) -> Bool {
                guard let c = img.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                let bgLum = 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent
                return lum > bgLum + 0.03
            }
            // Bubble center is ~24pt left of right edge and ~24pt below top edge.
            // In our 110x110 crop (anchorRect = maxX - 96 ... maxX + 14), panel.maxX is at x = 96pt = 192px (2x),
            // and panel.maxY is at y = 14pt = 28px (2x) from the top of the crop.
            let sampleX = Int(72 * 2) // 24pt left of panel.maxX
            let sampleY = Int(38 * 2) // 24pt below panel.maxY
            var topPx = -1
            for y in 0..<img.pixelsHigh where isGlass(sampleX, y) { topPx = y; break }
            var rightPx = -1
            for x in stride(from: img.pixelsWide - 1, through: 0, by: -1) where isGlass(x, sampleY) { rightPx = x; break }
            return (topPx, rightPx)
        }

        func stitchStrip(_ frames: [(String, NSBitmapImageRep)], to url: URL) throws {
            let gap = 8
            let w = frames.reduce(0) { $0 + $1.1.pixelsWide } + gap * max(0, frames.count - 1)
            let h = frames.map(\.1.pixelsHigh).max() ?? 1
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info))
            ctx.setFillColor(red: 0.14, green: 0.16, blue: 0.20, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            var x = 0
            for (_, rep) in frames {
                if let cg = rep.cgImage {
                    ctx.draw(cg, in: CGRect(x: x, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
                }
                x += rep.pixelsWide + gap
            }
            let out = NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
            try XCTUnwrap(out.representation(using: .png, properties: [:])).write(to: url)
        }

        var lines: [String] = []
        for phase in ["collapse", "expand"] {
            var captures: [(String, NSBitmapImageRep)] = []
            let pre = try captureAnchor(tag: "\(phase)-pre")
            let preM = try measureVisibleContour(pre)
            captures.append(("pre", pre))
            lines.append("\(phase) pre | win=\(panel.frame) | visibleTopPx=\(preM.topPx) visibleRightPx=\(preM.rightPx)")

            pendingDriver = nil
            motion.toggleBubble(in: backdropFrame)
            let driver = try XCTUnwrap(pendingDriver)
            let f0 = try captureAnchor(tag: "\(phase)-f0")
            let f0M = try measureVisibleContour(f0)
            captures.append(("f0", f0))
            lines.append("\(phase) frame0 | win=\(panel.frame) | visibleTopPx=\(f0M.topPx) visibleRightPx=\(f0M.rightPx)")
            XCTAssertLessThanOrEqual(abs(f0M.topPx - preM.topPx), 1, "\(phase) Frame 0 visible top silhouette must not jump")
            XCTAssertLessThanOrEqual(abs(f0M.rightPx - preM.rightPx), 1, "\(phase) Frame 0 visible right silhouette must not jump")

            let animator = PanelFrameAnimation(window: panel, target: driver.target, duration: 0.34) {}
            for p: Float in [0.2, 0.4, 0.6, 0.8] {
                animator.currentProgress = p
                let img = try captureAnchor(tag: "\(phase)-p\(Int(p * 100))")
                let m = try measureVisibleContour(img)
                captures.append(("p\(Int(p * 100))", img))
                lines.append("\(phase) p=\(Int(p * 100))% | win=\(panel.frame) | visibleTopPx=\(m.topPx) visibleRightPx=\(m.rightPx)")
                XCTAssertLessThanOrEqual(abs(m.topPx - preM.topPx), 1, "\(phase) p=\(p) visible top silhouette must stay anchored")
                XCTAssertLessThanOrEqual(abs(m.rightPx - preM.rightPx), 1, "\(phase) p=\(p) visible right silhouette must stay anchored")
            }
            animator.currentProgress = 1.0
            driver.completion()
            let end = try captureAnchor(tag: "\(phase)-end")
            let endM = try measureVisibleContour(end)
            captures.append(("end", end))
            lines.append("\(phase) end | win=\(panel.frame) | visibleTopPx=\(endM.topPx) visibleRightPx=\(endM.rightPx)")
            XCTAssertLessThanOrEqual(abs(endM.topPx - preM.topPx), 1, "\(phase) settled top silhouette must stay anchored")
            XCTAssertLessThanOrEqual(abs(endM.rightPx - preM.rightPx), 1, "\(phase) settled right silhouette must stay anchored")

            try stitchStrip(captures, to: outDir.appendingPathComponent("\(phase)-frames.png"))
        }

        let reportText = lines.joined(separator: "\n") + "\n"
        try reportText.write(to: outDir.appendingPathComponent("silhouette-frames.txt"), atomically: true, encoding: .utf8)
        print("TOGGLE_SILHOUETTE_CAPTURE output=\(outDir.path)\n\(reportText)")
    }

    /// Opt-in desktop WindowServer capture of the three locked presets (standard 60/40, clear 38/22, ultra 8/4)
    /// and the full (transparency 0%/50%/95%/100%) x (frost 0%/50%/100%) orthogonal matrix over dense-text and
    /// colorful backdrops.
    func testDesktopOpacityFrostCalibrationMatrix() throws {
        guard ProcessInfo.processInfo.environment["DOTIST_OPACITY_FROST_MATRIX"] == "1" else {
            throw XCTSkip("Set DOTIST_OPACITY_FROST_MATRIX=1 on a desktop host with Screen Recording permission")
        }
        let app = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else {
            throw CompactGlassDesktopEvidence.Failure("Screen Recording permission unavailable")
        }
        guard let screen = NSScreen.screens.first else {
            throw CompactGlassDesktopEvidence.Failure("No display available")
        }
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        func spin(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let event = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
            }
        }
        defer {
            app.setActivationPolicy(originalPolicy)
            previousFrontmost?.activate(options: [])
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let outDir: URL
        if let custom = ProcessInfo.processInfo.environment["DOTIST_MATRIX_OUT"], !custom.isEmpty {
            outDir = URL(fileURLWithPath: custom)
        } else {
            outDir = repoRoot.appendingPathComponent(".cache/opacity-frost-matrix/" + UUID().uuidString)
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let dbDir = outDir.appendingPathComponent("fixture-db")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dbDir) }

        let store = try TaskStore(databasePath: dbDir.appendingPathComponent("tasks.sqlite").path)
        _ = try store.addTask(title: "校准主表面透明度全量程遮底")
        _ = try store.addTask(title: "验证高透明与高磨砂正交响应")
        _ = try store.addTask(title: "检查密集文字与彩色底边缘光感")
        let model = try AppModel(store: store)
        DotistDesign.registerFonts()

        let backdropSize = NSSize(width: 440, height: 520)
        let backdropFrame = NSRect(
            x: (screen.visibleFrame.midX - backdropSize.width / 2).rounded(.down),
            y: (screen.visibleFrame.midY - backdropSize.height / 2).rounded(.down),
            width: backdropSize.width,
            height: backdropSize.height
        )
        let background = NSPanel(contentRect: backdropFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        background.isReleasedWhenClosed = false
        background.hasShadow = false
        background.hidesOnDeactivate = false
        background.level = .statusBar
        background.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        background.ignoresMouseEvents = true
        defer { background.close() }

        let cardSize = NSSize(width: 340, height: 420)
        let cardOrigin = NSPoint(
            x: (backdropFrame.midX - cardSize.width / 2).rounded(.down),
            y: (backdropFrame.midY - cardSize.height / 2).rounded(.down)
        )
        let panel = DotistPanel(
            contentRect: NSRect(origin: cardOrigin, size: cardSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.minSize = NSSize(width: 320, height: 400)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        defer { panel.close() }

        let panelState = TaskPanelState()
        var env = PanelMotion.Environment()
        env.pointerEventsEnabled = false
        env.visibleFrame = { _ in backdropFrame }
        let motion = PanelMotion(
            model: model, panel: panel, size: cardSize,
            title: { "Dotist" },
            bubbleContent: { BubbleContent(model: model, groupID: nil, fallbackTitle: "Dotist", state: panelState) },
            environment: env
        )
        defer { motion.stop() }

        func captureCard(name: String) throws -> NSBitmapImageRep {
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
            spin(0.28)
            let captureFrame = panel.frame.insetBy(dx: -16, dy: -16).integral
            let rect = CompactGlassDesktopEvidence.screenRect(captureFrame, primaryFrame: screen.frame)
            let url = outDir.appendingPathComponent("raw-\(name).png")
            defer { try? FileManager.default.removeItem(at: url) }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", url.path]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw CompactGlassDesktopEvidence.Failure("screencapture failed for \(name)")
            }
            return try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
        }

        func renderGrid(cells: [[(label: String, image: NSBitmapImageRep)]], title: String, to url: URL) throws {
            let rows = cells.count
            let cols = cells.first?.count ?? 0
            guard rows > 0, cols > 0 else { return }
            // Downscale 2x retina captures to 0.5x (1x logical) so the composite matrix stays crisp and compact
            let cellW = cells[0][0].image.pixelsWide / 2
            let cellH = cells[0][0].image.pixelsHigh / 2
            let pad = 18
            let headerH = 44
            let labelH = 26
            let totalW = pad + cols * (cellW + pad)
            let totalH = headerH + pad + rows * (cellH + labelH + pad)

            let image = NSImage(size: NSSize(width: totalW, height: totalH))
            image.lockFocus()
            NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: totalW, height: totalH).fill()

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            NSString(string: title).draw(at: NSPoint(x: pad, y: totalH - 32), withAttributes: titleAttrs)

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(white: 0.90, alpha: 1)
            ]

            for r in 0..<rows {
                for c in 0..<cols {
                    let item = cells[r][c]
                    let x = pad + c * (cellW + pad)
                    let topY = totalH - headerH - pad - r * (cellH + labelH + pad)
                    let imgRect = NSRect(x: x, y: topY - labelH - cellH, width: cellW, height: cellH)
                    NSString(string: item.label).draw(at: NSPoint(x: x + 2, y: topY - labelH + 5), withAttributes: labelAttrs)
                    if let cg = item.image.cgImage {
                        NSImage(cgImage: cg, size: NSSize(width: cellW, height: cellH)).draw(in: imgRect)
                    }
                }
            }
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                throw CompactGlassDesktopEvidence.Failure("Failed to encode grid PNG")
            }
            try png.write(to: url)
        }

        let setups: [(id: String, title: String, scheme: ColorScheme, appearance: NSAppearance.Name, themeName: String, colorful: Bool)] = [
            ("light-densetext", "浅色 · 密集代码底", .light, .aqua, "light", false),
            ("light-colorful", "浅色 · 彩色条纹底", .light, .aqua, "light", true),
            ("dark-densetext", "深色 · 密集代码底", .dark, .darkAqua, "dark", false)
        ]

        var metricsLines: [String] = []
        for setup in setups {
            let backdropView = ZStack {
                if setup.colorful {
                    LinearGradient(
                        colors: setup.scheme == .dark
                            ? [Color(red: 0.08, green: 0.14, blue: 0.28), Color(red: 0.26, green: 0.12, blue: 0.34), Color(red: 0.08, green: 0.28, blue: 0.26)]
                            : [Color(red: 0.18, green: 0.46, blue: 0.88), Color(red: 0.92, green: 0.42, blue: 0.34), Color(red: 0.16, green: 0.72, blue: 0.58)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    HStack(spacing: 20) {
                        ForEach(0..<14, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(index.isMultiple(of: 2) ? Color.white.opacity(0.48) : Color.yellow.opacity(0.55))
                                .frame(width: 18)
                        }
                    }
                    .frame(width: backdropSize.width * 1.5, height: backdropSize.height * 1.5)
                    .rotationEffect(.degrees(-22))
                } else {
                    (setup.scheme == .dark ? Color(red: 0.10, green: 0.11, blue: 0.13) : Color.white)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(0..<32, id: \.self) { row in
                            Text(String(format: "%02d  func calibrateGlass(transp: %d%%, frost: %d%%) // 密集对照 #%d", row + 1, row * 3 % 100, row * 7 % 100, row))
                                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                                .foregroundStyle(setup.scheme == .dark
                                    ? (row.isMultiple(of: 3) ? Color.cyan : Color.white.opacity(0.86))
                                    : (row.isMultiple(of: 3) ? Color(red: 0.10, green: 0.28, blue: 0.68) : Color.black.opacity(0.85)))
                                .lineLimit(1)
                        }
                    }
                    .padding(10)
                    .frame(width: backdropSize.width, height: backdropSize.height, alignment: .topLeading)
                }
            }.frame(width: backdropSize.width, height: backdropSize.height).clipped()

            let bgHost = NSHostingView(rootView: backdropView)
            bgHost.sizingOptions = []
            bgHost.frame = NSRect(origin: .zero, size: backdropSize)
            background.contentView = bgHost
            background.setFrame(backdropFrame, display: true)
            background.orderFrontRegardless()

            panel.appearance = NSAppearance(named: setup.appearance)
            let root = FloatingPanelView(
                model: model, motion: motion, colorState: panelState,
                title: "Dotist", remaining: 3, total: 3, groupName: nil,
                contextMenu: { _, _ in },
                content: MainWindow(
                    model: model, state: panelState,
                    showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in },
                    collapse: {}, close: nil, primary: true
                )
            ).environment(\.colorScheme, setup.scheme)
            let host = DotistHostingView(rootView: root)
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: cardSize)
            host.autoresizingMask = [.width, .height]
            let container = NSView(frame: host.frame)
            container.addSubview(host)
            panel.contentView = container
            panel.setFrame(NSRect(origin: cardOrigin, size: cardSize), display: true)
            panel.orderFrontRegardless()
            spin(0.25)

            func apply(opacity: UInt8, frost: UInt8) {
                var patch = DotistSettingsPatch()
                patch.theme = setup.themeName
                patch.opacity = opacity
                patch.frost = frost
                patch.alwaysOnTop = true
                model.updateSettings(patch)
            }

            // 1. Three locked presets
            let presets: [(String, UInt8, UInt8)] = [
                ("标准 (透明40% / 磨砂40%)", 60, 40),
                ("透明玻璃 (透明62% / 磨砂22%)", 38, 22),
                ("极致通透 (透明92% / 磨砂4%)", 8, 4)
            ]
            var presetRow: [(String, NSBitmapImageRep)] = []
            for (label, op, fr) in presets {
                apply(opacity: op, frost: fr)
                let rep = try captureCard(name: "\(setup.id)-preset-\(op)-\(fr)")
                presetRow.append((label, rep))
                let cal = ExpandedGlassCalibration.resolve(opacity: Double(op) / 100, frost: Double(fr) / 100, dark: setup.scheme == .dark, hasGroupColor: false)
                metricsLines.append(String(format: "%@ | %@ | wash=%.3f frost=%.3f inset=%.2f feather=%.2f",
                    setup.id, label, cal.washAlpha, cal.frostAlpha, cal.maskInsetPt, cal.maskFeatherPt))
            }
            try renderGrid(cells: [presetRow], title: "三档预设实拍对照 — \(setup.title)",
                to: outDir.appendingPathComponent("presets-\(setup.id).png"))

            // 2. 4x3 orthogonal matrix: transparency [0%, 50%, 95%, 100%] x frost [0%, 50%, 100%]
            let transparencies: [Int] = [0, 50, 95, 100]
            let frosts: [UInt8] = [0, 50, 100]
            var grid: [[(String, NSBitmapImageRep)]] = []
            for tr in transparencies {
                let op = UInt8(100 - tr)
                var row: [(String, NSBitmapImageRep)] = []
                for fr in frosts {
                    apply(opacity: op, frost: fr)
                    let rep = try captureCard(name: "\(setup.id)-t\(tr)-f\(fr)")
                    row.append(("透明 \(tr)% · 磨砂 \(fr)%", rep))
                }
                grid.append(row)
            }
            try renderGrid(cells: grid, title: "透明度 × 磨砂 正交全量程实拍矩阵 — \(setup.title)",
                to: outDir.appendingPathComponent("matrix-\(setup.id).png"))
        }

        try (metricsLines.joined(separator: "\n") + "\n").write(
            to: outDir.appendingPathComponent("calibration-metrics.txt"), atomically: true, encoding: .utf8
        )
        print("OPACITY_FROST_MATRIX output=\(outDir.path)")
    }
}
