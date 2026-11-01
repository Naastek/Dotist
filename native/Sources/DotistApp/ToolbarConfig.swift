import Foundation

enum ToolbarItem: String, CaseIterable, Codable {
    case views, pin, lock, search, collapse
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
    private struct Stored: Codable { var order: [ToolbarItem]; var visibility: [ToolbarItem: ToolbarVisibility] }

    @Published private(set) var order: [ToolbarItem]
    @Published private(set) var visibility: [ToolbarItem: ToolbarVisibility]

    static let defaultOrder: [ToolbarItem] = [.views, .pin, .lock, .search, .collapse]
    static let defaultVisibility: [ToolbarItem: ToolbarVisibility] =
        [.views: .hover, .pin: .hover, .lock: .hover, .search: .hidden, .collapse: .always]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            let known = stored.order.filter { ToolbarItem.allCases.contains($0) }
            order = known + ToolbarItem.allCases.filter { !known.contains($0) }
            visibility = Self.defaultVisibility.merging(stored.visibility) { _, new in new }
        } else {
            order = Self.defaultOrder
            visibility = Self.defaultVisibility
        }
    }

    func visibility(of item: ToolbarItem) -> ToolbarVisibility { visibility[item] ?? .hidden }
    func items(_ mode: ToolbarVisibility) -> [ToolbarItem] { order.filter { visibility(of: $0) == mode } }

    func setVisibility(_ value: ToolbarVisibility, for item: ToolbarItem) {
        visibility[item] = value
        save()
    }
    /// Moves `item` to the slot currently held by `target` (⌘-drag reorder).
    func move(_ item: ToolbarItem, onto target: ToolbarItem) {
        guard item != target, let from = order.firstIndex(of: item), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(item, at: to)
        save()
    }
    func reset() { order = Self.defaultOrder; visibility = Self.defaultVisibility; save() }

    private func save() {
        if let data = try? JSONEncoder().encode(Stored(order: order, visibility: visibility)) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
