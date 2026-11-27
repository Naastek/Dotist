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
    fileprivate var onFocusStateChanged: ((String, Bool) -> Void)?

    init(
        id: String = "",
        focusable: Bool = false,
        onFocusRequested: ((String) -> Void)? = nil,
        onFocusStateChanged: ((String, Bool) -> Void)? = nil
    ) {
        self.id = id
        self.focusable = focusable
        self.onFocusRequested = onFocusRequested
        self.onFocusStateChanged = onFocusStateChanged
        focusRequestObserver = focusRequest.sink { [weak self] in
            guard let self else { return }
            self.onFocusRequested?(self.id)
        }
    }
}

/// This object intentionally does not publish globally. Only rows whose bit
/// changes invalidate their title/checkmark, not the outline or its geometry.
/// Uses a roving focus target so only one task row participates in SwiftUI's
/// FocusBridge key-view loop at a time while preserving Tab entry, arrow
/// navigation, deterministic unmount FocusRecovery, and cross-move keepFocus.
@MainActor final class TaskSelectionController: ObservableObject {
    private struct PendingKeepFocus {
        let id: String
        let assertKeyboardFocus: Bool
        let scroll: Bool
    }

    private(set) var value = TaskSelection()
    private(set) var focusTargetID: String?
    private(set) var activeFocusedID: String?
    private var lastVisibleOrder: [String] = []
    private var pendingKeepFocus: PendingKeepFocus?
    var onFocusTargetChanged: ((String?, String?) -> Void)?
    let navigation = PassthroughSubject<String, Never>()
    private var rows: [String: TaskRowSelection] = [:]

    func row(_ id: String) -> TaskRowSelection {
        if let row = rows[id] { return row }
        let isInitialTarget = focusTargetID == nil
        if isInitialTarget { focusTargetID = id }
        let row = TaskRowSelection(
            id: id,
            focusable: isInitialTarget,
            onFocusRequested: { [weak self] target in
                self?.setFocusTarget(target)
            },
            onFocusStateChanged: { [weak self] target, focused in
                guard let self else { return }
                if focused {
                    self.activeFocusedID = target
                } else if self.activeFocusedID == target {
                    self.activeFocusedID = nil
                }
            }
        )
        row.selected = value.ids.contains(id)
        rows[id] = row
        return row
    }

    func setFocusTarget(_ id: String?) {
        guard focusTargetID != id else {
            if let id, let row = rows[id], !row.focusable { row.focusable = true }
            return
        }
        let previous = focusTargetID
        if let previous, let row = rows[previous], row.focusable {
            row.focusable = false
        }
        focusTargetID = id
        if let id, let row = rows[id], !row.focusable {
            row.focusable = true
        }
        onFocusTargetChanged?(previous, id)
    }

    /// Deterministic unmount focus recovery (UI SDK FocusRecovery):
    /// 1. Keep `previousTarget` if it is still visible.
    /// 2. Otherwise pick the nearest surviving following sibling in `previousOrder`.
    /// 3. If none follow, pick the nearest surviving preceding sibling in `previousOrder`.
    /// 4. Otherwise fall back to `currentOrder.first` (or `nil` when empty).
    static func recoverFocusTarget(
        previousTarget: String?,
        previousOrder: [String],
        currentOrder: [String]
    ) -> String? {
        guard !currentOrder.isEmpty else { return nil }
        if let previousTarget, currentOrder.contains(previousTarget) {
            return previousTarget
        }
        let currentSet = Set(currentOrder)
        if let previousTarget, let oldIndex = previousOrder.firstIndex(of: previousTarget) {
            if oldIndex + 1 < previousOrder.count {
                for candidate in previousOrder[(oldIndex + 1)...] where currentSet.contains(candidate) {
                    return candidate
                }
            }
            if oldIndex > 0 {
                for candidate in previousOrder[..<oldIndex].reversed() where currentSet.contains(candidate) {
                    return candidate
                }
            }
        }
        return currentOrder.first
    }

    /// Requests focus to follow `id` across a move/re-group/re-date operation.
    /// If `id` remains visible after the update, focus stays on `id`; if it leaves
    /// the current view, `ensureValidFocusTarget` falls back to FocusRecovery.
    func keepFocus(on id: String, assertKeyboardFocus: Bool = false, scroll: Bool = false) {
        pendingKeepFocus = PendingKeepFocus(id: id, assertKeyboardFocus: assertKeyboardFocus, scroll: scroll)
        if lastVisibleOrder.contains(id) || rows[id] != nil {
            setFocusTarget(id)
        }
    }

    func ensureValidFocusTarget(in order: [String], restoreFocusIfNeeded: Bool = false) {
        if let pending = pendingKeepFocus {
            if order.contains(pending.id) {
                pendingKeepFocus = nil
                setFocusTarget(pending.id)
                lastVisibleOrder = order
                if pending.assertKeyboardFocus, !(NSApp.keyWindow?.firstResponder is NSTextView) {
                    row(pending.id).focusRequest.send()
                }
                if pending.scroll {
                    navigation.send(pending.id)
                }
                return
            } else if order != lastVisibleOrder || order.isEmpty {
                pendingKeepFocus = nil
            }
        }
        let previousTarget = focusTargetID
        let hadActiveFocus = restoreFocusIfNeeded || (previousTarget != nil && activeFocusedID == previousTarget)
        let recovered = Self.recoverFocusTarget(
            previousTarget: previousTarget,
            previousOrder: lastVisibleOrder,
            currentOrder: order
        )
        setFocusTarget(recovered)
        lastVisibleOrder = order
        if hadActiveFocus,
           let recovered,
           recovered != previousTarget,
           !(NSApp.keyWindow?.firstResponder is NSTextView) {
            row(recovered).focusRequest.send()
            navigation.send(recovered)
        }
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
            .onChange(of: focused) { _, isFocused in
                selection.onFocusStateChanged?(selection.id, isFocused)
            }
            .onChange(of: selection.focusable) { _, canFocus in
                if !canFocus && focused { focused = false }
            }
    }
}

