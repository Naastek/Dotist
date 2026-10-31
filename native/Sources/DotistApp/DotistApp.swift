import AppKit
import Combine
import DotistCore
import SwiftUI

@main
struct DotistApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = DotistDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class DotistPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
}

/// Custom SwiftUI button styles must receive the click that activates a window.
final class DotistHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct WindowDragArea: View {
    @State private var origin: (mouse: NSPoint, window: NSPoint)?
    var body: some View {
        if #available(macOS 15.0, *) {
            Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()).allowsWindowActivationEvents()
        } else {
            Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 4)
                .onChanged { _ in
                    guard let window = NSApp.currentEvent?.window else { return }
                    if origin == nil { origin = (NSEvent.mouseLocation, window.frame.origin) }
                    guard let origin else { return }
                    let mouse = NSEvent.mouseLocation
                    window.setFrameOrigin(NSPoint(x: origin.window.x + mouse.x - origin.mouse.x, y: origin.window.y + mouse.y - origin.mouse.y))
                }.onEnded { _ in origin = nil })
        }
    }
}

@MainActor
final class DotistDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    @Published var bubble = false
    @Published var hovering = false
    @Published var bubbleOnRight = true
    private var model: AppModel!
    private var updater: NativeUpdater!
    private var panel: DotistPanel!
    private var viewsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var quickWindow: QuickPanel?
    private var menuBar: MenuBarController?
    private var shortcuts: GlobalShortcuts?
    private var suspendedShortcuts: [UInt32: String] = [:]
    private var settingsObserver: AnyCancellable?
    private var appliedLanguage: String?
    private(set) var expandedSize = NSSize(width: 364, height: 620)
    private(set) var transitionSize = NSSize(width: 364, height: 620)
    private var idleTimer: Timer?
    private var lastActive = Date()
    @Published private(set) var animationInProgress = false
    private var moveCheck: DispatchWorkItem?
    private var hoverClose: DispatchWorkItem?
    private var hoverAnimating = false
    private var pendingHover: Bool?
    private var pendingBubbleToggle = false
    private var hoverRequiresExit = false
    private var menuStates: [(NSMenuItem, Bool)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa" {
            let expected = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("data", isDirectory: true).standardizedFileURL.path
            let selected = ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            let isLink = (try? URL(fileURLWithPath: expected).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            if selected != expected || isLink {
                let alert = NSAlert()
                alert.messageText = "Dotist QA"
                alert.informativeText = "验收副本需要使用其专属的隔离数据目录。"
                alert.runModal()
                NSApp.terminate(nil)
                return
            }
        }
        DotistDesign.registerFonts()
        do { model = try AppModel() }
        catch {
            let alert = NSAlert()
            alert.messageText = "Dotist"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        updater = NativeUpdater(model: model)
        if model.settings.windowWidth > 0 && model.settings.windowHeight > 0 {
            expandedSize = NSSize(width: Int(model.settings.windowWidth), height: Int(model.settings.windowHeight))
        }
        panel = DotistPanel(contentRect: NSRect(origin: .zero, size: expandedSize), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Dotist"
        panel.minSize = NSSize(width: 320, height: 440)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        panel.level = model.settings.alwaysOnTop ? .floating : .normal
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        if model.settings.theme == "light" { panel.appearance = NSAppearance(named: .aqua) }
        if model.settings.theme == "dark" { panel.appearance = NSAppearance(named: .darkAqua) }
        let container = NSView(frame: NSRect(origin: .zero, size: expandedSize))
        let hosting = DotistHostingView(rootView: RootWindow(model: model, coordinator: self))
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        installMenu()
        appliedLanguage = model.settings.language
        menuBar = MenuBarController(model: model) { [weak self] action in self?.performMenuAction(action) }
        do {
            let manager = try GlobalShortcuts { [weak self] id in
                switch id {
                case 1: self?.performMenuAction("toggle")
                case 2: self?.showQuick()
                case 3: self?.showSettings()
                case 4: self?.showViews()
                default: break
                }
            }
            shortcuts = manager
            var registered: [UInt32: String] = [:]
            for (id, value) in shortcutValues().sorted(by: { $0.key < $1.key }) {
                var next = registered
                next[id] = value
                do { try manager.apply(next); registered = next }
                catch { model.error = error.localizedDescription }
            }
        } catch { model.error = error.localizedDescription }
        NSApp.setActivationPolicy(model.settings.showDock ? .regular : .accessory)
        settingsObserver = model.$settings.dropFirst().sink { [weak self] settings in
            guard let self else { return }
            self.updater.apply(settings)
            let appearance: NSAppearance? = settings.theme == "light" ? NSAppearance(named: .aqua) : settings.theme == "dark" ? NSAppearance(named: .darkAqua) : nil
            self.panel.appearance = appearance
            self.panel.level = settings.alwaysOnTop ? .floating : .normal
            self.viewsWindow?.appearance = appearance
            self.settingsWindow?.appearance = appearance
            self.quickWindow?.appearance = appearance
            if self.appliedLanguage != settings.language {
                self.appliedLanguage = settings.language
                self.viewsWindow?.title = self.model.text("任务视图")
                self.settingsWindow?.title = self.model.text("Dotist 设置")
                self.installMenu()
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
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateIdleState() }
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel,
              !bubble, !animationInProgress, panel.frame.width >= 320, panel.frame.height >= 440 else { return }
        expandedSize = panel.frame.size
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if updater.shouldDelayTermination({ allowed in sender.reply(toApplicationShouldTerminate: allowed) }) { return .terminateLater }
        return .terminateNow
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel, !bubble, !animationInProgress else { return }
        var patch = DotistSettingsPatch()
        patch.windowWidth = UInt32(max(320, panel.frame.width.rounded()))
        patch.windowHeight = UInt32(max(440, panel.frame.height.rounded()))
        model.updateSettings(patch)
    }
    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === quickWindow { window.orderOut(nil) }
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === viewsWindow {
            NSApp.setActivationPolicy(model.settings.showDock ? .regular : .accessory)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel, !animationInProgress else { return }
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
        if bubble, let area = panel.screen?.visibleFrame {
            let frame = panel.frame
            let x = min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width))
            let y = min(max(frame.minY, area.minY), max(area.minY, area.maxY - frame.height))
            if x != frame.minX || y != frame.minY { panel.setFrameOrigin(NSPoint(x: x, y: y)) }
            if !hovering && !hoverAnimating && frame.width <= 49 { bubbleOnRight = x + frame.width / 2 > area.midX }
            let width = min(expandedSize.width, area.width)
            let height = min(expandedSize.height, area.height)
            let center = bubbleOnRight ? x + frame.width - 24 : x + 24
            let right = min(max(center + 22, area.minX + width), area.maxX)
            let top = min(max(y + 46, area.minY + height), area.maxY)
            UserDefaults.standard.set(right - width, forKey: "dotist.native.window.x")
            UserDefaults.standard.set(top - height, forKey: "dotist.native.window.y")
            return
        }
        UserDefaults.standard.set(panel.frame.minX, forKey: "dotist.native.window.x")
        UserDefaults.standard.set(panel.frame.minY, forKey: "dotist.native.window.y")
    }

    private func updateIdleState() {
        let prefs = model.settings
        if bubble && hoverRequiresExit && !panel.frame.contains(NSEvent.mouseLocation) { hoverRequiresExit = false }
        if bubble && hovering && !panel.frame.contains(NSEvent.mouseLocation) && NSEvent.pressedMouseButtons & 1 == 0 { setHover(false) }
        let active = bubble || animationInProgress || panel.isKeyWindow || panel.frame.contains(NSEvent.mouseLocation) || NSEvent.pressedMouseButtons & 1 != 0
        if active || prefs.locked { lastActive = Date() }
        let idle = Date().timeIntervalSince(lastActive)
        if !active && !prefs.locked && prefs.autoCollapse && idle >= Double(prefs.autoCollapseSecs) {
            toggleBubble()
            return
        }
        let faded = !active && !prefs.locked && prefs.idleFade && idle >= Double(prefs.idleDelaySecs)
        let target = faded ? CGFloat(prefs.idleOpacity) / 100 : 1
        guard abs(panel.alphaValue - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (faded ? Double(prefs.idleFadeSecs) : 0.12)
            panel.animator().alphaValue = target
        }
    }

    private func installMenu() {
        let menu = NSMenu()
        let application = NSMenuItem()
        menu.addItem(application)
        let appMenu = NSMenu()
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
        editItem.submenu = editMenu
        NSApp.mainMenu = menu
    }
    @objc private func openSettingsFromMenu() { showSettings() }
    @objc private func openQuickFromMenu() { showQuick() }

    private func shortcutValues() -> [UInt32: String] {
        [1: model.settings.toggleShortcut, 2: model.settings.quickAddShortcut, 3: model.settings.settingsShortcut, 4: model.settings.viewsShortcut]
    }
    func beginShortcutCapture() {
        suspendedShortcuts = shortcuts?.values ?? [:]
        shortcuts?.suspend()
        menuStates = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }.map { ($0, $0.isEnabled) } ?? []
        for (item, _) in menuStates { item.isEnabled = false }
    }
    func endShortcutCapture(id: UInt32, value: String?) {
        for (item, enabled) in menuStates { item.isEnabled = enabled }
        menuStates.removeAll()
        guard let shortcuts else { return }
        let previous = suspendedShortcuts
        var next = previous
        if let value { next[id] = value }
        do {
            try shortcuts.apply(next)
            guard let value else { return }
            var patch = DotistSettingsPatch()
            switch id {
            case 1: patch.toggleShortcut = value
            case 2: patch.quickAddShortcut = value
            case 3: patch.settingsShortcut = value
            case 4: patch.viewsShortcut = value
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

    private func performMenuAction(_ action: String) {
        if action.hasPrefix("filter:") {
            model.scope = String(action.dropFirst("filter:".count)); model.scopeNavigation += 1; showMain(); return
        }
        if action.hasPrefix("group:") {
            let id = String(action.dropFirst("group:".count))
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

    func toggleBubble() {
        guard !animationInProgress, let screen = panel.screen ?? NSScreen.main else { return }
        if hoverAnimating {
            hoverClose?.cancel(); hoverClose = nil
            pendingHover = nil; pendingBubbleToggle = true
            return
        }
        hoverClose?.cancel(); hoverClose = nil
        animationInProgress = true
        let area = screen.visibleFrame
        let old = panel.frame
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let target: NSRect
        if !bubble {
            hoverRequiresExit = true
            expandedSize = old.size
            transitionSize = old.size
            let x = min(max(old.maxX - 46, area.minX), area.maxX - 48)
            let y = min(max(old.maxY - 46, area.minY), area.maxY - 48)
            target = NSRect(x: x, y: y, width: 48, height: 48)
            bubbleOnRight = target.midX > area.midX
            panel.minSize = NSSize(width: 48, height: 48)
            panel.styleMask.remove(.resizable)
            bubble = true
        } else {
            let width = min(expandedSize.width, area.width)
            let height = min(expandedSize.height, area.height)
            let center = bubbleOnRight ? old.maxX - 24 : old.minX + 24
            let right = min(max(center + 22, area.minX + width), area.maxX)
            let top = min(max(old.midY + 22, area.minY + height), area.maxY)
            target = NSRect(x: right - width, y: top - height, width: width, height: height)
            transitionSize = target.size
            hovering = false
            bubble = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0 : (bubble ? 0.28 : 0.34)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.animationInProgress = false
                if self.bubble {
                    // A collapse click often leaves the pointer inside the new circle.
                    // Only a fresh pointer entry should reveal the detail capsule.
                    self.hoverRequiresExit = self.panel.frame.contains(NSEvent.mouseLocation)
                    return
                }
                self.panel.minSize = NSSize(width: 320, height: 440)
                self.panel.styleMask.insert(.resizable)
                UserDefaults.standard.set(self.panel.frame.minX, forKey: "dotist.native.window.x")
                UserDefaults.standard.set(self.panel.frame.minY, forKey: "dotist.native.window.y")
            }
        }
    }

    func setHover(_ active: Bool) {
        if !active && !panel.frame.contains(NSEvent.mouseLocation) { hoverRequiresExit = false }
        guard bubble, !animationInProgress, let screen = panel.screen ?? NSScreen.main else { return }
        if active && hoverRequiresExit { return }
        if active && !model.settings.hoverExpand { return }
        if active && NSEvent.pressedMouseButtons & 1 != 0 { return }
        if !active {
            guard hovering, hoverClose == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hoverClose = nil
                guard self.bubble, NSEvent.pressedMouseButtons & 1 == 0, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.setHoverNow(false, screen: self.panel.screen ?? screen)
            }
            hoverClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
            return
        }
        hoverClose?.cancel(); hoverClose = nil
        pendingHover = nil
        guard !hovering else { return }
        setHoverNow(true, screen: screen)
    }

    private func setHoverNow(_ active: Bool, screen: NSScreen) {
        guard bubble, !animationInProgress else { return }
        if hoverAnimating { pendingHover = active; return }
        guard hovering != active else { return }
        hoverAnimating = true
        let frame = panel.frame
        let titleWidth = (model.bubbleTitle as NSString).size(withAttributes: [.font: DotistDesign.nativeFont(13, weight: .medium, language: model.language)]).width
        let detailWidth = (model.bubbleDetail as NSString).size(withAttributes: [.font: DotistDesign.nativeFont(12, language: model.language)]).width
        let width: CGFloat = active ? min(max(120, ceil(48 + 12 + max(titleWidth, detailWidth) + 18)), min(440, screen.visibleFrame.width / 2)) : 48
        let coreX = bubbleOnRight ? frame.maxX - 24 : frame.minX + 24
        let target = NSRect(x: bubbleOnRight ? coreX + 24 - width : coreX - 24, y: frame.minY, width: width, height: 48)
        // Resize the coordinate space without animation; only the glass surface morphs.
        // Animating the whole tree also moves the hit target away from the pointer.
        if active { panel.setFrame(target, display: true) }
        hovering = active
    }

    func finishHover(_ active: Bool) {
        guard bubble, hoverAnimating else { return }
        if !active && NSEvent.pressedMouseButtons & 1 != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.finishHover(active) }
            return
        }
        if !active {
            let frame = panel.frame
            let coreX = bubbleOnRight ? frame.maxX - 24 : frame.minX + 24
            panel.setFrame(NSRect(x: coreX - 24, y: frame.minY, width: 48, height: 48), display: true)
            if let screen = panel.screen ?? NSScreen.main { bubbleOnRight = coreX > screen.visibleFrame.midX }
        }
        hoverAnimating = false
        if pendingBubbleToggle {
            pendingBubbleToggle = false
            toggleBubble()
            return
        }
        if let next = pendingHover {
            pendingHover = nil
            if let screen = panel.screen ?? NSScreen.main { setHoverNow(next, screen: screen) }
        }
    }

    func beginBubbleDrag() {
        guard bubble, !animationInProgress else { return }
        hoverClose?.cancel(); hoverClose = nil
        pendingHover = nil
    }

    func showViews() {
        if viewsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = model.text("任务视图")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.appearance = panel.appearance
            window.delegate = self
            installContent(ViewsWindow(model: model).ignoresSafeArea(), in: window)
            window.minSize = NSSize(width: 680, height: 480)
            window.center()
            viewsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        viewsWindow?.makeKeyAndOrderFront(nil)
        viewsWindow?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = model.text("Dotist 设置")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.appearance = panel.appearance
            installContent(SettingsWindow(model: model, updater: updater, beginShortcutCapture: beginShortcutCapture, endShortcutCapture: endShortcutCapture, resetWindowSize: resetWindowSize).ignoresSafeArea(), in: window)
            window.minSize = NSSize(width: 600, height: 420)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installContent<Content: View>(_ content: Content, in window: NSWindow) {
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        let hosting = DotistHostingView(rootView: content)
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
    }

    func resetWindowSize() {
        var patch = DotistSettingsPatch()
        patch.windowWidth = 0; patch.windowHeight = 0
        model.updateSettings(patch) { [weak self] success in
            guard success, let self else { return }
            self.expandedSize = NSSize(width: 364, height: 620)
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
        }
        if let area = (panel.screen ?? NSScreen.main)?.visibleFrame {
            quickWindow?.setFrameOrigin(NSPoint(x: area.midX - 280, y: area.maxY - area.height * 0.2 - 112))
        }
        quickWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RootWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: DotistDelegate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let fixed = coordinator.bubble || coordinator.animationInProgress
            let width = fixed ? coordinator.transitionSize.width : geometry.size.width
            let height = fixed ? coordinator.transitionSize.height : geometry.size.height
            ZStack(alignment: .topTrailing) {
                MainWindowContent(model: model, coordinator: coordinator).equatable()
                    .frame(width: width, height: height)
                    .opacity(coordinator.bubble ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14).delay(coordinator.bubble ? 0 : 0.1), value: coordinator.bubble)
                    .allowsHitTesting(!coordinator.bubble)
                    .accessibilityHidden(coordinator.bubble)
                // Keep text, font cascade and SwiftUI metadata warm before the first
                // collapse. The circle's content never lays out at intermediate widths.
                BubbleWindow(model: model, coordinator: coordinator, width: coordinator.hovering ? geometry.size.width : 48)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: coordinator.animationInProgress || coordinator.bubbleOnRight ? .topTrailing : .topLeading)
                    .opacity(coordinator.bubble ? 1 : 0)
                    .allowsHitTesting(coordinator.bubble && !coordinator.animationInProgress)
                    .accessibilityHidden(!coordinator.bubble)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
            .background(FloatingSurface(model: model, coordinator: coordinator, size: geometry.size))
            .clipped()
        }
    }
}

