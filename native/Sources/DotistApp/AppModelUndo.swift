import Foundation
import DotistCore

struct TaskHistoryEntry: Equatable {
    let id: UUID
    let patch: TaskMutationPatch
    let source: TaskHistorySource
    let groupKey: String?
    let timestamp: TimeInterval
    var sealed: Bool
    let label: String?

    init(
        id: UUID = UUID(),
        patch: TaskMutationPatch,
        source: TaskHistorySource = .user,
        groupKey: String? = nil,
        timestamp: TimeInterval,
        sealed: Bool = false,
        label: String? = nil
    ) {
        self.id = id
        self.patch = patch
        self.source = source
        self.groupKey = groupKey
        self.timestamp = timestamp
        self.sealed = sealed
        self.label = label
    }
}

/// General ⌘Z / ⇧⌘Z history with UI SDK-inspired coalescing (`groupDelay`),
/// explicit `seal()` boundaries, and source-aware (`agent`) selective undo.
/// A frozen drag and an in-flight store operation both disable history so an
/// action cannot overtake its own capture.
@MainActor
extension AppModel {
    func undoLast() { applyHistory(redo: false) }
    func redoLast() { applyHistory(redo: true) }

    func updateHistoryAvailability() {
        let available = dragId == nil && !busy && !historyActionInFlight
        canUndoAction = available && !undoEntries.isEmpty
        canRedoAction = available && !redoEntries.isEmpty
        canUndoAgentAction = available && undoEntries.contains(where: { $0.source == .agent })
    }

    /// Seals the current top undo entry so subsequent edits cannot coalesce into it
    /// (for example after cursor/focus moves, task switches, or draft settlement).
    func sealUndoHistory() {
        guard !undoEntries.isEmpty else { return }
        undoEntries[undoEntries.count - 1].sealed = true
    }

    func recordHistory(
        _ patch: TaskMutationPatch,
        source: TaskHistorySource = .user,
        groupKey: String? = nil,
        label: String? = nil,
        sealed: Bool = false,
        sealAfterRecord: Bool = false
    ) {
        guard !patch.isEmpty else { return }
        let now = historyClock()
        if !sealed,
           let key = groupKey,
           let last = undoEntries.last,
           !last.sealed,
           last.source == source,
           last.groupKey == key,
           now - last.timestamp <= historyGroupDelay {
            let merged = last.patch.merged(with: patch)
            if merged.isEmpty {
                undoEntries.removeLast()
            } else {
                undoEntries[undoEntries.count - 1] = TaskHistoryEntry(
                    id: last.id,
                    patch: merged,
                    source: source,
                    groupKey: key,
                    timestamp: now,
                    sealed: sealAfterRecord,
                    label: label ?? last.label
                )
            }
        } else {
            let entry = TaskHistoryEntry(
                patch: patch,
                source: source,
                groupKey: groupKey,
                timestamp: now,
                sealed: sealed || sealAfterRecord || groupKey == nil,
                label: label
            )
            undoEntries.append(entry)
            if undoEntries.count > 100 { undoEntries.removeFirst(undoEntries.count - 100) }
        }
        redoEntries.removeAll()
        updateHistoryAvailability()
    }

    /// Records an external MCP/AI tool mutation as an isolated, sealed `.agent`
    /// history entry without coalescing into or disturbing active user edit groups.
    /// If an undo/redo write is currently in flight, buffers the entry until that
    /// history action finishes so stack order stays consistent and never races.
    func recordAgentHistory(_ patch: TaskMutationPatch, label: String? = nil) {
        guard !patch.isEmpty else { return }
        if historyActionInFlight {
            pendingAgentHistory.append((patch: patch, label: label))
            return
        }
        sealUndoHistory()
        recordHistory(patch, source: .agent, groupKey: nil, label: label, sealed: true)
    }

    func flushPendingAgentHistory() {
        guard !historyActionInFlight, !pendingAgentHistory.isEmpty else { return }
        let queued = pendingAgentHistory
        pendingAgentHistory.removeAll()
        for item in queued {
            sealUndoHistory()
            recordHistory(item.patch, source: .agent, groupKey: nil, label: item.label, sealed: true)
        }
    }

    /// Reverts the most recent history entry from the given source (e.g. `.agent`)
    /// while preserving any subsequent user edits to other or overlapping tasks.
    func undoSource(_ source: TaskHistorySource, completed: (() -> Void)? = nil) {
        let available = dragId == nil && !busy && !historyActionInFlight
        guard available, let index = undoEntries.lastIndex(where: { $0.source == source }) else { return }
        let entry = undoEntries[index]
        sealUndoHistory()
        historyActionInFlight = true
        updateHistoryAvailability()
        var actualApplied: TaskMutationPatch?
        change(recordHistory: false, completed: { [weak self] in
            guard let self else { return }
            if let removeIndex = self.undoEntries.firstIndex(where: { $0.id == entry.id }) {
                self.undoEntries.remove(at: removeIndex)
            }
            if let applied = actualApplied, !applied.isEmpty {
                let redoPatch = TaskMutationPatch(before: applied.after, after: applied.before)
                self.redoEntries.append(TaskHistoryEntry(
                    patch: redoPatch,
                    source: entry.source,
                    groupKey: nil,
                    timestamp: self.historyClock(),
                    sealed: true,
                    label: entry.label
                ))
            }
            self.undo = nil
            self.historyActionInFlight = false
            self.flushPendingAgentHistory()
            self.updateHistoryAvailability()
            completed?()
        }, failed: { [weak self] in
            guard let self else { return }
            self.historyActionInFlight = false
            self.flushPendingAgentHistory()
            self.updateHistoryAvailability()
        }) { store in
            if source == .agent {
                actualApplied = try store.captureChanges { try $0.applySelectiveUndo(of: entry.patch) }
            } else {
                try store.apply(mutation: entry.patch, redo: false)
                actualApplied = TaskMutationPatch(before: entry.patch.after, after: entry.patch.before)
            }
        }
    }

    func undoLastAgentAction(completed: (() -> Void)? = nil) {
        undoSource(.agent, completed: completed)
    }

    private func applyHistory(redo: Bool) {
        guard redo ? canRedoAction : canUndoAction,
              let entry = redo ? redoEntries.last : undoEntries.last else { return }
        sealUndoHistory()
        historyActionInFlight = true
        updateHistoryAvailability()
        change(recordHistory: false, completed: { [weak self] in
            guard let self else { return }
            if redo {
                if let removeIndex = self.redoEntries.firstIndex(where: { $0.id == entry.id }) {
                    self.redoEntries.remove(at: removeIndex)
                }
                var restored = entry
                restored.sealed = true
                self.undoEntries.append(restored)
            } else {
                if let removeIndex = self.undoEntries.firstIndex(where: { $0.id == entry.id }) {
                    self.undoEntries.remove(at: removeIndex)
                }
                var undone = entry
                undone.sealed = true
                self.redoEntries.append(undone)
            }
            self.undo = nil
            self.historyActionInFlight = false
            self.flushPendingAgentHistory()
            self.updateHistoryAvailability()
        }, failed: { [weak self] in
            guard let self else { return }
            self.historyActionInFlight = false
            self.flushPendingAgentHistory()
            self.updateHistoryAvailability()
        }) { store in
            try store.apply(mutation: entry.patch, redo: redo)
        }
    }
}
