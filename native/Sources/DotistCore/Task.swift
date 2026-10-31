import Foundation

public enum TaskStatus: String, Codable, Sendable {
    case todo, doing, done
}

public struct DotistTask: Codable, Identifiable, Equatable, Sendable {
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
    public let id: String
    public let name: String
    public let color: String
    public let position: Int64
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

/// Read through the existing Rust settings implementation so defaults and migrations stay shared.
public struct DotistSettings: Decodable, Equatable, Sendable {
    public let theme: String
    public let language: String
    public let opacity: UInt8
    public let frost: UInt8
    public let toggleShortcut: String
    public let quickAddShortcut: String
    public let settingsShortcut: String
    public let viewsShortcut: String
    public let trayMode: String
    public let trayRotateSecs: UInt16
    public let trayLeftClick: String
    public let trayRightClick: String
    public let alwaysOnTop: Bool
    public let hoverExpand: Bool
    public let showDock: Bool
    public let showMenubar: Bool
    public let idleFade: Bool
    public let locked: Bool
    public let windowWidth: UInt32
    public let windowHeight: UInt32
    public let idleOpacity: UInt8
    public let idleDelaySecs: UInt8
    public let idleFadeSecs: UInt8
    public let trayFilter: String
    public let trayGroup: String
    public let groupColors: String
    public let filters: [String]
    public let defaultFilter: String
    public let autoCollapse: Bool
    public let autoCollapseSecs: UInt16
    public let autoCheckUpdates: Bool
    public let autoInstallUpdates: Bool
    public let skippedUpdateVersion: String
    public let lastUpdateError: String
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
    public init() {}
}
