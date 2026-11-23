import AppKit
import ApplicationServices
import CoreMedia
import ScreenCaptureKit

private struct ProbeFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func windowInfo(_ pid: pid_t? = nil) -> [(CGWindowID, CGRect)] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return list.compactMap { entry in
        guard pid == nil || entry[kCGWindowOwnerPID as String] as? pid_t == pid,
              (entry[kCGWindowAlpha as String] as? Double ?? 0) > 0,
              let id = entry[kCGWindowNumber as String] as? CGWindowID,
              let bounds = entry[kCGWindowBounds as String],
              CFGetTypeID(bounds as CFTypeRef) == CFDictionaryGetTypeID(),
              let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary) else { return nil }
        return (id, frame)
    }
}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

private func button(in node: AXUIElement, expanding: Bool, depth: Int = 0) -> AXUIElement? {
    if attribute(node, kAXRoleAttribute) as? String == kAXButtonRole {
        if expanding {
            let labels = [kAXDescriptionAttribute, kAXTitleAttribute].compactMap { attribute(node, $0) as? String }
            if labels.contains(where: { $0.contains("点击展开") }) { return node }
        } else if attribute(node, kAXIdentifierAttribute) as? String == "toolbar:collapse" {
            return node
        }
    }
    guard depth < 12 else { return nil }
    for child in (attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
        if let match = button(in: child, expanding: expanding, depth: depth + 1) { return match }
    }
    return nil
}

private final class Frames: NSObject, SCStreamOutput, @unchecked Sendable {
    static let margin = 12

    private struct PixelChange {
        var count = 0
        var aboveTwo = 0
        var peak = 0

        mutating func add(_ delta: Int) {
            count += 1
            if delta > 2 { aboveTwo += 1 }
            peak = max(peak, delta)
        }

        var csv: String { "\(count),\(aboveTwo),\(peak)" }
    }

    private let collectDifferences: Bool

    init(collectDifferences: Bool) {
        self.collectDifferences = collectDifferences
    }

    private var previousPixels: [UInt32] = []
    private(set) var differenceRows: [String] = []

    private struct Pixels {
        let fingerprint: UInt64
        let silhouette: Int
        let buttonLuma: Double
        let referenceLuma: Int
    }

    struct Sample {
        let pts: Double
        let status: Int
        let displayTime: UInt64
        let fingerprint: UInt64?
        let silhouette: Int?
        let buttonLuma: Double?
        let referenceLuma: Int?
    }