/// Window-shape changes do not change task content. MainWindow still observes
/// AppModel directly, while collapse no longer re-runs dates and task builders.
private struct MainWindowContent: View, Equatable {
    let model: AppModel
    let coordinator: DotistDelegate
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.coordinator === rhs.coordinator }
    var body: some View {
        MainWindow(model: model, showViews: coordinator.showViews, showSettings: coordinator.showSettings, collapse: coordinator.toggleBubble)
    }
}

private struct FloatingSurface: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: DotistDelegate
    let size: CGSize
    @State private var revealDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FloatingMaterial(opacity: model.settings.opacity, frost: model.settings.frost, compact: coordinator.bubble)
            .frame(width: coordinator.bubble && !coordinator.animationInProgress && !revealDetails ? 48 : size.width, height: size.height)
            .frame(width: size.width, height: size.height, alignment: coordinator.bubbleOnRight ? .topTrailing : .topLeading)
            .onChange(of: coordinator.hovering) { active in
                // The parent window has already adopted its final coordinate space.
                // Animate this surface alone, and shrink the window only after it settles.
                if reduceMotion {
                    revealDetails = active
                    coordinator.finishHover(active)
                } else if #available(macOS 14.0, *) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.9), completionCriteria: .removed) {
                        revealDetails = active
                    } completion: {
                        coordinator.finishHover(active)
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.26)) { revealDetails = active }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { coordinator.finishHover(active) }
                }
            }
    }
}

