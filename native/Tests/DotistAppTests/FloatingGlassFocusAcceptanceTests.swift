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
                    GlassEdge(cornerRadius: form.radius, compact: form.compact, scheme: scheme)
                        .frame(width: form.size.width, height: form.size.height)
                        .environment(\.appearsActive, true),
                    size: form.size
                )
                let inactive = try fixedBitmap(
                    GlassEdge(cornerRadius: form.radius, compact: form.compact, scheme: scheme)
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
        background.level = .floating
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
            patch.opacity = 80
            patch.frost = 40
            patch.alwaysOnTop = true
            model.updateSettings(patch)

            let backdrop = ProcessInfo.processInfo.environment["DOTIST_GLASS_BACKDROP"]
            let usePatternBackdrop = backdrop == "pattern"
            let useWarmBackdrop = backdrop == "warm"
            let backdropView = ZStack {
                (useWarmBackdrop ? Color(red: 0.95, green: 0.93, blue: 0.90) : scheme == .dark ? Color(red: 0.14, green: 0.16, blue: 0.20) : Color(red: 0.24, green: 0.27, blue: 0.33))
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
            panel.level = .floating
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
                if usePatternBackdrop || useWarmBackdrop {
                    for (edge, focused, unfocused) in [("top", topA, topB), ("bottom", botA, botB),
                                                        ("left", leftA, leftB), ("right", rightA, rightB)] {
                        XCTAssertEqual(focused, unfocused, accuracy: 1, "\(label) \(edge) reflection changed on focus switch")
                    }
                }
                return String(format: "%-13@ | top %5.1f -> %5.1f (%+5.1f) | bot %5.1f -> %5.1f (%+5.1f) | left %5.1f -> %5.1f (%+5.1f) | right %5.1f -> %5.1f (%+5.1f)",
                    label, topA, topB, topB - topA, botA, botB, botB - botA, leftA, leftB, leftB - leftA, rightA, rightB, rightB - rightA)
            }

            // 1. Expanded task card
            try setFocus(active: true)
            let (_, cardActive) = try capturePanel(name: "\(schemeName)-card-active")
            try setFocus(active: false)
            let (_, cardInactive) = try capturePanel(name: "\(schemeName)-card-inactive")
            try stitch(active: cardActive, inactive: cardInactive, vertical: false, to: outDir.appendingPathComponent("\(schemeName)-card-compare.png"))
            reportLines.append(measure("\(schemeName)-card", active: cardActive, inactive: cardInactive))

            // 2. Floating button (collapsed)
            motion.toggleBubble(in: backdropFrame, animated: false)
            // Center button inside backdrop
            let buttonOrigin = NSPoint(x: (backdropFrame.midX - 24).rounded(.down), y: (backdropFrame.midY - 24).rounded(.down))
            panel.setFrame(NSRect(origin: buttonOrigin, size: NSSize(width: 48, height: 48)), display: true)
            spin(0.25)

            try setFocus(active: true)
            let (_, btnActive) = try capturePanel(name: "\(schemeName)-button-active")
            try setFocus(active: false)
            let (_, btnInactive) = try capturePanel(name: "\(schemeName)-button-inactive")
            try stitch(active: btnActive, inactive: btnInactive, vertical: false, to: outDir.appendingPathComponent("\(schemeName)-button-compare.png"))
            reportLines.append(measure("\(schemeName)-button", active: btnActive, inactive: btnInactive))

            // 3. Floating hover strip
            motion.setHover(true, in: backdropFrame)
            spin(0.50)
            // Center strip inside backdrop
            let stripSize = panel.frame.size
            let stripOrigin = NSPoint(x: (backdropFrame.midX - stripSize.width / 2).rounded(.down), y: (backdropFrame.midY - stripSize.height / 2).rounded(.down))
            panel.setFrame(NSRect(origin: stripOrigin, size: stripSize), display: true)
            spin(0.20)

            try setFocus(active: true)
            let (_, stripActive) = try capturePanel(name: "\(schemeName)-strip-active")
            try setFocus(active: false)
            let (_, stripInactive) = try capturePanel(name: "\(schemeName)-strip-inactive")
            try stitch(active: stripActive, inactive: stripInactive, vertical: true, to: outDir.appendingPathComponent("\(schemeName)-strip-compare.png"))
            reportLines.append(measure("\(schemeName)-strip", active: stripActive, inactive: stripInactive))

            if useWarmBackdrop {
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
}
