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

/// Native preferences persisted next to the task database.
public struct DotistSettings: Codable, Equatable, Sendable {
    public var theme: String
    public var language: String
    public var opacity: UInt8
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

public struct DotistSettingsPatch: Encodable, Sendable {
    public var theme: String?
    public var language: String?
    public var opacity: UInt8?
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
