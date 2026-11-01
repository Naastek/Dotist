import Foundation

final class SettingsStore: @unchecked Sendable {
    static let filterIDs = ["today", "all", "tomorrow", "week", "nextweek", "next7", "overdue", "undated", "done"]
    private let path: URL
    private let lock = NSLock()
    private var value: DotistSettings

    private static let defaults = DotistSettings(
        theme: "system",
        language: "system",
        opacity: 56,
        sideTabOpacity: 85,
        frost: 35,
        toggleShortcut: "CommandOrControl+Alt+D",
        quickAddShortcut: "CommandOrControl+Alt+N",
        settingsShortcut: "CommandOrControl+Alt+Comma",
        viewsShortcut: "",
        trayMode: "icon",
        trayRotateSecs: 4,
        trayLeftClick: "toggle",
        trayRightClick: "menu",
        alwaysOnTop: true,
        hoverExpand: true,
        showDock: true,
        showMenubar: true,
        idleFade: true,
        locked: false,
        windowWidth: 0,
        windowHeight: 0,
        idleOpacity: 55,
        idleDelaySecs: 5,
        idleFadeSecs: 2,
        trayFilter: "all",
        trayGroup: "all",
        groupColors: "none",
        filters: SettingsStore.filterIDs,
        defaultFilter: "all",
        autoCollapse: true,
        autoCollapseSecs: 20,
        autoCheckUpdates: true,
        autoInstallUpdates: false,
        skippedUpdateVersion: "",
        lastUpdateError: "",
        mcpEnabled: false
    )

    init(path: URL) throws {
        self.path = path
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let defaults = try JSONSerialization.jsonObject(with: encoder.encode(Self.defaults)) as! [String: Any]
        let stored = FileManager.default.fileExists(atPath: path.path)
            ? try JSONSerialization.jsonObject(with: Data(contentsOf: path)) : [:]
        guard let stored = stored as? [String: Any] else { throw TaskStoreError("设置文件格式无效") }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        value = try decoder.decode(DotistSettings.self, from: JSONSerialization.data(withJSONObject: defaults.merging(stored) { _, new in new }))
        value = try Self.normalized(value)
    }

    func current() -> DotistSettings { lock.withLock { value } }

    func update(_ patch: DotistSettingsPatch) throws -> DotistSettings {
        try lock.withLock {
            var next = value
        if let value = patch.theme { next.theme = value }
        if let value = patch.language { next.language = value }
        if let value = patch.fontSerifLatin { next.fontSerifLatin = value }
        if let value = patch.fontSansLatin { next.fontSansLatin = value }
        if let value = patch.fontSerifCjk { next.fontSerifCjk = value }
        if let value = patch.fontSansCjk { next.fontSansCjk = value }
        if let value = patch.opacity { next.opacity = value }
        if let value = patch.sideTabOpacity { next.sideTabOpacity = value }
        if let value = patch.frost { next.frost = value }
        if let value = patch.alwaysOnTop { next.alwaysOnTop = value }
        if let value = patch.hoverExpand { next.hoverExpand = value }
        if let value = patch.idleFade { next.idleFade = value }
        if let value = patch.locked { next.locked = value }
        if let value = patch.windowWidth { next.windowWidth = value }
        if let value = patch.windowHeight { next.windowHeight = value }
        if let value = patch.idleOpacity { next.idleOpacity = value }
        if let value = patch.idleDelaySecs { next.idleDelaySecs = value }
        if let value = patch.idleFadeSecs { next.idleFadeSecs = value }
        if let value = patch.groupColors { next.groupColors = value }
        if let value = patch.tagOrder { next.tagOrder = value }
        if let value = patch.allColor { next.allColor = value }
        if let value = patch.filters { next.filters = value }
        if let value = patch.defaultFilter { next.defaultFilter = value }
        if let value = patch.autoCollapse { next.autoCollapse = value }
        if let value = patch.autoCollapseSecs { next.autoCollapseSecs = value }
        if let value = patch.showDock { next.showDock = value }
        if let value = patch.showMenubar { next.showMenubar = value }
        if let value = patch.trayMode { next.trayMode = value }
        if let value = patch.trayRotateSecs { next.trayRotateSecs = value }
        if let value = patch.trayLeftClick { next.trayLeftClick = value }
        if let value = patch.trayRightClick { next.trayRightClick = value }
        if let value = patch.trayFilter { next.trayFilter = value }
        if let value = patch.trayGroup { next.trayGroup = value }
        if let value = patch.toggleShortcut { next.toggleShortcut = value }
        if let value = patch.quickAddShortcut { next.quickAddShortcut = value }
        if let value = patch.settingsShortcut { next.settingsShortcut = value }
        if let value = patch.viewsShortcut { next.viewsShortcut = value }
        if let value = patch.autoCheckUpdates { next.autoCheckUpdates = value }
        if let value = patch.autoInstallUpdates { next.autoInstallUpdates = value }
        if let value = patch.skippedUpdateVersion { next.skippedUpdateVersion = value }
        if let value = patch.lastUpdateError { next.lastUpdateError = value }
        if let value = patch.mcpEnabled { next.mcpEnabled = value }
            if patch.autoInstallUpdates == true { next.autoCheckUpdates = true }
            if patch.autoCheckUpdates == false { next.autoInstallUpdates = false }
            next = try Self.normalized(next)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(next).write(to: path, options: .atomic)
            value = next
            return next
        }
    }

