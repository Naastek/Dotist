import Foundation
import DotistCore

/// General ⌘Z / ⇧⌘Z history. A frozen drag and an in-flight store operation
/// both disable history so an action cannot overtake its own capture.
@MainActor
extension AppModel {
    func undoLast() { applyHistory(redo: false) }
    func redoLast() { applyHistory(redo: true) }

    func updateHistoryAvailability() {
        let available = dragId == nil && !busy && !historyActionInFlight
        canUndoAction = available && !undoHistory.isEmpty
        canRedoAction = available && !redoHistory.isEmpty
    }

    func recordHistory(_ patch: TaskMutationPatch) {
        guard !patch.isEmpty else { return }
        undoHistory.append(patch)
        if undoHistory.count > 100 { undoHistory.removeFirst(undoHistory.count - 100) }
        redoHistory.removeAll()
    }

    private func applyHistory(redo: Bool) {
        guard redo ? canRedoAction : canUndoAction,
              let patch = redo ? redoHistory.last : undoHistory.last else { return }
        historyActionInFlight = true
        updateHistoryAvailability()
        change(recordHistory: false, completed: { [weak self] in
            guard let self else { return }
            if redo {
                self.redoHistory.removeLast()
                self.undoHistory.append(patch)
            } else {
                self.undoHistory.removeLast()
                self.redoHistory.append(patch)
            }
            self.undo = nil
            self.historyActionInFlight = false
            self.updateHistoryAvailability()
        }, failed: { [weak self] in
            self?.historyActionInFlight = false
            self?.updateHistoryAvailability()
        }) { store in
            try store.apply(patch: redo ? patch.after : patch.before)
        }
    }
}
