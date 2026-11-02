import Foundation

public enum TaskStatus: String, Codable, Sendable {
    case todo, doing, done
}

public struct DotistTask: Codable, Identifiable, Equatable, Sendable {
    /// Root tasks have depth zero; five levels are supported without a schema change.
    public static let maxDepth = 4
    public let id: String
    public let title: String
    public let category: String
    public let completed: Bool
    public let status: TaskStatus
    public let position: Int64
    public let createdAt: String
    public let updatedAt: String
    public let deletedAt: String?
    public let revision: Int64
    public let parentId: String?
    public let dueDate: String?
    public let startDate: String?
}

public struct DotistGroup: Codable, Identifiable, Equatable, Sendable {
    public static let inboxID = "inbox"
    public let id: String
    public let name: String
    public let color: String
    public let position: Int64
}

/// Stored independently of the UI palette. Legacy or unknown colors are neutral.
public enum DotistGroupColor: String, Codable, CaseIterable, Sendable {
    case none, red, orange, yellow, green, teal, blue, purple, pink

    public init(rawValue: String) {
        self = Self.allCases.first { $0.rawValue == rawValue } ?? .none
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

public struct DotistTaskTags: Decodable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let tags: [String]
}
public struct DotistTagCount: Decodable, Identifiable, Equatable, Sendable {
    public let tag: String
    public let open: Int
    public let all: Int
    public var id: String { tag }
}
public struct DotistTagDescription: Decodable, Equatable, Sendable {
    public let tasks: [DotistTaskTags]
    public let counts: [DotistTagCount]
}

/// Stable persisted IDs; unknown or absent choices always resolve to defaults.
public enum DotistFontRole: String, CaseIterable, Sendable {
    case serifLatin, sansLatin, serifCjk, sansCjk
    public var choices: [String] {
        switch self {
        case .serifLatin: return ["newsreader", "source-serif-4", "system"]
        case .sansLatin: return ["atkinson-next", "source-sans-3", "system"]
        case .serifCjk: return ["noto-serif", "chiron-sung-hk", "system"]
        case .sansCjk: return ["noto-sans", "system"]
        }
    }
    public var defaultValue: String { choices[0] }
    public func normalized(_ value: String?) -> String { value.flatMap { choices.contains($0) ? $0 : nil } ?? defaultValue }
}

public struct DotistFontPreferences: Equatable, Sendable {
    public var serifLatin: String
    public var sansLatin: String
    public var serifCjk: String
    public var sansCjk: String
    public init(serifLatin: String? = nil, sansLatin: String? = nil, serifCjk: String? = nil, sansCjk: String? = nil) {
        self.serifLatin = DotistFontRole.serifLatin.normalized(serifLatin)
        self.sansLatin = DotistFontRole.sansLatin.normalized(sansLatin)
        self.serifCjk = DotistFontRole.serifCjk.normalized(serifCjk)
        self.sansCjk = DotistFontRole.sansCjk.normalized(sansCjk)
    }
    public var cacheKey: String { [serifLatin, sansLatin, serifCjk, sansCjk].joined(separator: "|") }
}

/// UI values always increase toward transparency. Persisted *_opacity keys
/// keep their historical meaning; loading an old file never inverts its values.
public enum DotistTransparency {
    public static func value(opacity: UInt8) -> Double { 100 - Double(min(100, opacity)) }
    public static func opacity(value: Double) -> UInt8 {
        UInt8((100 - min(100, max(0, value.isFinite ? value : 0))).rounded())
    }
}

/// Native preferences persisted next to the task database.
public struct DotistSettings: Codable, Equatable, Sendable {
    public var theme: String
    public var language: String
    public var fontSerifLatin: String? = nil
    public var fontSansLatin: String? = nil
    public var fontSerifCjk: String? = nil
    public var fontSansCjk: String? = nil
    public var fontPreferences: DotistFontPreferences {
        DotistFontPreferences(serifLatin: fontSerifLatin, sansLatin: fontSansLatin, serifCjk: fontSerifCjk, sansCjk: fontSansCjk)
    }
    public var opacity: UInt8
    /// Background opacity of side tabs, independent of panel opacity (0...100).
    public var sideTabOpacity: UInt8 = 85
    public var frost: UInt8
    public var toggleShortcut: String
    public var quickAddShortcut: String
    public var settingsShortcut: String
    public var viewsShortcut: String
    public var trayMode: String
    public var trayRotateSecs: UInt16
    public var trayLeftClick: String
    public var trayRightClick: String
    public var alwaysOnTop: Bool
    public var hoverExpand: Bool
    public var showDock: Bool
    public var showMenubar: Bool
    public var idleFade: Bool
    public var locked: Bool
    public var windowWidth: UInt32
    public var windowHeight: UInt32
    public var idleOpacity: UInt8
    public var idleDelaySecs: UInt8
    public var idleFadeSecs: UInt8
    public var trayFilter: String
    public var trayGroup: String
    public var groupColors: String
    public var tagOrder: [String] = []
    public var allColor: String = "none"
    public var filters: [String]
    public var defaultFilter: String
    public var autoCollapse: Bool
    public var autoCollapseSecs: UInt16
    public var autoCheckUpdates: Bool
    public var autoInstallUpdates: Bool
    public var skippedUpdateVersion: String
    public var lastUpdateError: String
    public var mcpEnabled: Bool
}

// Keep the memberwise initializer used by SettingsStore while decoding newly
// added preferences safely from older snapshots as well as on-disk settings.
extension DotistSettings {
    private enum CodingKeys: String, CodingKey {
        case theme, language, fontSerifLatin, fontSansLatin, fontSerifCjk, fontSansCjk
        case opacity, sideTabOpacity, frost, toggleShortcut, quickAddShortcut, settingsShortcut, viewsShortcut
        case trayMode, trayRotateSecs, trayLeftClick, trayRightClick
        case alwaysOnTop, hoverExpand, showDock, showMenubar, idleFade, locked
        case windowWidth, windowHeight, idleOpacity, idleDelaySecs, idleFadeSecs
        case trayFilter, trayGroup, groupColors, tagOrder, allColor, filters, defaultFilter
        case autoCollapse, autoCollapseSecs, autoCheckUpdates, autoInstallUpdates
        case skippedUpdateVersion, lastUpdateError, mcpEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = try values.decode(String.self, forKey: .theme)
        language = try values.decode(String.self, forKey: .language)
        fontSerifLatin = try values.decodeIfPresent(String.self, forKey: .fontSerifLatin)
        fontSansLatin = try values.decodeIfPresent(String.self, forKey: .fontSansLatin)
        fontSerifCjk = try values.decodeIfPresent(String.self, forKey: .fontSerifCjk)
        fontSansCjk = try values.decodeIfPresent(String.self, forKey: .fontSansCjk)
        opacity = try values.decode(UInt8.self, forKey: .opacity)
        sideTabOpacity = try values.decodeIfPresent(UInt8.self, forKey: .sideTabOpacity) ?? 85
        frost = try values.decode(UInt8.self, forKey: .frost)
        toggleShortcut = try values.decode(String.self, forKey: .toggleShortcut)
        quickAddShortcut = try values.decode(String.self, forKey: .quickAddShortcut)
        settingsShortcut = try values.decode(String.self, forKey: .settingsShortcut)
        viewsShortcut = try values.decode(String.self, forKey: .viewsShortcut)
        trayMode = try values.decode(String.self, forKey: .trayMode)
        trayRotateSecs = try values.decode(UInt16.self, forKey: .trayRotateSecs)
        trayLeftClick = try values.decode(String.self, forKey: .trayLeftClick)
        trayRightClick = try values.decode(String.self, forKey: .trayRightClick)
        alwaysOnTop = try values.decode(Bool.self, forKey: .alwaysOnTop)
        hoverExpand = try values.decode(Bool.self, forKey: .hoverExpand)
        showDock = try values.decode(Bool.self, forKey: .showDock)
        showMenubar = try values.decode(Bool.self, forKey: .showMenubar)
        idleFade = try values.decode(Bool.self, forKey: .idleFade)
        locked = try values.decode(Bool.self, forKey: .locked)
        windowWidth = try values.decode(UInt32.self, forKey: .windowWidth)
        windowHeight = try values.decode(UInt32.self, forKey: .windowHeight)
        idleOpacity = try values.decode(UInt8.self, forKey: .idleOpacity)
        idleDelaySecs = try values.decode(UInt8.self, forKey: .idleDelaySecs)
        idleFadeSecs = try values.decode(UInt8.self, forKey: .idleFadeSecs)
        trayFilter = try values.decode(String.self, forKey: .trayFilter)
        trayGroup = try values.decode(String.self, forKey: .trayGroup)
        groupColors = try values.decode(String.self, forKey: .groupColors)
        tagOrder = try values.decodeIfPresent([String].self, forKey: .tagOrder) ?? []
        allColor = try values.decodeIfPresent(String.self, forKey: .allColor) ?? "none"
        filters = try values.decode([String].self, forKey: .filters)
        defaultFilter = try values.decode(String.self, forKey: .defaultFilter)
        autoCollapse = try values.decode(Bool.self, forKey: .autoCollapse)
        autoCollapseSecs = try values.decode(UInt16.self, forKey: .autoCollapseSecs)
        autoCheckUpdates = try values.decode(Bool.self, forKey: .autoCheckUpdates)
        autoInstallUpdates = try values.decode(Bool.self, forKey: .autoInstallUpdates)
        skippedUpdateVersion = try values.decode(String.self, forKey: .skippedUpdateVersion)
        lastUpdateError = try values.decode(String.self, forKey: .lastUpdateError)
        mcpEnabled = try values.decode(Bool.self, forKey: .mcpEnabled)
    }
}

public struct DotistSettingsPatch: Encodable, Sendable {
    public var theme: String?
    public var language: String?
    public var fontSerifLatin: String?
    public var fontSansLatin: String?
    public var fontSerifCjk: String?
    public var fontSansCjk: String?
    public var opacity: UInt8?
    public var sideTabOpacity: UInt8?
    public var frost: UInt8?
    public var alwaysOnTop: Bool?
    public var hoverExpand: Bool?
    public var idleFade: Bool?
    public var locked: Bool?
    public var windowWidth: UInt32?
    public var windowHeight: UInt32?
    public var idleOpacity: UInt8?
    public var idleDelaySecs: UInt8?
    public var idleFadeSecs: UInt8?
    public var groupColors: String?
    public var tagOrder: [String]?
    public var allColor: String?
    public var filters: [String]?
    public var defaultFilter: String?
    public var autoCollapse: Bool?
    public var autoCollapseSecs: UInt16?
    public var showDock: Bool?
    public var showMenubar: Bool?
    public var trayMode: String?
    public var trayRotateSecs: UInt16?
    public var trayLeftClick: String?
    public var trayRightClick: String?
    public var trayFilter: String?
    public var trayGroup: String?
    public var toggleShortcut: String?
    public var quickAddShortcut: String?
    public var settingsShortcut: String?
    public var viewsShortcut: String?
    public var autoCheckUpdates: Bool?
    public var autoInstallUpdates: Bool?
    public var skippedUpdateVersion: String?
    public var lastUpdateError: String?
    public var mcpEnabled: Bool?
    public init() {}
}