    private static func normalized(_ settings: DotistSettings) throws -> DotistSettings {
        var next = settings
        let fonts = next.fontPreferences
        next.fontSerifLatin = fonts.serifLatin
        next.fontSansLatin = fonts.sansLatin
        next.fontSerifCjk = fonts.serifCjk
        next.fontSansCjk = fonts.sansCjk
        next.allColor = DotistGroupColor(rawValue: next.allColor).rawValue
        var seenTags: Set<String> = []
        next.tagOrder = next.tagOrder.filter { !$0.isEmpty && seenTags.insert($0).inserted }
        guard ["system", "light", "dark"].contains(next.theme) else { throw TaskStoreError("无效的主题") }
        guard ["system", "zh-CN", "zh-TW", "en", "ja"].contains(next.language) else { throw TaskStoreError("无效的语言") }
        guard ["icon", "count", "next", "next_date", "rotate"].contains(next.trayMode) else { throw TaskStoreError("无效的菜单栏显示方式") }
        let actions = ["toggle", "bubble", "quick", "settings", "show", "menu", "none"]
        guard actions.contains(next.trayLeftClick), actions.contains(next.trayRightClick) else { throw TaskStoreError("无效的点击操作") }
        guard filterIDs.contains(next.defaultFilter), filterIDs.contains(next.trayFilter) else { throw TaskStoreError("无效的筛选器") }
        let shortcuts = [next.toggleShortcut, next.quickAddShortcut, next.settingsShortcut, next.viewsShortcut].filter { !$0.isEmpty }
        guard Set(shortcuts).count == shortcuts.count else { throw TaskStoreError("不同的动作不能使用同一个快捷键") }
        next.opacity = min(max(next.opacity, 4), 95)
        next.sideTabOpacity = min(max(next.sideTabOpacity, 10), 100)
        next.frost = min(next.frost, 100)
        next.idleOpacity = min(max(next.idleOpacity, 20), 95)
        next.idleDelaySecs = min(max(next.idleDelaySecs, 1), 60)
        next.idleFadeSecs = min(max(next.idleFadeSecs, 1), 10)
        next.autoCollapseSecs = min(max(next.autoCollapseSecs, 1), 600)
        next.trayRotateSecs = min(max(next.trayRotateSecs, 2), 60)
        if next.windowWidth == 0 || next.windowHeight == 0 { next.windowWidth = 0; next.windowHeight = 0 }
        else { next.windowWidth = min(max(next.windowWidth, 320), 4000); next.windowHeight = min(max(next.windowHeight, 440), 4000) }
        var seen: Set<String> = []
        next.filters = next.filters.filter { filterIDs.contains($0) && seen.insert($0).inserted }
        if next.filters.isEmpty { next.filters = filterIDs }
        if !next.autoCheckUpdates { next.autoInstallUpdates = false }
        return next
    }
}