    let queue = DispatchQueue(label: "dotist.panel-motion.capture")
    private var samples: [Sample] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let status = info[.status] as? Int else { return }
        let pixels = status == SCFrameStatus.complete.rawValue ? buffer.imageBuffer.flatMap { measure($0, at: buffer.presentationTimeStamp.seconds) } : nil
        samples.append(Sample(pts: buffer.presentationTimeStamp.seconds, status: status,
                              displayTime: info[.displayTime] as? UInt64 ?? 0,
                              fingerprint: pixels?.fingerprint, silhouette: pixels?.silhouette,
                              buttonLuma: pixels?.buttonLuma, referenceLuma: pixels?.referenceLuma))
    }

    func snapshot() -> [Sample] { queue.sync { samples } }

    private func measure(_ pixels: CVPixelBuffer, at pts: Double) -> Pixels? {
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let margin = Self.margin
        let captureWidth = CVPixelBufferGetWidth(pixels)
        let captureHeight = CVPixelBufferGetHeight(pixels)
        let width = captureWidth - 2 * margin
        let height = captureHeight - 2 * margin
        let artwork = base.advanced(by: margin * rowBytes + margin * 4)
        if collectDifferences {
            comparePixels(base, width: captureWidth, height: captureHeight, rowBytes: rowBytes, at: pts)
        }
        var hash: UInt64 = 14695981039346656037
        for y in stride(from: 8, to: height, by: 2) {
            for x in stride(from: 8, to: width, by: 4) {
                hash = (hash ^ UInt64(artwork.load(fromByteOffset: y * rowBytes + x * 4, as: UInt32.self))) &* 1099511628211
            }
        }
        // Track the lower edge in a narrow band inside the right-anchored bubble.
        // The bottom row is the uncovered stripe background at every size.
        let columns = stride(from: width - 32, to: width - 15, by: 4)
        var lowerEdge = 0
        for y in stride(from: height - 3, through: 8, by: -1) {
            let changed = columns.filter { x in
                let offset = x * 4
                let distance = (0..<3).reduce(0) { sum, channel in
                    let sample = artwork.load(fromByteOffset: y * rowBytes + offset + channel, as: UInt8.self)
                    let stripe = artwork.load(fromByteOffset: (height - 1) * rowBytes + offset + channel, as: UInt8.self)
                    return sum + abs(Int(sample) - Int(stripe))
                }
                return distance >= 42
            }.count
            if changed >= 4 {
                lowerEdge = y + 1
                break
            }
        }
        // Collapse toolbar button: average only its central 24pt square.
        var buttonSum = 0
        for y in 10..<34 {
            for x in (width - 36)..<(width - 12) {
                let pixel = artwork.load(fromByteOffset: y * rowBytes + x * 4, as: UInt32.self)
                buttonSum += Int((pixel >> 8) & 255)
            }
        }
        let reference = Int((base.load(fromByteOffset: 24 * rowBytes + 4 * 4, as: UInt32.self) >> 8) & 255)
        return Pixels(fingerprint: hash, silhouette: lowerEdge,
                      buttonLuma: Double(buttonSum) / 576, referenceLuma: reference)
    }

    // Report RGB deltas in concentric regions around the final 48pt bubble.
    // The icon region includes the glass behind it. The exterior includes shadow.
    private func comparePixels(_ base: UnsafeMutableRawPointer, width: Int, height: Int, rowBytes: Int, at pts: Double) {
        let centerX = width - Self.margin - 24
        let centerY = Self.margin + 24
        let hasPrevious = previousPixels.count == width * height
        if !hasPrevious { previousPixels = .init(repeating: 0, count: width * height) }
        var regions = Array(repeating: PixelChange(), count: 5)
        for y in 0..<height {
            let dy = y - centerY
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let index = y * width + x
                let current = row[x] & 0x00ff_ffff
                let previous = previousPixels[index]
                previousPixels[index] = current
                guard hasPrevious, current != previous else { continue }
                let dx = x - centerX
                let distance = dx * dx + dy * dy
                let region: Int
                switch distance {
                case ...144: region = 0
                case ...484: region = 1
                case ...625: region = 2
                case ...1225: region = 3
                default: region = 4
                }
                let blue = abs(Int(current & 255) - Int(previous & 255))
                let green = abs(Int((current >> 8) & 255) - Int((previous >> 8) & 255))
                let red = abs(Int(current >> 16) - Int(previous >> 16))
                regions[region].add(max(blue, green, red))
            }
        }
        if hasPrevious {
            differenceRows.append(([String(pts)] + regions.map(\.csv)).joined(separator: ","))
        }
    }

}

@MainActor
private final class DisplayClock: NSObject {
    private var link: CADisplayLink?
    private(set) var targets: [CFTimeInterval] = []

    var onTick: ((Int) -> Void)?

    func start(on screen: NSScreen) {
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        targets.append(link.targetTimestamp)
        onTick?(targets.count)
    }
}

private final class ClickProbePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class Stripes: NSView {
    private(set) var clicks = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicks += 1 }

    override func draw(_ rect: NSRect) {
        for x in stride(from: 0, to: Int(bounds.width), by: 20) {
            let blue = x.isMultiple(of: 40)
            NSColor(calibratedRed: blue ? 0.42 : 0.9, green: blue ? 0.59 : 0.84, blue: blue ? 0.79 : 0.72, alpha: 1).setFill()
            CGRect(x: CGFloat(x), y: 0, width: 20, height: bounds.height).fill()
        }
    }
}

