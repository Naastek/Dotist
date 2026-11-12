import AppKit
import Combine
import DotistCore
import SwiftUI
import ObjectiveC.runtime

// Opt-in QA diagnostics record event routing without task text or user data.
func shortcutTrace(_ message: String) {
    guard Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa",
          ProcessInfo.processInfo.environment["DOTIST_SHORTCUT_TRACE"] == "1",
          let directory = ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"] else { return }
    let url = URL(fileURLWithPath: directory).appendingPathComponent("shortcut-trace.log")
    let line = "\(Date().timeIntervalSince1970) \(message) active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "nil") front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")\n"
    if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
}

@main
struct DotistApplication {
    static func main() {
        if Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa" {
            let expected = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("data", isDirectory: true).standardizedFileURL.path
            let selected = ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            let isLink = (try? URL(fileURLWithPath: expected).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            guard selected == expected, !isLink else {
                fputs("Dotist QA requires its own DOTIST_DATA_DIR.\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--mcp") { MCPProxy.run() }
        let app = NSApplication.shared
        let delegate = DotistDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

// Private AppKit selector, verified on macOS 27.2: keeps floating Liquid Glass lit
// when not key. If AppKit removes it, the old inactive appearance returns.
enum FloatingGlassAppearance {
    static let alwaysActive = true
    static func active(_ window: NSWindow) -> Bool {
        guard !alwaysActive else { return true }
        let selector = NSSelectorFromString("_hasActiveAppearance")
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return window.isKeyWindow }
        typealias Implementation = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Implementation.self)(window, selector)
    }
}

final class ViewsGlassWindow: NSWindow {
    @objc(_hasActiveAppearance) func dotistHasActiveAppearance() -> Bool { FloatingGlassAppearance.active(self) }
}

final class DotistPanel: NSPanel {
    @objc(_hasActiveAppearance) func dotistHasActiveAppearance() -> Bool { FloatingGlassAppearance.active(self) }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class QuickPanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        hasShadow = true
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
}

/// Custom SwiftUI button styles must receive the click that activates a window.
final class DotistHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct WindowDragArea: View {
    var body: some View {
        Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()).allowsWindowActivationEvents()
    }
}

@MainActor
final class DotistDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    private struct ShortcutSignature: Equatable {
        let language: String
        let scopes: [String: String]
        let values: [String]

