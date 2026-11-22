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
    let id: String
    @Published var selected = false
    @Published var focusable = false
    let focusRequest = PassthroughSubject<Void, Never>()
    private var focusRequestObserver: AnyCancellable?
    fileprivate var onFocusRequested: ((String) -> Void)?

    init(id: String = "", focusable: Bool = false, onFocusRequested: ((String) -> Void)? = nil) {
        self.id = id
        self.focusable = focusable
        self.onFocusRequested = onFocusRequested
        focusRequestObserver = focusRequest.sink { [weak self] in
            guard let self else { return }
            self.onFocusRequested?(self.id)
        }
    }
}

/// This object intentionally does not publish globally. Only rows whose bit
/// changes invalidate their title/checkmark, not the outline or its geometry.
/// Uses a roving focus target so only one task row participates in SwiftUI's
/// FocusBridge key-view loop at a time while preserving Tab entry and arrow navigation.
@MainActor final class TaskSelectionController: ObservableObject {
    private(set) var value = TaskSelection()
    private(set) var focusTargetID: String?
    let navigation = PassthroughSubject<String, Never>()
    private var rows: [String: TaskRowSelection] = [:]

    func row(_ id: String) -> TaskRowSelection {
        if let row = rows[id] { return row }
        let isInitialTarget = focusTargetID == nil
        if isInitialTarget { focusTargetID = id }
        let row = TaskRowSelection(id: id, focusable: isInitialTarget) { [weak self] target in
            self?.setFocusTarget(target)
        }
        row.selected = value.ids.contains(id)
        rows[id] = row
        return row
    }

    func setFocusTarget(_ id: String?) {
        guard focusTargetID != id else {
            if let id, let row = rows[id], !row.focusable { row.focusable = true }
            return
        }
        if let previous = focusTargetID, let row = rows[previous], row.focusable {
            row.focusable = false
        }
        focusTargetID = id
        if let id, let row = rows[id], !row.focusable {
            row.focusable = true
        }
    }

    func ensureValidFocusTarget(in order: [String]) {
        if let current = focusTargetID, order.contains(current) {
            if let row = rows[current], !row.focusable { row.focusable = true }
            return
        }
        setFocusTarget(order.first)
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
            .focusable(selection.focusable).focused($focused).focusEffectDisabled()
            .onReceive(selection.focusRequest) { _ in
                focused = true
                // When focusable was just promoted from false to true in the same
                // turn, re-assert focus once SwiftUI commits the focusable state.
                DispatchQueue.main.async {
                    guard selection.focusable, !focused,
                          !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
                    focused = true
                }
            }
            .onChange(of: selection.focusable) { _, canFocus in
                if !canFocus && focused { focused = false }
            }
    }
}