@main
private enum InstalledPanelCapture {
    private static let preferencesID = "com.dotist.app" as CFString
    private static let preferenceKeys = ["dotist.native.window.x", "dotist.native.window.y",
                                         "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUScheduledCheckInterval",
                                         "SULastCheckTime", "SUHasLaunchedBefore", "SUUpdateGroupIdentifier"]

    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--restore-test-preferences"]) {
            exit(restorePreferencesFromInput() ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if CommandLine.arguments.dropFirst().first != "--capture-child" {
            exit(runWithPreferenceRestoration())
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            do {
                try await run()
                exit(EXIT_SUCCESS)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        app.run()
    }

    @MainActor
    private static func restorePreferencesFromInput() -> Bool {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              Set(saved.keys).isSubset(of: preferenceKeys) else { return false }
        let absent = preferenceKeys.filter { saved[$0] == nil }
        CFPreferencesSetMultiple(saved as CFDictionary, absent as CFArray, preferencesID,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesSynchronize(preferencesID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func readPreferenceFile(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let domain = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return domain.filter { preferenceKeys.contains($0.key) }
    }

    private static func restorePreferences(_ saved: [String: Any]) -> Bool {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
            // Use a fresh preferences client after the test process exits. The
            // capture process may still cache the pre-launch values.
            let child = Process()
            let input = Pipe()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            child.arguments = ["--restore-test-preferences"]
            child.standardInput = input
            try child.run()
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
            child.waitUntilExit()
            return child.terminationStatus == EXIT_SUCCESS
        } catch {
            return false
        }
    }

    private static func runWithPreferenceRestoration() -> Int32 {
        let preferencesFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.dotist.app.plist")
        let persisted = readPreferenceFile(preferencesFile)
        let saved = persisted ?? (CFPreferencesCopyMultiple(preferenceKeys as CFArray, preferencesID,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:])
        // Exit the AppKit capture process as well as the test application
        // before writing the saved values back through a fresh client.
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        capture.arguments = ["--capture-child"] + CommandLine.arguments.dropFirst()
        do { try capture.run() }
        catch {
            fputs("无法启动桌面采集进程\n", stderr)
            return EXIT_FAILURE
        }
        capture.waitUntilExit()
        guard restorePreferences(saved) else {
            fputs("测试结束后窗口和更新偏好恢复失败\n", stderr)
            return EXIT_FAILURE
        }
        if persisted != nil {
            for _ in 0..<100 {
                if let current = readPreferenceFile(preferencesFile),
                   NSDictionary(dictionary: current).isEqual(to: saved) {
                    return capture.terminationStatus
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            fputs("窗口和更新偏好未在时限内写回磁盘\n", stderr)
            return EXIT_FAILURE
        }
        return capture.terminationStatus
    }

    @MainActor
    private static func run() async throws {
        let args = [CommandLine.arguments[0]] + CommandLine.arguments.dropFirst(2)
        let paired = args.count == 5 && args[4] == "--paired-reference"
        let referenceCapture = paired || (args.count == 5 && ["--display-reference", "--button"].contains(args[4]))
        let holdButton = args.count == 5 && args[4] == "--button"
        let mouseClicks = referenceCapture || (args.count == 5 && args[4] == "--mouse")
        let verifyHost = args.count == 5 && args[4] == "--verify-host"
        let verifyPress = args.count == 5 && args[4] == "--verify-press"
        guard (args.count == 4 || mouseClicks || verifyHost || verifyPress), let rounds = Int(args[3]), (1...30).contains(rounds) else {
            throw ProbeFailure("用法：capture <签名的 Dotist.app> <新输出目录> <轮数> [--mouse|--display-reference|--paired-reference|--button|--verify-host|--verify-press]")
        }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(), let screen = NSScreen.main,
              let displayID = screen.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ProbeFailure("需要有辅助功能、屏幕录制权限的桌面会话")
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, screen.maximumFramesPerSecond > 0 else {
            throw ProbeFailure("需要启用系统动画并使用可报告刷新率的显示器")
        }
        let bundleURL = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
        guard let bundle = Bundle(url: bundleURL), bundle.bundleIdentifier == "com.dotist.app",
              let executable = bundle.executableURL?.resolvingSymlinksInPath() else {
            throw ProbeFailure("请提供已打包的 Dotist.app")
        }

        let output = URL(fileURLWithPath: args[2])
        let files = FileManager.default
        guard mkdir(output.path, S_IRWXU) == 0 else {
            throw ProbeFailure("无法创建新输出目录：\(output.path)")
        }
        let data = output.appendingPathComponent("data", isDirectory: true)
        let home = output.appendingPathComponent("home", isDirectory: true)
        try files.createDirectory(at: data, withIntermediateDirectories: false)
        try files.createDirectory(at: home.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            "theme": "light", "language": "zh-CN", "opacity": 82, "frost": 68,
            "window_width": 454, "window_height": 568, "always_on_top": true,
            "auto_check_updates": false, "auto_install_updates": false,
            "auto_collapse": false, "idle_fade": false, "hover_expand": true, "mcp_enabled": false
        ]
        try JSONSerialization.data(withJSONObject: settings).write(to: data.appendingPathComponent("settings.json"))

        let visible = screen.visibleFrame
        guard visible.width >= 490, visible.height >= 620 else { throw ProbeFailure("显示器可见区域太小") }
        let target = CGRect(x: floor(visible.maxX - 470), y: floor(visible.maxY - 584), width: 454, height: 568)
        let backdrop = ClickProbePanel(contentRect: target.insetBy(dx: -12, dy: -12), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.hidesOnDeactivate = false
        backdrop.ignoresMouseEvents = true
        let stripes = Stripes(frame: backdrop.contentLayoutRect)
        backdrop.contentView = stripes
        backdrop.orderFrontRegardless()
        defer { backdrop.close() }

        let launch = NSWorkspace.OpenConfiguration()
        launch.activates = true
        launch.createsNewApplicationInstance = true
        launch.addsToRecentItems = false
        launch.environment = ["DOTIST_DATA_DIR": data.path, "CFFIXED_USER_HOME": home.path]
        launch.arguments = ["-dotist.native.window.x", String(Double(target.minX)),
                            "-dotist.native.window.y", String(Double(target.minY))]
        let previousApp = NSWorkspace.shared.frontmostApplication
        let existingPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let app = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: launch)
        guard !existingPIDs.contains(app.processIdentifier),
              app.executableURL?.resolvingSymlinksInPath() == executable else {
            throw ProbeFailure("启动进程与指定安装包不符")
        }
        defer {
            if !app.isTerminated { app.terminate() }
            previousApp?.activate()
        }
        let pid = app.processIdentifier
        let ax = AXUIElementCreateApplication(pid)
        try await Task.sleep(for: .seconds(2))
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            app.activate()
            try await Task.sleep(for: .milliseconds(300))
        }
        guard let (windowID, expanded) = windowInfo(pid).first(where: { $0.1.size == target.size }),
              let dbSize = try? data.appendingPathComponent("tasks.sqlite").resourceValues(forKeys: [.fileSizeKey]).fileSize,
              dbSize > 0 else { throw ProbeFailure("未检测到展开面板和独立任务库") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID && $0.frame.contains(expanded) }) else {
            throw ProbeFailure("测试面板必须完整位于所选显示器")
        }
        let included = content.windows.filter { [windowID, CGWindowID(backdrop.windowNumber)].contains($0.windowID) }
        guard included.count == 2 else { throw ProbeFailure("未找到目标面板或条纹背景") }
        let windowFilter = SCContentFilter(display: display, including: included)
        let filter = referenceCapture
            ? SCContentFilter(display: display, excludingWindows: [])
            : windowFilter
        let config = SCStreamConfiguration()
        let captureRect = expanded.insetBy(dx: -CGFloat(Frames.margin), dy: -CGFloat(Frames.margin))
        guard display.frame.contains(captureRect) else { throw ProbeFailure("采集外缘必须完整位于同一显示器") }
        config.sourceRect = captureRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(captureRect.width)
        config.height = Int(captureRect.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(screen.maximumFramesPerSecond))
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        // Put the reference in its own click-through window. The original
        // filtered stream excludes it, so it cannot force extra window frames.
        let referencePanel: NSPanel? = referenceCapture ? makeReferencePanel(
            at: NSPoint(x: screen.frame.minX + config.sourceRect.minX + 1,
                        y: screen.frame.maxY - config.sourceRect.minY - 30)) : nil
        defer { referencePanel?.close() }

        let collapsed = CGRect(x: expanded.maxX - 48, y: expanded.minY, width: 48, height: 48)
        let originalPointer = CGEvent(source: nil)?.location
        defer {
            if mouseClicks, let originalPointer, let current = CGEvent(source: nil)?.location,
               collapsed.contains(current) {
                movePointer(to: originalPointer)
            }
        }
        print("进程 \(pid)，显示器最高 \(screen.maximumFramesPerSecond) Hz，展开区域 \(expanded)")
        if mouseClicks {
            // A physical click is preceded by pointer motion. Posting only a
            // down event at a different coordinate omits AppKit's hover update.
            movePointer(to: CGPoint(x: collapsed.midX, y: expanded.minY + 22))
            try await Task.sleep(for: .milliseconds(180))
        }
        var mouseDown: Double?
        for round in 1...rounds {
            for expanding in [false, true] {
                let kind = expanding ? "expand" : "collapse"
                let differences = expanding || referenceCapture ? nil : output.appendingPathComponent("pixels-\(round).csv")
                let result = try await capture(filter: filter, config: config, screen: screen, differences: differences,
                                               reference: referencePanel?.contentView?.layer,
                                               pairedFilter: paired ? windowFilter : nil, mouseDown: { mouseDown }) {
                    if mouseClicks {
                        // The default toolbar's fixed collapse button is centered 24pt
                        // from the right edge and 22pt from the top of the header.
                        let point = CGPoint(x: collapsed.midX, y: expanded.minY + (expanding ? 24 : 22))
                        let click = try await click(at: point, pid: pid, windowID: windowID,
                                                   hold: holdButton && !expanding ? 140 : 24)
                        mouseDown = click.down
                        return click.up
                    }
                    let button = try action(in: ax, expanding: expanding)
                    let start = hostTime()
                    try press(button)
                    return start
                }
                try result.write(to: output.appendingPathComponent("\(kind)-\(round).csv"), atomically: true, encoding: .utf8)
                let actual = windowInfo(pid).first { $0.0 == windowID }?.1
                guard actual == (expanding ? expanded : collapsed) else {
                    throw ProbeFailure("第 \(round) 轮 \(kind) 终点错位：\(String(describing: actual))")
                }
                try await Task.sleep(for: .milliseconds(550))
            }
        }
        if verifyHost {
            try await checkFixedHost(application: ax, pid: pid, windowID: windowID,
                                     expanded: expanded, collapsed: collapsed, backdrop: backdrop, stripes: stripes)
        }
        if verifyPress {
            try await checkPressCancellation(application: ax, pid: pid, windowID: windowID,
                                             expanded: expanded, collapsed: collapsed)
        }
        if holdButton {
            try await checkCollapseButtonCancellation(application: ax, pid: pid, windowID: windowID, expanded: expanded)
        }
        try await checkHover(application: ax, pid: pid, windowID: windowID, collapsed: collapsed, expanded: expanded)
        print("圆球、悬停横条和展开面板已通过尺寸与锚点检查")
        app.terminate()
        for _ in 0..<50 {
            if app.isTerminated { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard app.isTerminated else { throw ProbeFailure("测试进程未能正常退出") }
    }

    @MainActor
    private static func makeReferencePanel(at origin: NSPoint) -> NSPanel {
        let rect = CGRect(origin: origin, size: CGSize(width: 7, height: 12))
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        let view = NSView(frame: CGRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        panel.contentView = view
        panel.orderFrontRegardless()
        return panel
    }

    private static func action(in application: AXUIElement, expanding: Bool) throws -> AXUIElement {
        guard let raw = attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID(),
              let action = button(in: raw as! AXUIElement, expanding: expanding) else {
            throw ProbeFailure("辅助功能找不到当前开合按钮")
        }
        return action
    }

    private static func press(_ action: AXUIElement) throws {
        guard AXUIElementPerformAction(action, kAXPressAction as CFString) == .success else {
            throw ProbeFailure("辅助功能开合操作失败")
        }
    }

    private static func hostTime() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private static func movePointer(to point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    @MainActor
    private static func click(at point: CGPoint, pid: pid_t, windowID: CGWindowID,
                              hold: Int = 24) async throws -> (down: Double, up: Double) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw ProbeFailure("指定测试进程未在前台")
        }
        guard windowInfo().first(where: { $0.1.contains(point) })?.0 == windowID else {
            throw ProbeFailure("指定测试面板被遮挡或点击超出范围")
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw ProbeFailure("无法创建收展按钮的鼠标事件")
        }
        let pressed = hostTime()
        down.post(tap: .cghidEventTap)
        do { try await Task.sleep(for: .milliseconds(hold)) }
        catch {
            up.post(tap: .cghidEventTap)
            throw error
        }
        let start = hostTime()
        up.post(tap: .cghidEventTap)
        return (pressed, start)
    }

    @MainActor
    private static func checkCollapseButtonCancellation(application: AXUIElement, pid: pid_t,
                                                        windowID: CGWindowID, expanded: CGRect) async throws {
        let center = CGPoint(x: expanded.maxX - 24, y: expanded.minY + 22)
        let outside = CGPoint(x: center.x - 66, y: center.y + 48)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
              let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: outside, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: outside, mouseButton: .left) else {
            throw ProbeFailure("无法创建收起按钮的取消事件")
        }
        movePointer(to: center)
        try await Task.sleep(for: .milliseconds(80))
        down.post(tap: .cghidEventTap)
        var released = false
        defer { if !released { up.post(tap: .cghidEventTap) } }
        try await Task.sleep(for: .milliseconds(95))
        drag.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(55))
        up.post(tap: .cghidEventTap)
        released = true
        try await Task.sleep(for: .milliseconds(400))
        guard windowInfo(pid).first(where: { $0.0 == windowID })?.1 == expanded else {
            throw ProbeFailure("收起按钮在范围外松开后改变了窗口")
        }
        _ = try action(in: application, expanding: false)
        movePointer(to: center)
        print("收起按钮在范围外松开后保持展开")
    }

    @MainActor
    private static func checkFixedHost(application: AXUIElement, pid: pid_t, windowID: CGWindowID,
                                       expanded: CGRect, collapsed: CGRect, backdrop: NSPanel, stripes: Stripes) async throws {
        func frame() -> CGRect? { windowInfo(pid).first { $0.0 == windowID }?.1 }
        func expect(_ rect: CGRect, _ message: String) throws {
            guard frame() == rect else { throw ProbeFailure(message) }
        }

        // The test click targets only the synthetic panel immediately beneath the animated window.
        let point = CGPoint(x: expanded.minX + 36, y: expanded.maxY - 36)
        let pointerBeforeTest = CGEvent(source: nil)?.location
        backdrop.ignoresMouseEvents = false
        defer {
            backdrop.ignoresMouseEvents = true
            if let pointerBeforeTest, CGEvent(source: nil)?.location == point {
                movePointer(to: pointerBeforeTest)
            }
        }
        try press(action(in: application, expanding: false))
        for _ in 1...4 {
            try await Task.sleep(for: .milliseconds(29))
            try expect(expanded, "收起过程中宿主窗口发生了变化")
        }
        let windowsUnderPoint = windowInfo().filter { $0.1.contains(point) }.prefix(2).map(\.0)
        guard windowsUnderPoint == [windowID, CGWindowID(backdrop.windowNumber)] else {
            throw ProbeFailure("测试区域已被其他窗口覆盖")
        }
        _ = try await click(at: point, pid: pid, windowID: windowID)
        try await Task.sleep(for: .milliseconds(65))
        try expect(expanded, "收起过程中宿主窗口提前缩小")
        let clicksDuringTransition = stripes.clicks
        try await Task.sleep(for: .milliseconds(250))
        try expect(collapsed, "收起结束时宿主窗口没有回到圆球尺寸")
        guard windowInfo().first(where: { $0.1.contains(point) })?.0 == CGWindowID(backdrop.windowNumber),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw ProbeFailure("背景窗口的正向点击对照已被遮挡")
        }
        down.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(24))
        up.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(65))
        guard stripes.clicks == clicksDuringTransition + 1 else {
            throw ProbeFailure("背景窗口在无遮挡的正向对照中也没有收到点击")
        }
        guard clicksDuringTransition == 1 else { throw ProbeFailure("收起时透明区的点击未送达下方测试窗口") }
        NSRunningApplication(processIdentifier: pid)?.activate()
        try await Task.sleep(for: .milliseconds(120))
        try press(action(in: application, expanding: true))
        for _ in 1...6 {
            try await Task.sleep(for: .milliseconds(29))
            try expect(expanded, "展开过程中宿主窗口发生了变化")
        }
        try await Task.sleep(for: .milliseconds(350))
        try expect(expanded, "展开结束时宿主窗口发生了变化")
        print("收展中段宿主尺寸固定，透明区的实际点击送达下方测试窗口")
    }

    @MainActor
    private static func checkPressCancellation(application: AXUIElement, pid: pid_t, windowID: CGWindowID,
                                               expanded: CGRect, collapsed: CGRect) async throws {
        func frame() -> CGRect? { windowInfo(pid).first { $0.0 == windowID }?.1 }
        func event(_ type: CGEventType, at point: CGPoint) throws -> CGEvent {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                throw ProbeFailure("无法生成测试鼠标事件")
            }
            return event
        }
        let center = CGPoint(x: collapsed.midX, y: collapsed.midY)
        let outside = CGPoint(x: collapsed.midX - 70, y: collapsed.midY + 25)
        let dragTarget = CGPoint(x: center.x - 40, y: center.y + 30)
        let original = CGEvent(source: nil)?.location
        defer {
            if let original, let current = CGEvent(source: nil)?.location,
               [center, outside, dragTarget].contains(current) {
                movePointer(to: original)
            }
        }

        // Place the pointer over the ball before collapse, so a fresh hover
        // entry cannot start its separate reveal while the press is held.
        movePointer(to: center)
        try press(action(in: application, expanding: false))
        try await Task.sleep(for: .milliseconds(450))
        guard frame() == collapsed,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              windowInfo().first(where: { $0.1.contains(center) })?.0 == windowID else {
            throw ProbeFailure("测试窗口未处于前台圆球状态")
        }

        let outsideUp = try event(.leftMouseUp, at: outside)
        try event(.leftMouseDown, at: center).post(tap: .cghidEventTap)
        var released = false
        defer { if !released { outsideUp.post(tap: .cghidEventTap) } }
        try await Task.sleep(for: .milliseconds(100))
        guard frame() == expanded else { throw ProbeFailure("按住时没有准备固定宿主") }
        _ = try action(in: application, expanding: true)
        outsideUp.post(tap: .cghidEventTap)
        released = true
        try await Task.sleep(for: .milliseconds(150))
        guard frame() == collapsed else { throw ProbeFailure("在圆球外松开后未恢复窗口") }

        // Return to the same stationary pointer setup for the drag case.
        // Moving into a settled ball could independently trigger its hover reveal.
        try press(action(in: application, expanding: true))
        try await Task.sleep(for: .milliseconds(500))
        movePointer(to: center)
        try press(action(in: application, expanding: false))
        try await Task.sleep(for: .milliseconds(450))
        guard frame() == collapsed else { throw ProbeFailure("拖动前未恢复圆球尺寸") }

        let dragUp = try event(.leftMouseUp, at: dragTarget)
        try event(.leftMouseDown, at: center).post(tap: .cghidEventTap)
        released = false
        defer {
            if !released {
                dragUp.post(tap: .cghidEventTap)
                released = true
            }
        }
        try await Task.sleep(for: .milliseconds(80))
        let heldBeforeDrag = frame()
        let halfway = CGPoint(x: (center.x + dragTarget.x) / 2, y: (center.y + dragTarget.y) / 2)
        try event(.leftMouseDragged, at: halfway).post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(45))
        try event(.leftMouseDragged, at: dragTarget).post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(45))
        let heldAfterDrag = frame()
        dragUp.post(tap: .cghidEventTap)
        released = true
        try await Task.sleep(for: .milliseconds(150))

        let moved = collapsed.offsetBy(dx: dragTarget.x - center.x, dy: dragTarget.y - center.y)
        guard frame() == moved else {
            throw ProbeFailure("拖动未保持圆球尺寸和指针位移，预期 \(moved)，实际 \(String(describing: frame()))，按住时 \(String(describing: heldBeforeDrag))，拖动中 \(String(describing: heldAfterDrag))")
        }
        movePointer(to: dragTarget)
        try event(.leftMouseDown, at: dragTarget).post(tap: .cghidEventTap)
        released = false
        try await Task.sleep(for: .milliseconds(80))
        try event(.leftMouseDragged, at: halfway).post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(45))
        try event(.leftMouseDragged, at: center).post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(45))
        try event(.leftMouseUp, at: center).post(tap: .cghidEventTap)
        released = true
        try await Task.sleep(for: .milliseconds(150))
        guard frame() == collapsed else { throw ProbeFailure("圆球拖回原锚点失败") }
        try press(action(in: application, expanding: true))
        try await Task.sleep(for: .milliseconds(500))
        guard frame() == expanded else { throw ProbeFailure("取消或拖动后的展开位置有误") }
        print("按住、圆球外松开、两次实鼠标拖动及展开锚点检查通过")
    }

    @MainActor
    private static func checkHover(application: AXUIElement, pid: pid_t, windowID: CGWindowID,
                                   collapsed: CGRect, expanded: CGRect) async throws {
        func frame() -> CGRect? { windowInfo(pid).first { $0.0 == windowID }?.1 }
        let outside = CGPoint(x: collapsed.minX - 70, y: collapsed.maxY + 30)
        let original = CGEvent(source: nil)?.location
        defer {
            if let original, CGEvent(source: nil)?.location == outside { movePointer(to: original) }
        }
        try press(action(in: application, expanding: false))
        try await Task.sleep(for: .milliseconds(650))
        guard frame() == collapsed else { throw ProbeFailure("悬停前的圆球尺寸不符") }
        movePointer(to: outside)
        try await Task.sleep(for: .milliseconds(80))
        movePointer(to: CGPoint(x: collapsed.midX, y: collapsed.midY))
        try await Task.sleep(for: .milliseconds(650))
        guard let strip = frame(), strip.height == 48, strip.width > 48,
              strip.maxX == collapsed.maxX, strip.minY == collapsed.minY else {
            throw ProbeFailure("悬停横条没有从圆球锚点展开")
        }
        movePointer(to: outside)
        try await Task.sleep(for: .milliseconds(750))
        guard frame() == collapsed else { throw ProbeFailure("悬停结束后圆球没有回到锚点") }
        try press(action(in: application, expanding: true))
        try await Task.sleep(for: .milliseconds(750))
        guard frame() == expanded else { throw ProbeFailure("悬停往返后面板没有回到展开位置") }
    }

    @MainActor
    private static func capture(filter: SCContentFilter, config: SCStreamConfiguration, screen: NSScreen,
                                differences: URL?, reference: CALayer?, pairedFilter: SCContentFilter?,
                                mouseDown: () -> Double?,
                                trigger: () async throws -> Double) async throws -> String {
        let frames = Frames(collectDifferences: differences != nil)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: frames.queue)
        let clock = DisplayClock()
        if let reference {
            clock.onTick = { tick in
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                reference.backgroundColor = CGColor(gray: CGFloat(tick % 8) / 7, alpha: 1)
                CATransaction.commit()
            }
        }
        clock.start(on: screen)
        defer { clock.stop() }
        try await stream.startCapture()
        let pairedFrames = Frames(collectDifferences: false)
        let pairedStream = pairedFilter.map { SCStream(filter: $0, configuration: config, delegate: nil) }
        let start: Double
        do {
            if let pairedStream {
                try pairedStream.addStreamOutput(pairedFrames, type: .screen, sampleHandlerQueue: pairedFrames.queue)
                try await pairedStream.startCapture()
            }
            try await Task.sleep(for: .milliseconds(500))
            start = try await trigger()
            try await Task.sleep(for: .milliseconds(differences == nil ? 750 : 1300))
        } catch {
            try? await pairedStream?.stopCapture()
            try? await stream.stopCapture()
            throw error
        }
        try await stream.stopCapture()
        try await pairedStream?.stopCapture()
        let samples = frames.snapshot()
        if let differences {
            let names = ["icon", "glass", "rim", "near_exterior", "background"]
            let columns = names.flatMap { name in ["\(name)_count", "\(name)_above_two", "\(name)_peak"] }
            let header = (["host_s"] + columns).joined(separator: ",")
            try ([header] + frames.differenceRows).joined(separator: "\n").write(to: differences, atomically: true, encoding: .utf8)
        }
        let fingerprints = Set(samples.filter { $0.pts >= start && $0.pts <= start + 0.5 }.compactMap(\.fingerprint))
        guard fingerprints.count > 5, clock.targets.count > 10 else {
            throw ProbeFailure("采集缺少连续的动画画面或独立显示节拍")
        }
        var csv = "source,host_s,relative_ms,status,display_time,fingerprint,silhouette,button_luma,reference_luma\n"
        if let down = mouseDown() {
            csv += "mouse-down,\(down),\((down - start) * 1000),,,,,,\n"
        }
        for (source, recorded) in [("capture", samples), ("filtered", pairedFrames.snapshot())] {
            for sample in recorded {
                let fingerprint = sample.fingerprint.map(String.init) ?? ""
                csv += "\(source),\(sample.pts),\((sample.pts - start) * 1000),\(sample.status),\(sample.displayTime),\(fingerprint),\(sample.silhouette.map(String.init) ?? ""),\(sample.buttonLuma.map { String($0) } ?? ""),\(sample.referenceLuma.map(String.init) ?? "")\n"
            }
        }
        for target in clock.targets {
            csv += "display,\(target),\((target - start) * 1000),,,,,,\n"
        }
        return csv
    }
}
