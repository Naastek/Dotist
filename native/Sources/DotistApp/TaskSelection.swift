import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

struct TaskSelection: Equatable {
    var ids: Set<String> = []
    var anchor: String?
    mutating func click(_ id: String, order: [String], shift: Bool, command: Bool) {
        if shift, let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
            ids = Set(order[min(a, b)...max(a, b)])
        } else if command {
            if !ids.insert(id).inserted { ids.remove(id) }
            anchor = id
        } else { ids = []; anchor = id }
    }
    mutating func clear() { ids = []; anchor = nil }
    func last(in order: [String]) -> String? { order.last { ids.contains($0) } }
}

@MainActor final class TaskRowSelection: ObservableObject {
    @Published var selected = false
    let focusRequest = PassthroughSubject<Void, Never>()
}

/// This object intentionally does not publish globally. Only rows whose bit
/// changes invalidate their title/checkmark, not the outline or its geometry.
@MainActor final class TaskSelectionController: ObservableObject {
    private(set) var value = TaskSelection()
    let navigation = PassthroughSubject<String, Never>()
    private var rows: [String: TaskRowSelection] = [:]
    func row(_ id: String) -> TaskRowSelection {
        if let row = rows[id] { return row }
        let row = TaskRowSelection(); row.selected = value.ids.contains(id); rows[id] = row
        return row
    }
    func update(_ operation: (inout TaskSelection) -> Void) {
        let old = value.ids
        operation(&value)
        for id in old.symmetricDifference(value.ids) { rows[id]?.selected = value.ids.contains(id) }
    }
}

struct TaskSelectableContent<Content: View>: View {
    @ObservedObject var selection: TaskRowSelection
    @FocusState private var focused: Bool
    let content: (Bool, Bool) -> Content
    var body: some View {
        content(selection.selected, focused)
            .focusable().focused($focused).focusEffectDisabled()
            .onReceive(selection.focusRequest) { _ in focused = true }
    }
}

