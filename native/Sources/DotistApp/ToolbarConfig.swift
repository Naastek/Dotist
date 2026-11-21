import Foundation

enum ToolbarItem: String, CaseIterable, Codable {
    case filter, completion, calendar, views, pin, lock, color, collapse
}

enum ToolbarVisibility: String, Codable, CaseIterable {
    case always, hover, hidden
}

/// Header toolbar layout shared by the panel header and the settings window.
/// Stored in UserDefaults so the task data model stays untouched.
@MainActor
final class ToolbarConfig: ObservableObject {
    static let shared = ToolbarConfig()
    private static let key = "dotist.toolbar.v1"
    private struct Stored: Codable {
        var order: [ToolbarItem]
        var visibility: [ToolbarItem: ToolbarVisibility]
        private enum CodingKeys: String, CodingKey { case order, visibility }

        init(order: [ToolbarItem], visibility: [ToolbarItem: ToolbarVisibility]) {
            self.order = order
            self.visibility = visibility
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            order = try values.decode([String].self, forKey: .order).compactMap(ToolbarItem.init(rawValue:))
            // v1 encoded enum-keyed dictionaries as alternating key/value arrays.
            // Accept that format and the string-keyed format, dropping retired items.
            if let dictionary = try? values.decode([String: ToolbarVisibility].self, forKey: .visibility) {
                visibility = Dictionary(uniqueKeysWithValues: dictionary.compactMap { key, value in
                    ToolbarItem(rawValue: key).map { ($0, value) }
                })
            } else {
                var entries = try values.nestedUnkeyedContainer(forKey: .visibility)
                visibility = [:]
                while !entries.isAtEnd {
                    let key = try entries.decode(String.self)
                    let value = try entries.decode(ToolbarVisibility.self)
                    if let item = ToolbarItem(rawValue: key) { visibility[item] = value }
                }
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(order.map(\.rawValue), forKey: .order)
            try values.encode(Dictionary(uniqueKeysWithValues: visibility.map { ($0.key.rawValue, $0.value) }), forKey: .visibility)
        }
    }
    private let defaults: UserDefaults

    @Published private(set) var order: [ToolbarItem]
    @Published private(set) var visibility: [ToolbarItem: ToolbarVisibility]

    static let defaultOrder: [ToolbarItem] = [.filter, .completion, .calendar, .views, .pin, .lock, .color, .collapse]
    static let defaultVisibility: [ToolbarItem: ToolbarVisibility] =
        [.filter: .hover, .completion: .hover, .calendar: .hover, .views: .hover, .pin: .hover, .lock: .hover, .color: .hover, .collapse: .always]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            var seen: Set<ToolbarItem> = []
            let known = stored.order.filter { seen.insert($0).inserted }
            order = Self.fixedOrder(known + ToolbarItem.allCases.filter { !known.contains($0) })
            visibility = Self.defaultVisibility.merging(stored.visibility) { _, new in new }
        } else {
            order = Self.defaultOrder
            visibility = Self.defaultVisibility
        }
        visibility[.collapse] = .always
    }

    // Collapse is a permanent edge control, outside the sortable icon strip.
    static func fixedOrder(_ items: [ToolbarItem]) -> [ToolbarItem] {
        items.filter { $0 != .collapse } + [.collapse]
    }

    func visibility(of item: ToolbarItem) -> ToolbarVisibility { item == .collapse ? .always : visibility[item] ?? .hidden }
    func items(_ mode: ToolbarVisibility) -> [ToolbarItem] { order.filter { visibility(of: $0) == mode } }

    func setVisibility(_ value: ToolbarVisibility, for item: ToolbarItem) {
        guard item != .collapse else { return }
        visibility[item] = value
        save()
    }
    /// Moves `item` to the slot currently held by `target` (⌘-drag reorder).
    func move(_ item: ToolbarItem, onto target: ToolbarItem) {
        guard item != .collapse, target != .collapse, item != target, let from = order.firstIndex(of: item), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(item, at: to)
        save()
    }
    func reset() { order = Self.defaultOrder; visibility = Self.defaultVisibility; save() }

    private func save() {
        if let data = try? JSONEncoder().encode(Stored(order: order, visibility: visibility)) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