        init(_ settings: DotistSettings) {
            language = settings.language
            scopes = settings.shortcutScopes
            values = [settings.toggleShortcut, settings.quickAddShortcut, settings.settingsShortcut, settings.viewsShortcut, settings.searchShortcut]
        }
    }
    private(set) var motion: PanelMotion!
    var bubble: Bool { motion?.bubble ?? false }
    var animationInProgress: Bool { motion?.animationInProgress ?? false }
    private var model: AppModel!
    private var updater: NativeUpdater!
    private var panel: DotistPanel!
    private var sideTabs: SideTabsController?
    private var viewsWindow: NSWindow?
    private var viewsShadow: ViewsShadowController?
    private var settingsWindow: NSWindow?
    private var quickWindow: QuickPanel?
    private var searchWindow: QuickPanel?
    let mainState = TaskPanelState()
    private var groupPanels: [GroupPanelController] = []
    private var menuBar: MenuBarController?
    private var shortcuts: GlobalShortcuts?
    private var shortcutCaptureActive = false
    private var localShortcutMonitor: Any?
    private var qaPointerMonitor: Any?
    private var suspendedShortcuts: [UInt32: String] = [:]
    private var settingsObserver: AnyCancellable?
    private var appliedLanguage: String?
    private var appliedShortcutSignature: ShortcutSignature?
    private(set) var expandedSize = NSSize(width: 364, height: 620)
    private var idleTimer: Timer?
    private var qaPerfDriver: QAPerfDriver?
    private var moveCheck: DispatchWorkItem?
    private var menuStates: [(NSMenuItem, Bool)] = []
    private var preferredWindowFrame = NSRect.zero
    private var displayOffset = NSPoint.zero
    private var userMoveInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DotistDesign.registerFonts()
        do {
            if Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa",
               ProcessInfo.processInfo.environment["DOTIST_QA_SEED"] == "groups" {
                let store = try TaskStore()
                if try store.listGroups().allSatisfy({ $0.id == DotistGroup.inboxID }) {
                    for name in ["工作", "生活", "阅读"] {
                        let group = try store.addGroup(name: name)
                        try store.addTask(title: name, category: group.id)
                    }
                }
                model = try AppModel(store: store)
            } else { model = try AppModel() }
        }
        catch {
            let alert = NSAlert()
            alert.messageText = "Dotist"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        updater = NativeUpdater(model: model)
        mainState.scope = model.settings.defaultFilter
        if model.settings.windowWidth > 0 && model.settings.windowHeight > 0 {
            expandedSize = NSSize(width: Int(model.settings.windowWidth), height: Int(model.settings.windowHeight))
        }
        panel = DotistPanel(contentRect: NSRect(origin: .zero, size: expandedSize), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Dotist"
        panel.identifier = NSUserInterfaceItemIdentifier("dotist.main")
        panel.minSize = NSSize(width: 320, height: 440)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // .stationary keeps the panel in place when "click wallpaper to reveal desktop" slides ordinary windows aside.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        panel.level = model.settings.alwaysOnTop ? .floating : .normal
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        if model.settings.theme == "light" { panel.appearance = NSAppearance(named: .aqua) }
        if model.settings.theme == "dark" { panel.appearance = NSAppearance(named: .darkAqua) }
        motion = PanelMotion(model: model, panel: panel, size: expandedSize, title: { [model] in model!.bubbleTitle }, rememberFrame: { [weak self] in self?.rememberWindowFrame($0) })
        let container = NSView(frame: NSRect(origin: .zero, size: expandedSize))
        let hosting = DotistHostingView(rootView: RootWindow(model: model, coordinator: self))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        sideTabs = SideTabsController(parent: panel, model: model, state: mainState, motion: motion)
        installMenu()
        appliedLanguage = model.settings.language
        menuBar = MenuBarController(model: model) { [weak self] action in self?.performMenuAction(action) }
        do {
            let manager = try GlobalShortcuts { [weak self] id in self?.performShortcut(id) }
            shortcuts = manager
            var registered: [UInt32: String] = [:]
            for (id, value) in shortcutValues().sorted(by: { $0.key < $1.key }) {
                var next = registered
                next[id] = value
                do { try manager.apply(next); registered = next }
                catch { model.error = error.localizedDescription }
            }
        } catch { model.error = error.localizedDescription }
        shortcutTrace("configured search=\(model.settings.searchShortcut) scope=\(model.settings.shortcutScopes["search"] ?? "nil")")
        appliedShortcutSignature = ShortcutSignature(model.settings)
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if !event.modifierFlags.intersection([.command, .control]).isEmpty || event.keyCode == 53 {
                shortcutTrace("keyDown code=\(event.keyCode) flags=\(event.modifierFlags.rawValue)")
            }
            guard let self, !self.shortcutCaptureActive else { return event }
            for (id, key, value) in self.allShortcutValues() where self.model.settings.shortcutScopes[key] == "app" {
                // Menu key equivalents and this monitor both see the event; let exactly one of them act.
                guard !self.menuHandles(key: key, value: value) else { continue }
                if GlobalShortcuts.matches(value, event: event) { self.performShortcut(id); return nil }
            }
            return event
        }
        if TaskDragDiagnostics.enabled {
            qaPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
                TaskDragDiagnostics.record("application.mouse", fields: ["type": "\(event.type)",
                    "windowNumber": "\(event.windowNumber)", "point": "\(event.locationInWindow)",
                    "windowID": event.window?.identifier?.rawValue ?? "nil", "active": "\(NSApp.isActive)",
                    "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"])
                return event
            }
            TaskDragDiagnostics.record("application.pointer-monitor-installed")
        }
        NSApp.setActivationPolicy(model.settings.showDock ? .regular : .accessory)
        settingsObserver = model.$settings.dropFirst().sink { [weak self] settings in
            guard let self else { return }
            self.updater.apply(settings)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.shortcutCaptureActive else { return }
                let signature = ShortcutSignature(self.model.settings)
                guard signature != self.appliedShortcutSignature else { return }
                do { try self.shortcuts?.apply(self.shortcutValues()) } catch { self.model.error = error.localizedDescription }
                self.installMenu()
                self.appliedShortcutSignature = signature
            }
            let appearance: NSAppearance? = settings.theme == "light" ? NSAppearance(named: .aqua) : settings.theme == "dark" ? NSAppearance(named: .darkAqua) : nil
            self.panel.appearance = appearance
            self.panel.level = settings.alwaysOnTop ? .floating : .normal
            self.viewsWindow?.appearance = appearance
            self.viewsWindow?.level = settings.alwaysOnTop ? .floating : .normal
            self.settingsWindow?.appearance = appearance
            self.quickWindow?.appearance = appearance
            self.searchWindow?.appearance = appearance
            self.groupPanels.forEach { $0.applyAppearance() }
            if self.appliedLanguage != settings.language {
                self.appliedLanguage = settings.language
                self.viewsWindow?.title = self.model.text("任务视图")
                self.settingsWindow?.title = self.model.text("Dotist 设置")
            }
            NSApp.setActivationPolicy(settings.showDock || self.viewsWindow?.isVisible == true ? .regular : .accessory)
        }
        if let x = UserDefaults.standard.object(forKey: "dotist.native.window.x") as? Double,
           let y = UserDefaults.standard.object(forKey: "dotist.native.window.y") as? Double,
           let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSPoint(x: x, y: y)) }) {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: min(max(x, area.minX), max(area.minX, area.maxX - expandedSize.width)), y: min(max(y, area.minY), max(area.minY, area.maxY - expandedSize.height))))
        } else if let area = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: max(area.minX, area.maxX - expandedSize.width - 16), y: max(area.minY, area.maxY - expandedSize.height - 16)))
        } else { panel.center() }
        preferredWindowFrame = panel.frame
        if let x = UserDefaults.standard.object(forKey: "dotist.native.window.x") as? Double,
           let y = UserDefaults.standard.object(forKey: "dotist.native.window.y") as? Double {
            preferredWindowFrame.origin = NSPoint(x: x, y: y)
            displayOffset = NSPoint(x: panel.frame.minX - x, y: panel.frame.minY - y)
            screensChanged()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if !CommandLine.arguments.contains("--background") {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        GlassDebugState.shared.showPanel(avoiding: panel)
        model.mcp.focus = { [weak self] task in
            guard let self else { return }
            self.performMenuAction("show")
            if let task { self.revealTask(task) }
        }
        if Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa", ProcessInfo.processInfo.environment["DOTIST_QA_OPEN"] == "views" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.showViews() }
        }
        if Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa", ProcessInfo.processInfo.environment["DOTIST_QA_OPEN"] == "composer" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .init("DotistQAComposer"), object: nil)
            }
        }
        if Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa", ProcessInfo.processInfo.environment["DOTIST_QA_OPEN"] == "strip" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                if !self.bubble { self.toggleBubble() }
                var readyAt: Date?
                var releaseAt: Date?
                Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
                    MainActor.assumeIsolated {
                        guard let self else { timer.invalidate(); return }
                        if self.animationInProgress || !self.bubble { readyAt = nil; return }
                        if readyAt == nil { readyAt = Date().addingTimeInterval(0.3) }
                        guard Date() >= readyAt! else { return }
                        if releaseAt == nil { releaseAt = Date().addingTimeInterval(8) }
                        guard Date() < releaseAt! else { timer.invalidate(); return }
                        if !self.motion.hovering { self.motion.setHover(true) }
                    }
                }
            }
        }
        if QAPerf.enabled { qaPerfDriver = QAPerfDriver(panel: panel, toggle: { [weak self] in self?.toggleBubble() }, isBubble: { [weak self] in self?.bubble ?? false }); qaPerfDriver?.start() }
        if model.settings.mcpEnabled { model.mcp.start() }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in if QAPerf.enabled { QAPerf.count(.idleTimer) }; self?.updateIdleState() }
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel,
              !bubble, !animationInProgress, panel.frame.width >= 320, panel.frame.height >= 440 else { return }
        expandedSize = panel.frame.size
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if updater?.shouldDelayTermination({ allowed in sender.reply(toApplicationShouldTerminate: allowed) }) == true { return .terminateLater }
        return .terminateNow
    }

    func applicationDidBecomeActive(_ notification: Notification) { shortcutTrace("application became active") }
    func applicationDidResignActive(_ notification: Notification) { shortcutTrace("application resigned active") }

    func applicationWillTerminate(_ notification: Notification) {
        TaskDragDiagnostics.record("application.terminate")
        TaskDragDiagnostics.flush()
        if let qaPointerMonitor { NSEvent.removeMonitor(qaPointerMonitor) }
        if let localShortcutMonitor { NSEvent.removeMonitor(localShortcutMonitor) }
        sideTabs?.stop()
        motion?.stop()
        groupPanels.forEach { $0.motion.stop() }
        model?.mcp.stop()
        idleTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel, !bubble, !animationInProgress else { return }
        var patch = DotistSettingsPatch()
        patch.windowWidth = UInt32(max(320, panel.frame.width.rounded()))
        patch.windowHeight = UInt32(max(440, panel.frame.height.rounded()))
        model.updateSettings(patch)
        preferredWindowFrame = panel.frame
        displayOffset = .zero
        UserDefaults.standard.set(panel.frame.minX, forKey: "dotist.native.window.x")
        UserDefaults.standard.set(panel.frame.minY, forKey: "dotist.native.window.y")
    }
    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === quickWindow || window === searchWindow { shortcutTrace("resign quick/search"); window.orderOut(nil) }
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === viewsWindow {
            viewsShadow?.stop(); viewsShadow = nil
            NSApp.setActivationPolicy(model.settings.showDock ? .regular : .accessory)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel, !animationInProgress else { return }
        // Only a user's drag changes the preferred placement. Display rearrangement is temporary.
        guard NSEvent.pressedMouseButtons & 1 != 0 || userMoveInProgress else { return }
        userMoveInProgress = true
        moveCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishMove() }
        moveCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func finishMove() {
        guard !animationInProgress else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            let work = DispatchWorkItem { [weak self] in self?.finishMove() }
            moveCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            return
        }
        userMoveInProgress = false
        if motion.finishBubbleMove() != nil { return }
        rememberWindowFrame(panel.frame)
    }

    private func rememberWindowFrame(_ frame: NSRect) {
        displayOffset = .zero
        UserDefaults.standard.set(frame.minX, forKey: "dotist.native.window.x")
        UserDefaults.standard.set(frame.minY, forKey: "dotist.native.window.y")
        preferredWindowFrame = frame
    }

    static func screenPlacement(for frame: NSRect, screens: [NSRect], main: NSRect, minimumSize: NSSize = NSSize(width: 320, height: 440)) -> NSRect {
        func overlapArea(_ screen: NSRect) -> CGFloat {
            let overlap = screen.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if screens.contains(where: { overlapArea($0) >= frame.width * frame.height / 2 }) { return frame }
        let best = screens.max(by: { overlapArea($0) < overlapArea($1) }).flatMap { overlapArea($0) > 0 ? $0 : nil } ?? main
        let width = min(frame.width, max(minimumSize.width, best.width))
        let height = min(frame.height, max(minimumSize.height, best.height))
        return NSRect(x: min(max(frame.minX, best.minX), max(best.minX, best.maxX - width)),
                      y: min(max(frame.minY, best.minY), max(best.minY, best.maxY - height)),
                      width: width, height: height)
    }

    @objc private func screensChanged() {
        guard !userMoveInProgress, !animationInProgress, let main = NSScreen.main?.visibleFrame else { return }
        moveCheck?.cancel()
        let target = Self.screenPlacement(for: preferredWindowFrame, screens: NSScreen.screens.map(\.visibleFrame), main: main, minimumSize: panel.minSize)
        let offset = NSPoint(x: target.minX - preferredWindowFrame.minX, y: target.minY - preferredWindowFrame.minY)
        var frame = panel.frame
        frame.origin = NSPoint(x: frame.minX + offset.x - displayOffset.x, y: frame.minY + offset.y - displayOffset.y)
        if !bubble { frame.size = target.size }
        panel.setFrame(frame, display: true)
        displayOffset = offset
    }

    private func updateIdleState() {
        motion.updateIdleState()
        groupPanels.forEach { $0.motion.updateIdleState() }
    }

    private func installMenu() {
        let menu = NSMenu()
        let application = NSMenuItem()
        menu.addItem(application)
        let appMenu = NSMenu()
        // ⌘, is the conventional settings shortcut and stays available even when
        // the configurable shortcut is cleared or switched to another combination.
        let settings = NSMenuItem(title: model.text("设置…"), action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let quick = NSMenuItem(title: model.text("快速添加"), action: #selector(openQuickFromMenu), keyEquivalent: "")
        quick.target = self
        appMenu.addItem(quick)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: model.text("退出 Dotist"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: model.text("编辑"))
        editMenu.addItem(withTitle: model.text("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: model.text("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: model.text("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: model.text("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: model.text("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let search = NSMenuItem(title: model.text("搜索"), action: #selector(openSearchFromMenu), keyEquivalent: "")
        configureMenuShortcut(search, key: "search", value: model.settings.searchShortcut)
        search.target = self
        editMenu.addItem(search)
        editItem.submenu = editMenu
        NSApp.mainMenu = menu
    }
    @objc private func openSettingsFromMenu() { shortcutTrace("settings menu action"); showSettings() }
    @objc private func openQuickFromMenu() { showQuick() }
    @objc private func openSearchFromMenu() { shortcutTrace("search menu action"); showSearch() }

    /// Whether an app-scoped shortcut is already carried by a menu key equivalent.
    private func menuHandles(key: String, value: String) -> Bool {
        guard model.settings.shortcutScopes[key] == "app", GlobalShortcuts.menuEquivalent(value) != nil else { return false }
        // The settings item always carries ⌘,; any other app shortcut belongs to the monitor.
        if key == "settings" { return value == "Command+Comma" }
        return key == "search"
    }
    private func configureMenuShortcut(_ item: NSMenuItem, key: String, value: String) {
        if model.settings.shortcutScopes[key] == "app", let (equivalent, flags) = GlobalShortcuts.menuEquivalent(value) {
            item.keyEquivalent = equivalent
            item.keyEquivalentModifierMask = flags
        }
    }
    private func allShortcutValues() -> [(UInt32, String, String)] {
        let s = model.settings
        return [(1, "toggle", s.toggleShortcut), (2, "quickAdd", s.quickAddShortcut), (3, "settings", s.settingsShortcut), (4, "views", s.viewsShortcut), (5, "search", s.searchShortcut)]
    }
    private func shortcutValues() -> [UInt32: String] {
        Dictionary(uniqueKeysWithValues: allShortcutValues().filter { model.settings.shortcutScopes[$0.1] == "global" }.map { ($0.0, $0.2) })
    }
    private func performShortcut(_ id: UInt32) {
        switch id {
        case 1: performMenuAction("toggle")
        case 2: showQuick()
        case 3: showSettings()
        case 4: showViews()
        case 5: showSearch()
        default: break
        }
    }
    func beginShortcutCapture() {
        shortcutTrace("begin recording")
        shortcutCaptureActive = true
        suspendedShortcuts = shortcuts?.values ?? [:]
        shortcuts?.suspend()
        menuStates = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }.map { ($0, $0.isEnabled) } ?? []
        for (item, _) in menuStates { item.isEnabled = false }
    }
    func endShortcutCapture(id: UInt32, value: String?) {
        shortcutTrace("end recording id=\(id) cancelled=\(value == nil)")
        for (item, enabled) in menuStates { item.isEnabled = enabled }
        menuStates.removeAll()
        shortcutCaptureActive = false
        guard let shortcuts else { return }
        let previous = suspendedShortcuts
        var next = previous
        do {
            if let value {
                try GlobalShortcuts.validate(value, id: id)
                if previous[id] != nil { next[id] = value }
            }
            try shortcuts.apply(next)
            guard let value else { return }
            var patch = DotistSettingsPatch()
            switch id {
            case 1: patch.toggleShortcut = value
            case 2: patch.quickAddShortcut = value
            case 3: patch.settingsShortcut = value
            case 4: patch.viewsShortcut = value
            case 5: patch.searchShortcut = value
            default: return
            }
            model.updateSettings(patch) { [weak self] success in
                guard !success else { return }
                do { try shortcuts.apply(previous) } catch { self?.model.error = error.localizedDescription }
            }
        } catch {
            model.error = error.localizedDescription
            do { try shortcuts.apply(previous) } catch { model.error = error.localizedDescription }
        }
    }
    func changeShortcutScope(key: String, scope: String) {
        guard let shortcuts else { return }
        let previous = shortcuts.values
        var scopes = model.settings.shortcutScopes
        scopes[key] = scope
        var next = shortcutValues()
        if let (id, _, value) = allShortcutValues().first(where: { $0.1 == key }) {
            if scope == "global" { next[id] = value } else { next.removeValue(forKey: id) }
        }
        do {
            try shortcuts.apply(next)
            var patch = DotistSettingsPatch()
            patch.shortcutScopes = scopes
            model.updateSettings(patch) { [weak self] success in
                guard !success else { return }
                do { try shortcuts.apply(previous) } catch { self?.model.error = error.localizedDescription }
            }
        } catch { model.error = error.localizedDescription }
    }

    private func performMenuAction(_ action: String) {
        if action.hasPrefix("filter:") {
            mainState.groupID = nil
            model.scope = String(action.dropFirst("filter:".count)); model.scopeNavigation += 1; showMain(); return
        }
        if action.hasPrefix("group:") {
            let id = String(action.dropFirst("group:".count))
            mainState.groupID = id == "all" ? nil : id
            model.scope = "all"; model.scopeNavigation += 1; showMain()
            if id != "all" { DispatchQueue.main.async { self.model.gotoGroup = id } }
            return
        }
        switch action {
        case "toggle", "bubble": toggleBubble()
        case "collapse": if !bubble { toggleBubble() }
        case "show": showMain()
        case "views": showViews()
        case "quick": showQuick()
        case "settings": showSettings()
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }
    private func showMain() {
        if bubble { toggleBubble() }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleBubble() { motion.toggleBubble() }

    func showBubbleMenu(_ event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        func add(_ title: String, _ action: String, checked: Bool = false) {
            let item = NSMenuItem(title: model.text(title), action: #selector(bubbleMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            item.state = checked ? .on : .off
            menu.addItem(item)
        }
        add("显示窗口", "show")
        add("快速添加", "quick")
        add("任务视图", "views")
        menu.addItem(.separator())
        add(model.settings.alwaysOnTop ? "取消置顶" : "置顶窗口", "top", checked: model.settings.alwaysOnTop)
        add(model.settings.locked ? "取消固定" : "固定窗口", "locked", checked: model.settings.locked)
        menu.addItem(.separator())
        add("设置…", "settings")
        add("退出 Dotist", "quit")
        motion.showMenu(menu, event: event, in: view)
    }

    @objc private func bubbleMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        if action == "top" {
            var patch = DotistSettingsPatch(); patch.alwaysOnTop = !model.settings.alwaysOnTop; model.updateSettings(patch)
            return
        }
        if action == "locked" {
            var patch = DotistSettingsPatch(); patch.locked = !model.settings.locked; model.updateSettings(patch)
            return
        }
        performMenuAction(action)
    }

    func showViews() {
        if viewsWindow == nil {
            let window = ViewsGlassWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = model.text("任务视图")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.appearance = panel.appearance
            window.delegate = self
            installContent(ViewsWindow(model: model).ignoresSafeArea(), in: window)
            window.minSize = NSSize(width: 680, height: 480)
            window.center()
            viewsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        viewsWindow?.level = panel.level
        if viewsShadow == nil, let viewsWindow { viewsShadow = ViewsShadowController(parent: viewsWindow) }
        viewsWindow?.makeKeyAndOrderFront(nil)
        viewsShadow?.synchronize()
        viewsWindow?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showGroupPanel(_ id: String) {
        guard model.groups.contains(where: { $0.id == id }) else { return }
        if let existing = groupPanels.first(where: { $0.state.groupID == id }) {
            if existing.compact { existing.toggleCompact() }
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = GroupPanelController(model: model, groupID: id, near: groupPanels.last?.window?.frame ?? panel.frame,
            showViews: { [weak self] in self?.showViews() }, showSearch: { [weak self] in self?.showSearch() },
            showSettings: { [weak self] in self?.showSettings() }, showGroupPanel: { [weak self] in self?.showGroupPanel($0) },
            didClose: { [weak self] closed in self?.groupPanels.removeAll { $0 === closed } })
        groupPanels.append(controller)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = model.text("Dotist 设置")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.appearance = panel.appearance
            installContent(SettingsWindow(model: model, updater: updater, beginShortcutCapture: beginShortcutCapture, endShortcutCapture: endShortcutCapture, changeShortcutScope: changeShortcutScope, resetWindowSize: resetWindowSize).ignoresSafeArea(), in: window)
            window.minSize = NSSize(width: 800, height: 540)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installContent<Content: View>(_ content: Content, in window: NSWindow) {
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        let hosting = DotistHostingView(rootView: ShadowTrackedContent(model: model, content: content))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        window.invalidateShadow()
    }

    func resetWindowSize() {
        var patch = DotistSettingsPatch()
        patch.windowWidth = 0; patch.windowHeight = 0
        model.updateSettings(patch) { [weak self] success in
            guard success, let self else { return }
            self.expandedSize = NSSize(width: 364, height: 620)
            self.motion.expandedSize = self.expandedSize
            guard !self.bubble else { return }
            let old = self.panel.frame
            self.panel.setFrame(NSRect(x: old.maxX - 364, y: old.maxY - 620, width: 364, height: 620), display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    func showQuick() {
        if quickWindow == nil {
            let window = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 112), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.appearance = panel.appearance
            window.delegate = self
            quickWindow = window
        }
        if let window = quickWindow {
            model.error = nil
            window.contentView = DotistHostingView(rootView: QuickAddWindow(model: model) { [weak window] in window?.orderOut(nil) })
            window.invalidateShadow()
        }
        if let area = (panel.screen ?? NSScreen.main)?.visibleFrame {
            quickWindow?.setFrameOrigin(NSPoint(x: area.midX - 280, y: area.maxY - area.height * 0.2 - 112))
        }
        quickWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSearch() {
        shortcutTrace("showSearch visible=\(searchWindow?.isVisible == true)")
        if CommandPaletteVisibility.action(isVisible: searchWindow?.isVisible == true) == .hide {
            searchWindow?.orderOut(nil)
            return
        }
        if searchWindow == nil {
            let window = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.delegate = self
            window.appearance = panel.appearance
            window.center()
            searchWindow = window
        }
        guard let window = searchWindow else { return }
        window.title = model.text("搜索")
        installContent(CommandPalette(model: model, close: { [weak window] in window?.orderOut(nil) }, reveal: revealTask, revealGroup: revealGroup, showViews: showViews, resize: { [weak window] height in
            guard let window else { return }
            var frame = window.frame
            guard abs(frame.height - height) > 0.5 else { return }
            let top = frame.maxY
            shortcutTrace("resize search to \(height)")
            frame.size.height = height
            frame.origin.y = top - height
            window.setFrame(frame, display: true)
        }), in: window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        shortcutTrace("search shown visible=\(window.isVisible)")
    }

    private func revealGroup(_ group: DotistGroup) {
        performMenuAction("show")
        mainState.groupID = group.id
        model.selectTag(nil)
        model.focusId = nil
        model.scope = "all"
        model.activeGroupNavigation(group.id)
    }

    private func revealTask(_ task: DotistTask) {
        performMenuAction("show")
        mainState.groupID = task.category
        model.scope = "all"
        model.selectTag(nil)
        mainState.setGroupCollapsed(false, id: task.category)
        if task.completed || TaskHierarchy(model.tasks).ancestors(of: task.id).contains(where: \.completed) { mainState.hideCompleted = false }
        for parent in TaskHierarchy(model.tasks).ancestors(of: task.id) {
            mainState.expanded.insert(parent.id)
            if parent.completed { mainState.folded.insert(task.category) }
        }
        if task.completed { mainState.folded.insert(task.category) }
        model.gotoGroup = task.category
        model.scopeNavigation += 1
        DispatchQueue.main.async { [weak self] in
            self?.model.focusId = task.id
            self?.model.focusNavigation += 1
        }
    }
}

struct RootWindow: View {
    @ObservedObject var model: AppModel
    let coordinator: DotistDelegate
    var body: some View {
        FloatingPanelView(model: model, motion: coordinator.motion, colorState: coordinator.mainState, title: model.bubbleTitle,
            remaining: model.remainingCount, total: model.topLevelTasks.count, groupName: nil,
            contextMenu: coordinator.showBubbleMenu, content: MainWindowContent(model: model, coordinator: coordinator).equatable())
    }
}

/// Window-shape changes do not change task content. MainWindow still observes
/// AppModel directly, while collapse no longer re-runs dates and task builders.
private struct MainWindowContent: View, Equatable {
    let model: AppModel
    let coordinator: DotistDelegate
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.coordinator === rhs.coordinator }
    var body: some View {
        MainWindow(model: model, state: coordinator.mainState, showViews: coordinator.showViews, showSearch: coordinator.showSearch, showSettings: coordinator.showSettings, showGroupPanel: coordinator.showGroupPanel, collapse: coordinator.toggleBubble)
    }
}

struct BubblePointer: NSViewRepresentable {
    let action: () -> Void
    let drag: () -> Void
    let hover: (Bool) -> Void
    let contextMenu: (NSEvent, NSView) -> Void
    var dragEnd: () -> Void = {}
    func makeNSView(context: Context) -> BubblePointerView { BubblePointerView() }
    func updateNSView(_ view: BubblePointerView, context: Context) { view.action = action; view.drag = drag; view.hover = hover; view.contextMenu = contextMenu; view.dragEnd = dragEnd }
}

final class BubblePointerView: NSView {
    var action: () -> Void = {}
    var drag: () -> Void = {}
    var hover: (Bool) -> Void = { _ in }
    var contextMenu: (NSEvent, NSView) -> Void = { _, _ in }
    var dragEnd: () -> Void = {}
    private var down: (mouse: NSPoint, origin: NSPoint)?
    private var dragged = false
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        // This AppKit overlay owns pointer input, including while another app is active.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        hoverTrackingArea = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        guard let window else { return }
        down = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down, let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let dx = point.x - down.mouse.x, dy = point.y - down.mouse.y
        guard dragged || hypot(dx, dy) > 4 else { return }
        if !dragged { dragged = true; drag() }
        // Keep the bubble out of the system drag session that offers edge tiling.
        window.setFrameOrigin(NSPoint(x: down.origin.x + dx, y: down.origin.y + dy))
    }
    override func mouseUp(with event: NSEvent) {
        guard down != nil else { return }
        down = nil
        defer { dragged = false }
        if dragged { dragEnd(); return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func rightMouseDown(with event: NSEvent) {
        down = nil
        dragged = false
        contextMenu(event, self)
    }
}