struct BubbleWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: DotistDelegate
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: coordinator.toggleBubble) {
            ZStack(alignment: coordinator.bubbleOnRight ? .trailing : .leading) {
                details
                    .frame(width: coordinator.hovering ? max(40, width - 78) : 362,
                           alignment: coordinator.bubbleOnRight ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(coordinator.hovering ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: coordinator.hovering)
                    .padding(coordinator.bubbleOnRight ? .leading : .trailing, 12)
                    .padding(coordinator.bubbleOnRight ? .trailing : .leading, 60)
                    .frame(width: width, height: 48, alignment: coordinator.bubbleOnRight ? .trailing : .leading)
                    .accessibilityHidden(true)
                ZStack {
                    Circle().stroke(DotistDesign.rule, lineWidth: 2.5).frame(width: 30, height: 30)
                    Circle().trim(from: 0, to: model.topLevelTasks.isEmpty ? 0 : CGFloat(model.topLevelTasks.count - model.remainingCount) / CGFloat(model.topLevelTasks.count))
                        .stroke(DotistDesign.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).frame(width: 30, height: 30).rotationEffect(.degrees(-90))
                    if model.remainingCount == 0 && !model.topLevelTasks.isEmpty {
                        Image(systemName: "checkmark").font(.system(size: 20, weight: .semibold)).foregroundColor(DotistDesign.accent)
                    } else {
                        Text("\(model.remainingCount)").font(DotistDesign.font(20, weight: .bold, language: model.language)).foregroundColor(DotistDesign.ink)
                    }
                }.frame(width: 48, height: 48).contentShape(Circle())
            }.frame(width: width, height: 48, alignment: coordinator.bubbleOnRight ? .trailing : .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(DotistFocusRing())
        .overlay(BubblePointer(action: coordinator.toggleBubble, drag: coordinator.beginBubbleDrag).accessibilityHidden(true))
        .accessibilityLabel(Text(model.remainingCount > 0 ? model.text("还有 {n} 件，点击展开").replacingOccurrences(of: "{n}", with: "\(model.remainingCount)") : model.text("全部完成，点击展开")))
        .onHover(perform: coordinator.setHover)
    }
    private var details: some View {
        VStack(alignment: coordinator.bubbleOnRight ? .trailing : .leading, spacing: 0) {
            Text(model.bubbleTitle).font(DotistDesign.font(13, weight: .medium, language: model.language)).foregroundColor(DotistDesign.ink).lineLimit(1)
            if !model.bubbleDetail.isEmpty { Text(model.bubbleDetail).font(DotistDesign.font(12, language: model.language)).foregroundColor(DotistDesign.muted).lineLimit(1) }
        }
    }
}

private struct BubblePointer: NSViewRepresentable {
    let action: () -> Void
    let drag: () -> Void
    func makeNSView(context: Context) -> BubblePointerView { BubblePointerView() }
    func updateNSView(_ view: BubblePointerView, context: Context) { view.action = action; view.drag = drag }
}

final class BubblePointerView: NSView {
    var action: () -> Void = {}
    var drag: () -> Void = {}
    private var down: (mouse: NSPoint, origin: NSPoint)?
    private var dragged = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
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
        guard !dragged else { return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}
