import AppKit
import Combine
import DotistCore
import SwiftUI

extension MainWindow {
    func rowGeometry(_ task: DotistTask, sub: Bool, allTasks: Bool, hideDue: Bool, region: String, date: String?) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: TaskListRowFrame.Key.self, value: [TaskListRowFrame(
                task: task, frame: geometry.frame(in: .named(Self.listSpace)), sub: sub, allTasks: allTasks, hideDue: hideDue, region: region, date: date, depth: model.depth(of: task)
            )])
        }
    }

    func groupGeometry(_ id: String, region: String, date: String? = nil) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: TaskListGroupFrame.Key.self, value: [TaskListGroupFrame(
                id: id, region: region, frame: geometry.frame(in: .named(Self.listSpace)), date: date
            )])
        }
    }

    private var showsInsertionGhost: Bool { drag?.destination != nil }

    func updateGhostFrame() {
        guard let drag, let row = rowFrames.first(where: { $0.task.id == drag.taskID && drag.carries($0.task.id, region: $0.region) }) else { return }
        ghostFrame = row.frame
    }

    func reorderAnimation(_ duration: Double = 0.16) -> Animation? {
        LayoutMotionInputs.shouldReduceMotion(reduceMotion) ? nil : .snappy(duration: duration)
    }

    @ViewBuilder var ghostConnector: some View {
        if let drag, let target = drag.target, target.level > 0, shelfTarget == nil,
           let parent = rowFrames.first(where: { $0.task.id == target.parentID && $0.task.category == target.groupID && $0.region == drag.destination?.region }),
           !drag.visibleBlock.isEmpty {
            let frame = showsInsertionGhost ? ghostFrame : drag.startFrame
            if frame != .zero {
                let parentDepth = model.depth(of: parent.task)
                let start = CGPoint(x: parent.frame.minX + TaskRowMetrics.circleX(parentDepth) - TaskRowMetrics.inset + TaskRowMetrics.diameter(parentDepth) / 2,
                                    y: parent.frame.midY + TaskRowMetrics.diameter(parentDepth) / 2 + 2)
                let end = CGPoint(x: frame.minX + TaskRowMetrics.circleX(target.level) - TaskRowMetrics.inset - 2,
                                  y: frame.midY)
                TaskGhostConnector(start: start, end: end)
                    .stroke(DotistDesign.rule, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    .animation(reorderAnimation(), value: end)
                    .animation(reorderAnimation(), value: start)
                    .id(parent.task.id + ":" + parent.region)
                    .mask(alignment: .topLeading) {
                        Rectangle().frame(width: listViewport.width, height: listViewport.height).offset(x: listViewport.minX, y: listViewport.minY)
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    func traceReorder(_ event: String, taskID: String? = nil, point: CGPoint? = nil, fields: [String: String] = [:]) {
        guard TaskDragDiagnostics.enabled else { return }
        var context = fields
        context["taskID"] = taskID ?? drag?.taskID ?? "nil"
        context["point"] = "\(point ?? dragMotion.location)"
        context["gestureActive"] = "\(reorderGestureActive)"
        context["dragCancelled"] = "\(dragCancelled)"
        context["hasDrag"] = "\(drag != nil)"
        context["committing"] = "\(drag?.committing == true)"
        context["editing"] = "\(editing != nil)"
        context["draft"] = "\(draftAfter != nil)"
        context["inputBound"] = "\(reorderRuntime.handleInput != nil)"
        context["rowCount"] = "\(rowFrames.count)"
        context["target"] = String(describing: drag?.target)
        context["viewport"] = "\(listViewport)"
        TaskDragDiagnostics.record(event, fields: context)
    }

    func reorderGesture(_ task: DotistTask) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.listSpace))
            .updating($reorderGestureActive) { value, active, _ in
                traceReorder("swiftui.updating", taskID: task.id, point: value.location, fields: ["start": "\(value.startLocation)"])
                active = true
            }
            .onChanged { value in
                traceReorder("swiftui.changed", taskID: task.id, point: value.location, fields: ["start": "\(value.startLocation)"])
                if drag == nil { reorderRuntime.send(.begin(task.id, value.startLocation)) }
                reorderRuntime.send(.move(task.id, value.location))
            }
            .onEnded { value in
                traceReorder("swiftui.ended", taskID: task.id, point: value.location)
                reorderRuntime.send(.end(task.id, value.location))
            }
    }

    /// Press-and-hold lifts the glass bar without displacement. A quick click still
    /// edits; moving more than 6 pt before the hold elapses keeps the ordinary drag.
    func holdGesture(_ task: DotistTask) -> some Gesture {
        LongPressGesture(minimumDuration: TaskHoldTracker.duration, maximumDistance: 6)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.listSpace)))
            .updating($holdGestureActive) { value, active, _ in
                if case .second = value { active = true }
            }
            .onChanged { value in
                guard case .second(true, let dragValue) = value else { return }
                hold.lifted = true
                if drag == nil { reorderRuntime.send(.begin(task.id, dragValue?.startLocation ?? hold.pointer)) }
                if let dragValue { reorderRuntime.send(.move(task.id, dragValue.location)) }
            }
            .onEnded { value in
                guard case .second(true, let dragValue) = value else { return }
                reorderRuntime.send(.end(task.id, dragValue?.location ?? hold.pointer))
                hold.finish()
            }
    }

    // Native gestures and other input adapters share the same mounted state.
    func handleReorderInput(_ input: TaskReorderRuntime.Input) {
        switch input {
        case .begin(let id, let point):
            traceReorder("input.begin", taskID: id, point: point)
            guard !dragCancelled, editing == nil, draftAfter == nil, drag == nil,
                  let task = model.tasks.first(where: { $0.id == id }) else { traceReorder("input.begin-rejected", taskID: id); return }
            beginReorder(task, at: point)
        case .move(let id, let point), .end(let id, let point):
            if case .move = input { traceReorder("input.move", taskID: id, point: point) }
            else { traceReorder("input.end", taskID: id, point: point) }
            if case .move = input { guard editing == nil, draftAfter == nil else { traceReorder("input.move-rejected-editor", taskID: id); return } }
            guard !dragCancelled, drag?.taskID == id, drag?.committing == false else { traceReorder("input.move-or-end-rejected", taskID: id); return }
            dragMotion.location = point
            // Mouse-up commits the last presented slot, as Tic does. Resolving
            // again here can choose a different slot after layout has settled,
            // causing the committed row to jump away from its placeholder.
            if case .end = input { finishReorder() }
            else { retargetReorder() }
        case .cancel: traceReorder("input.cancel"); cancelReorder()
        }
    }

    private func beginReorder(_ task: DotistTask, at start: CGPoint) {
        let rowFrames = reorderRuntime.pickupFrames(self.rowFrames)
        guard let head = rowFrames.first(where: { $0.task.id == task.id && $0.frame.contains(start) }) ?? rowFrames.first(where: { $0.task.id == task.id }) else { traceReorder("begin.missing-row", taskID: task.id, point: start); return }
        let hierarchy = TaskHierarchy(model.tasks)
        let selectedIDs = selection.value.ids.contains(task.id) ? Array(selection.value.ids) : [task.id]
        let roots = hierarchy.selectionRoots(ids: selectedIDs, groupIDs: model.groups.map(\.id))
            .sorted { a, b in (displayOrder.firstIndex(of: a.id) ?? 0) < (displayOrder.firstIndex(of: b.id) ?? 0) }
        let ids = Set(roots.flatMap { [$0.id] + model.descendants(of: $0).map(\.id) })
        // A filtered outline can show the same task as context in several
        // regions. Lift one representation per identity, preferring the press's
        // region; other representations keep their ordinary layout.
        var seen: Set<String> = []
        let block = rowFrames.filter { ids.contains($0.task.id) && $0.frame.height > 0 }
            .sorted {
                if ($0.region == head.region) != ($1.region == head.region) { return $0.region == head.region }
                return abs($0.frame.midY - head.frame.midY) < abs($1.frame.midY - head.frame.midY)
            }.filter { seen.insert($0.task.id).inserted }.sorted { $0.frame.minY < $1.frame.minY }
        guard !block.isEmpty else { return }
        dragMotion.location = start
        var next = TaskListDrag(taskID: task.id, blockIDs: ids, visibleBlock: block,
            startFrame: CGRect(x: head.frame.minX, y: head.frame.minY, width: head.frame.width, height: 32), startLocation: start,
            rootIDs: roots.map(\.id), sourceDepth: roots.first.map { model.depth(of: $0) } ?? model.depth(of: task),
            subtreeHeight: roots.map { model.subtreeHeight(of: $0) }.max() ?? 0)
        // The source itself becomes the single-line placeholder; never create
        // a separate replacement gap or remove the view owning mouse-down.
        let members = rowFrames.filter { !ids.contains($0.task.id) && $0.region == head.region }.sorted { $0.frame.minY < $1.frame.minY }
        let slot = members.prefix { $0.frame.midY < head.frame.midY }.count
        let target = TaskReorderEngine.Target(groupID: task.category, slot: slot, level: next.sourceDepth,
            parentID: roots.first?.parentId, beforeID: members.dropFirst(slot).first?.task.id)
        let anchor: TaskInsertionSlot = slot < members.count ? .before(members[slot].task.id, region: head.region)
            : members.last.map { .after($0.task.id, region: head.region) } ?? .empty(head.region)
        next.destination = .init(target: target, region: head.region, slot: anchor, frame: head.frame, date: head.date)
        withAnimation(reorderAnimation()) { drag = next }
        ghostFrame = next.startFrame
        model.beginDrag(task.id, scope: "list:\(state.scope)")
        model.focusId = task.id
    }

    private func retargetReorder() {
        guard var next = drag, !next.committing else { return }
        let location = dragMotion.location
        let shelf = shelfFrames.first(where: { $0.value.contains(location) })?.key
        shelfTarget = shelf
        let entries = reorderRestEntries(listEntries, session: next)
        let rows = reorderRuntime.pickupFrames(rowFrames)
        let groups = reorderRuntime.pickupGroupFrames(groupFrames)
        func frame(_ entry: TaskListEntry) -> CGRect? {
            if let row = entry.row { return rows.first { $0.task.id == row.task.id && $0.region == row.region }?.frame }
            return groups.first { $0.region == entry.group?.region }?.frame
        }
        let content = entries.filter { entry in
            guard let bounds = frame(entry) else { return false }
            return entry.row == nil || (entry.expanded && TaskRowVisibility.hasUsableFrame(bounds))
        }
        let center = location.y - min(max(next.startLocation.y - next.startFrame.minY, 0), 32) + 16
        // Exactly Tic's count, with the gap open. Headings occupy the same
        // content stream and therefore move with the very same transaction.
        let slot = content.filter { (frame($0)?.midY ?? .greatestFiniteMagnitude) < center }.count
        let preceding = Array(content.prefix(slot))
        let owner = shelf.flatMap { id in content.first { $0.group?.id == id }?.group }
            ?? preceding.last.flatMap { entry -> TaskListGroupFrame? in
                let region = entry.row?.region ?? entry.group?.region
                return content.first { $0.group?.region == region }?.group
            } ?? content.first?.group
        guard let group = owner else { return }
        if let date = group.date, !model.tasks.contains(where: { next.blockIDs.contains($0.id) && $0.dueDate == date }) { return }
        if state.collapsedGroups.contains(group.id) {
            next.expandedDropGroup = group.id
            withAnimation(reorderAnimation()) { state.setGroupCollapsed(false, id: group.id) }
        }
        let members = content.compactMap(\.row).filter { $0.region == group.region }
        let rawSlot = shelf != nil ? members.count : preceding.compactMap(\.row).filter { $0.region == group.region }.count
        let engineRows = next.rootIDs.compactMap { id in model.tasks.first { $0.id == id } }.map {
            TaskReorderEngine.Row(id: $0.id, depth: model.depth(of: $0), groupID: $0.category, parentID: $0.parentId, midY: -1)
        } + members.enumerated().map { index, row in
            TaskReorderEngine.Row(id: row.task.id, depth: row.depth, groupID: row.task.category, parentID: row.task.parentId, midY: Double(index))
        }
        guard let target = TaskReorderEngine.target(rows: engineRows,
            groups: [.init(id: group.id, minY: -1, maxY: Double(members.count + 1))],
            draggedID: next.rootIDs.first ?? next.taskID, blockIDs: next.blockIDs,
            startY: 0, offsetY: Double(rawSlot) - 0.5, offsetX: location.x - next.startLocation.x,
            subtreeHeight: next.subtreeHeight) else { return }
        // The engine can advance across descendants to preserve subtree order.
        let anchor: TaskInsertionSlot = target.slot < members.count ? .before(members[target.slot].task.id, region: group.region)
            : members.last.map { .after($0.task.id, region: group.region) } ?? .empty(group.region)
        let destination = TaskDropDestination(target: target, region: group.region, slot: anchor, frame: .zero, date: group.date)
        guard destination.target != next.destination?.target || destination.slot != next.destination?.slot || next.expandedDropGroup != drag?.expandedDropGroup else { return }
        next.destination = destination
        withAnimation(reorderAnimation()) { drag = next }
    }

    private func finishReorder() {
        guard let drag, !drag.committing else { return }
        guard let target = drag.target, listViewport.contains(dragMotion.location) || shelfTarget != nil else { cancelReorder(); return }
        self.drag?.committing = true
        let complete = {
            // Publish the committed snapshot and retire the placeholder in one
            // transaction. There is no measured second landing or release clock.
            withAnimation(reorderAnimation(0.18)) { clearReorder() }
        }
        if drag.rootIDs.count == 1 {
            model.commitReorder(taskID: drag.rootIDs[0], to: target, completed: complete, failed: { clearReorder() })
        } else {
            model.change(completed: complete, failed: { clearReorder() }) { store in
                try TaskDragBatch.commit(ids: drag.rootIDs, target: target, store: store)
            }
        }
    }

    func cancelReorder() {
        guard drag != nil, drag?.committing == false else { return }
        dragCancelled = reorderGestureActive
        withAnimation(reorderAnimation(0.18)) { clearReorder() }
    }

    private func clearReorder() {
        drag = nil
        ghostFrame = .zero
        shelfTarget = nil
        model.endDrag()
    }

    func autoScrollReorder() {
        guard let drag, !drag.committing, shelfTarget == nil,
              dragMotion.location.x >= listViewport.minX, dragMotion.location.x <= listViewport.maxX else { return }
        let y = dragMotion.location.y
        let delta: CGFloat
        if y >= listViewport.minY - 24 && y < listViewport.minY + 24 {
            delta = -max(2, min(14, (listViewport.minY + 24 - y) * 0.45))
        } else if y > listViewport.maxY - 24 && y <= listViewport.maxY + 24 {
            delta = max(2, min(14, (y - listViewport.maxY + 24) * 0.45))
        } else { return }
        if reorderRuntime.scroll(by: delta) { retargetReorder() }
    }

}
