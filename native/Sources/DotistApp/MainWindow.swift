import AppKit
import Combine
import DotistCore
import SwiftUI

struct MainWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: TaskPanelState
    let showViews: () -> Void
    let showSearch: () -> Void
    let showSettings: () -> Void
    let showGroupPanel: (String) -> Void
    let collapse: () -> Void
    var close: (() -> Void)? = nil
    var primary = true
    @ObservedObject var toolbarConfig = ToolbarConfig.shared
    @State private var panelHovered = false
    @State private var composerHovered = false
    @State private var composerFocused = false
    @State private var toolbarDrag: ToolbarDragSession?
    @GestureState private var toolbarGestureActive = false
    @State private var toolbarFrames: [ToolbarItem: CGRect] = [:]
    @State private var showColorPicker = false
    @State private var shelfTarget: String?
    @State private var composer = ""
    @State private var composerSubmitting = false
    @State private var selectedSuggestion = -1
    @State private var category = DotistGroup.inboxID
    @State private var dueDate: Date?
    @State private var addingToGroup: String?
    @State private var groupTitles: [String: String] = [:]
    @State private var groupSubmitting = false
    @State private var editing: String?
    @State private var draftAfter: String?
    @State private var draftTitle = ""
    @State private var draftParent: String?
    @State private var draftHeight: CGFloat = 20
    @State private var draftSaving = false
    @State private var editedTitle = ""
    @State private var editSaving = false
    @State private var editHeight: CGFloat = 20
    @State private var pendingEdit: DotistTask?
    @State private var manageGroups = false
    @State private var manageTags = false
    @State private var showCalendar = false
    @State private var showDuePicker = false
    @State private var pickingTask: String?
    @State private var hoveredTask: String?
    @State private var hoveredGroup: String?
    @State private var customStart: String?
    @State private var customEnd: String?
    @State private var upcomingOpen = false
    @State private var todayDoneOpen = false
    private static let listSpace = "dotist-task-list"
    @State private var rowFrames: [TaskListRowFrame] = []
    @State private var groupFrames: [TaskListGroupFrame] = []
    @State private var shelfFrames: [String: CGRect] = [:]
    @State private var listViewport = CGRect.zero
    @State private var dragCancelled = false
    @GestureState private var reorderGestureActive = false
    @StateObject var reorderRuntime = TaskReorderRuntime()
    @State var dragMotion = TaskDragMotion()
    @StateObject var selection = TaskSelectionController()
    @State private var notice: String?
    @State private var noticeLifetime = PausableToastLifetime(duration: 2)
    @State private var undoToastLifetime = PausableToastLifetime(duration: 7)
    @State private var undoToastVisible = false
    @State private var ghostFrame = CGRect.zero

    private var drag: TaskListDrag? {
        get { reorderRuntime.drag }
        nonmutating set { reorderRuntime.drag = newValue }
    }

    private var textColor: Color { DotistDesign.ink }
    private var panelTasks: [DotistTask] {
        let tasks = state.activeTag.map { TaskTags.filter(model.tasks, tag: $0, description: model.tagDescription) } ?? model.tasks
        return tasks.filter { state.groupID == nil || $0.category == state.groupID }
    }
    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> Font {
        (serif ? DotistDesign.nameFont(size, weight: weight, language: model.language) : DotistDesign.textFont(size, weight: weight, language: model.language))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Text(model.text(error)).font(font(12)).foregroundColor(DotistDesign.danger).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
            if manageTags {
                TagManager(model: model, close: { manageTags = false }, groups: { manageTags = false; manageGroups = true }, select: { tag in state.activeTag = tag; state.scope = "all" })
            } else if manageGroups {
                GroupManager(model: model, close: { manageGroups = false }, tags: { manageGroups = false; manageTags = true })
            } else {
                header
                dateFilters
                if model.tagCounts.contains(where: { $0.open > 0 }) { tagBar }
                taskList
            }
            if !manageGroups && !manageTags {
                composerArea

            }
        }
        .coordinateSpace(name: Self.listSpace)
        .overlay(alignment: .topLeading) {
            ghostConnector
            if let drag {
                TaskLiftedBlock(drag: drag, motion: dragMotion) { row in
                    rowContent(row.task, children: model.children(of: row.task), sub: row.sub, allTasks: row.allTasks, previous: nil,
                               hideDue: row.hideDue, titleParts: model.tags(for: row.task), actionsVisible: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: listViewport.width, height: listViewport.height).offset(x: listViewport.minX, y: listViewport.minY)
                }
            }
        }
        .background(TaskReorderInteractionGuard(rowFrames: rowFrames.map(\.frame) + Array(toolbarFrames.values), dragging: drag != nil, cancel: cancelReorder, undoRedo: handleUndoShortcut))
        .onPreferenceChange(TaskListRowFrame.Key.self) { if rowFrames != $0 { rowFrames = $0 } }
        .onPreferenceChange(TaskListGroupFrame.Key.self) { if groupFrames != $0 { groupFrames = $0 } }
        .onPreferenceChange(TaskGhostFrameKey.self) { if ghostFrame != $0 { ghostFrame = $0 } }
        .onPreferenceChange(ToolbarFrameKey.self) { toolbarFrames = $0 }
        .onChange(of: toolbarGestureActive) { active in if !active { toolbarDrag = nil } }
        .onPreferenceChange(TaskShelfFrameKey.self) { shelfFrames = $0 }
        .onChange(of: reorderGestureActive) { active in
            if !active {
                if drag?.committing == false { cancelReorder() }
                dragCancelled = false
            }
        }
        .onReceive(Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()) { _ in autoScrollReorder() }
        .onReceive(model.$undo) { entry in
            undoToastVisible = entry != nil
            undoToastLifetime.restart(at: ProcessInfo.processInfo.systemUptime)
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            if undoToastVisible && !undoToastLifetime.isVisible(at: now) { undoToastVisible = false }
            if notice != nil && !noticeLifetime.isVisible(at: now) { notice = nil }
        }
        .onDisappear { cancelReorder(); leaveInputs(); selection.update { $0.clear() } }
        .onHover { panelHovered = $0 }
        .foregroundColor(textColor)
        .onAppear { category = state.groupID ?? DotistGroup.inboxID }
        .onChange(of: state.groupID) { id in
            cancelReorder()
            category = id ?? DotistGroup.inboxID
            leaveInputs()
            selection.update { $0.clear() }
        }
        .onChange(of: model.groups) { groups in
            if let id = state.groupID, !groups.contains(where: { $0.id == id }) { state.groupID = nil }
            if !groups.contains(where: { $0.id == category }) { category = state.groupID ?? DotistGroup.inboxID }
        }
        .onChange(of: model.tagDescription) { _ in
            if let tag = state.activeTag, !model.tagCounts.contains(where: { $0.tag == tag && $0.open > 0 }) { state.activeTag = nil }
        }
        .onChange(of: model.scope) { scope in if primary { state.scope = scope } }
        .onChange(of: state.scope) { scope in cancelReorder(); leaveInputs(); selection.update { $0.clear() }; if primary { model.scope = scope } }
        .onChange(of: model.scopeNavigation) { _ in
            guard primary else { return }
            state.activeTag = nil
            customStart = nil; customEnd = nil
            manageGroups = false; manageTags = false
        }
    }

    #if DEBUG
    static var taskListRenders = 0
    #endif

    private var taskList: some View {
        #if DEBUG
        Self.taskListRenders += 1
        #endif
        return ScrollViewReader { proxy in
            GeometryReader { space in
                ScrollView {
                    // An eager stack keeps the gesture source alive while auto-scrolling
                    // beyond the viewport. A lazy stack may recycle it mid-drag.
                    VStack(alignment: .leading, spacing: 0) {
                        listSections
                    }.padding(.horizontal, 16).padding(.bottom, 12)
                        .frame(minHeight: space.size.height, alignment: .topLeading)
                        .background(WindowDragArea())
                        .background(TaskReorderScrollBridge(runtime: reorderRuntime))
                }
                .background(GeometryReader { geometry in
                    Color.clear.onAppear { listViewport = geometry.frame(in: .named(Self.listSpace)) }
                        .onChange(of: geometry.frame(in: .named(Self.listSpace))) { listViewport = $0 }
                })
                .contextMenu { listMenu }
                .onChange(of: model.gotoGroup) { id in
                    guard primary, let id else { return }
                    state.groupID = id == DotistGroup.inboxID ? nil : id
                    withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.22)) { proxy.scrollTo(id, anchor: .top) }
                    model.gotoGroup = nil
                }
                .onReceive(selection.navigation) { id in proxy.scrollTo(id, anchor: .center) }
                .onChange(of: model.focusNavigation) { _ in
                    guard primary, let id = model.focusId else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
                .onAppear {
                    if let id = model.focusId { proxy.scrollTo(id, anchor: .center) }
                    else if let id = model.gotoGroup { proxy.scrollTo(id, anchor: .top) }
                    model.gotoGroup = nil
                }
            }
        }
    }

    @ViewBuilder private var listSections: some View {
        if state.scope == "all" { allGroups }
        else if state.scope == "today" && customStart == nil { todayList }
        else { filteredTasks }
    }

    @ViewBuilder private var listMenu: some View {
        Button(model.text("新建分组…")) { manageGroups = true }
        Button(model.text("管理分组…")) { manageGroups = true }
        Button(model.text("管理标签…")) { manageTags = true }
        Button(model.text("任务视图"), action: showViews)
        Button(model.text("收起为悬浮球"), action: collapse)
    }

    private var composerArea: some View {
        GlassEffectContainer(spacing: 12) {
            Group {
                if drag != nil { groupShelf } else { composerBar }
            }.overlay(alignment: .top) {
                if let notice {
                    Text(model.text(notice)).font(font(13)).foregroundStyle(DotistDesign.muted)
                        .padding(.horizontal, 16).frame(height: 36).glassEffect(.regular, in: .capsule).fixedSize().offset(y: -48)
                        .onHover { noticeLifetime.setHovered($0, at: ProcessInfo.processInfo.systemUptime) }
                        .onDisappear { noticeLifetime.setHovered(false, at: ProcessInfo.processInfo.systemUptime) }
                } else { undoToast }
            }
        }
    }

    @ViewBuilder private var undoToast: some View {
        if undoToastVisible, let undo = model.undo {
            HStack(alignment: .opticalCenter, spacing: 8) {
                OpticalText(title: model.text(undo.group ? "已删除分组「{title}」，任务已移至无分组" : "已删除「{title}」").replacingOccurrences(of: "{title}", with: undo.title), size: 13, language: model.language).lineLimit(1)
                Button { model.restore() } label: { OpticalText(title: model.text("撤销"), size: 13, weight: .medium, language: model.language) }.foregroundColor(DotistDesign.accent)
                Button { undoToastVisible = false } label: { OpticalSymbol(name: "xmark", size: 11).frame(width: 22, height: 22) }
                    .accessibilityLabel(Text(model.text("关闭")))
            }.buttonStyle(.plain).font(font(13)).foregroundColor(DotistDesign.muted)
                .padding(.leading, 16).padding(.trailing, 6).frame(height: 36)
                .glassEffect(.regular, in: .capsule).fixedSize().offset(y: -48)
                .onHover { undoToastLifetime.setHovered($0, at: ProcessInfo.processInfo.systemUptime) }
                .onDisappear { undoToastLifetime.setHovered(false, at: ProcessInfo.processInfo.systemUptime) }
                .accessibilityIdentifier("undo-toast")
        }
    }

    private func rowGeometry(_ task: DotistTask, sub: Bool, allTasks: Bool, hideDue: Bool) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: TaskListRowFrame.Key.self, value: [TaskListRowFrame(
                task: task, frame: geometry.frame(in: .named(Self.listSpace)), sub: sub, allTasks: allTasks, hideDue: hideDue
            )])
        }
    }

    private func groupGeometry(_ id: String, region: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: TaskListGroupFrame.Key.self, value: [TaskListGroupFrame(
                id: id, region: region, frame: geometry.frame(in: .named(Self.listSpace))
            )])
        }
    }

    private var showsInsertionGhost: Bool {
        guard let drag, shelfTarget == nil else { return false }
        return drag.target != drag.initialTarget
    }

    private var ghostBeforeID: String? { showsInsertionGhost ? drag?.ghostBeforeID : nil }
    private var ghostAfterID: String? { showsInsertionGhost ? drag?.ghostAfterID : nil }

    @ViewBuilder private func emptyGroupGhost(_ id: String, region: String) -> some View {
        if let drag, showsInsertionGhost, drag.target?.groupID == id, drag.region == region, drag.targetIsEmpty {
            taskGhost(compensatingIndent: 0)
        }
    }

    @ViewBuilder private func taskGhost(compensatingIndent: CGFloat) -> some View {
        if let drag, let target = drag.target {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(drag.visibleBlock, id: \.task.id) { row in
                    let depth = ghostDepth(row, drag: drag, target: target)
                    TaskRowLayout(depth: depth) {
                        TaskCheckmark(depth: depth, completed: false, children: [], emphasized: false)
                        Text(row.task.title).font(font(13)).foregroundStyle(DotistDesign.ink).lineLimit(1).fixedSize(horizontal: false, vertical: true)
                        Color.clear.frame(width: 0, height: 0)
                    }.frame(height: row.frame.height)
                }
            }.opacity(0.35).allowsHitTesting(false).accessibilityHidden(true)
                .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.12), value: target.level)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: TaskGhostFrameKey.self, value: geometry.frame(in: .named(Self.listSpace)))
                })
        }
    }

    private func ghostDepth(_ row: TaskListRowFrame, drag: TaskListDrag, target: TaskReorderEngine.Target) -> Int {
        let hierarchy = TaskHierarchy(model.tasks)
        let root = ([row.task] + hierarchy.ancestors(of: row.task.id)).first { drag.rootIDs.contains($0.id) }
        return min(4, target.level + model.depth(of: row.task) - (root.map { model.depth(of: $0) } ?? drag.sourceDepth))
    }

    @ViewBuilder private var ghostConnector: some View {
        if let drag, let target = drag.target, target.level > 0, shelfTarget == nil,
           let parent = rowFrames.first(where: { $0.task.id == target.parentID }),
           let first = drag.visibleBlock.first {
            let frame = showsInsertionGhost ? ghostFrame : drag.startFrame
            if frame != .zero {
                let parentDepth = model.depth(of: parent.task)
                let start = CGPoint(x: parent.frame.minX + TaskRowMetrics.circleX(parentDepth) - TaskRowMetrics.inset + TaskRowMetrics.diameter(parentDepth) / 2,
                                    y: parent.frame.midY + TaskRowMetrics.diameter(parentDepth) / 2 + 2)
                let end = CGPoint(x: frame.minX + TaskRowMetrics.circleX(target.level) - TaskRowMetrics.inset - 2,
                                  y: frame.minY + first.frame.height / 2)
                TaskGhostConnector(start: start, end: end)
                    .stroke(DotistDesign.rule, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.12), value: end)
                    .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.12), value: start)
                    .mask(alignment: .topLeading) {
                        Rectangle().frame(width: listViewport.width, height: listViewport.height).offset(x: listViewport.minX, y: listViewport.minY)
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func reorderGesture(_ task: DotistTask) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.listSpace))
            .updating($reorderGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard !dragCancelled, editing == nil, draftAfter == nil else { return }
                if drag == nil { beginReorder(task, at: value.startLocation) }
                guard drag?.taskID == task.id, drag?.committing == false else { return }
                dragMotion.location = value.location
                retargetReorder()
            }
            .onEnded { value in
                guard !dragCancelled, drag?.taskID == task.id, drag?.committing == false else { return }
                dragMotion.location = value.location
                retargetReorder()
                finishReorder()
            }
    }

    private func beginReorder(_ task: DotistTask, at start: CGPoint) {
        guard let head = rowFrames.first(where: { $0.task.id == task.id }) else { return }
        let hierarchy = TaskHierarchy(model.tasks)
        let selectedIDs = selection.value.ids.contains(task.id) ? Array(selection.value.ids) : [task.id]
        let roots = hierarchy.selectionRoots(ids: selectedIDs, groupIDs: model.groups.map(\.id))
            .sorted { a, b in (displayOrder.firstIndex(of: a.id) ?? 0) < (displayOrder.firstIndex(of: b.id) ?? 0) }
        let ids = Set(roots.flatMap { [$0.id] + model.descendants(of: $0).map(\.id) })
        let block = rowFrames.filter { ids.contains($0.task.id) && $0.frame.height > 0 }.sorted { $0.frame.minY < $1.frame.minY }
        guard let first = block.first else { return }
        dragMotion.location = start
        ghostFrame = .zero
        drag = TaskListDrag(taskID: task.id, blockIDs: ids, visibleBlock: block, startFrame: CGRect(x: head.frame.minX, y: first.frame.minY, width: head.frame.width, height: block.reduce(0) { $0 + $1.frame.height }), startLocation: start,
                            rootIDs: roots.map(\.id), sourceDepth: roots.first.map { model.depth(of: $0) } ?? model.depth(of: task), subtreeHeight: roots.map { model.subtreeHeight(of: $0) }.max() ?? 0)
        // Resolve against pre-drag geometry. Neither the source row nor the
        // composer changes height, and the initial slot adds no duplicate gap.
        drag?.baselineRows = rowFrames
        drag?.baselineGroups = groupFrames
        drag?.scrollOriginY = reorderRuntime.scrollOriginY
        model.beginDrag(task.id, scope: "list:\(state.scope)")
        model.focusId = task.id
        retargetReorder()
        drag?.initialTarget = drag?.target
    }

    private func retargetReorder() {
        guard var next = drag, !next.committing else { return }
        let location = dragMotion.location
        let shelf = shelfFrames.first(where: { $0.value.contains(location) })?.key
        if shelfTarget != shelf { shelfTarget = shelf }
        if let shelf {
            let wasCollapsed = state.collapsedGroups.contains(shelf)
            if wasCollapsed {
                withAnimation(groupCollapseAnimation) { state.setGroupCollapsed(false, id: shelf) }
                next.expandedDropGroup = shelf
            }
            let target = TaskCollapsedGroupDrop.target(groupID: shelf)
            if next.target != target || wasCollapsed { next.target = target; drag = next }
            return
        }
        // A collapsed header is a whole-group destination. Keep its append
        // target while its newly revealed rows animate under the pointer.
        let hoveredRegion = groupFrames.first { $0.frame.contains(location) }
        if let region = hoveredRegion, state.collapsedGroups.contains(region.id) {
            withAnimation(groupCollapseAnimation) { state.setGroupCollapsed(false, id: region.id) }
            next.expandedDropGroup = region.id
            next.target = TaskCollapsedGroupDrop.target(groupID: region.id)
            next.region = region.region
            next.ghostBeforeID = nil
            next.ghostAfterID = nil
            next.targetIsEmpty = true
            drag = next
            return
        }
        if let expanded = next.expandedDropGroup {
            if let region = hoveredRegion, region.id == expanded {
                next.target = TaskCollapsedGroupDrop.target(groupID: expanded)
                next.region = region.region
                next.ghostBeforeID = nil
                // The group's end placeholder follows all open task trees.
                next.ghostAfterID = nil
                next.targetIsEmpty = true
                if drag?.target != next.target || drag?.region != next.region { drag = next }
                return
            }
            // Rebase once after leaving the expanded group. Strip the live
            // placeholder so that it cannot feed back into pointer projection.
            let gap = showsInsertionGhost ? ghostFrame : .zero
            next.baselineRows = rowFrames.map { row in
                var row = row
                row.frame = TaskCollapsedGroupDrop.removingGap(row.frame, gap: gap)
                return row
            }
            next.baselineGroups = groupFrames.map { group in
                TaskListGroupFrame(id: group.id, region: group.region, frame: TaskCollapsedGroupDrop.removingGap(group.frame, gap: gap))
            }
            next.scrollOriginY = reorderRuntime.scrollOriginY
            next.expandedDropGroup = nil
        }
        let logicalY = showsInsertionGhost ? TaskDragGeometry.pointerY(location.y, excludingGhost: ghostFrame) : location.y
        let scrollDelta = reorderRuntime.scrollOriginY - next.scrollOriginY
        let groups = next.baselineGroups.sorted { $0.frame.minY < $1.frame.minY }
        let engineGroups = groups.map { TaskReorderEngine.Group(id: $0.id, minY: $0.frame.minY - scrollDelta, maxY: $0.frame.maxY - scrollDelta) }
        let rows = next.baselineRows.sorted { $0.frame.midY < $1.frame.midY }.map { row in
            TaskReorderEngine.Row(id: row.task.id, depth: model.depth(of: row.task), groupID: row.task.category, parentID: row.task.parentId, midY: row.frame.midY - scrollDelta)
        }
        let target = TaskReorderEngine.target(rows: rows, groups: engineGroups, draggedID: next.rootIDs.first ?? next.taskID, blockIDs: next.blockIDs, startY: next.startLocation.y, offsetY: logicalY - next.startLocation.y, offsetX: location.x - next.startLocation.x, indentStep: 22, subtreeHeight: next.subtreeHeight)
        let region = groups.first { $0.id == target?.groupID && logicalY >= $0.frame.minY - scrollDelta && logicalY < $0.frame.maxY - scrollDelta }
            ?? groups.filter { $0.id == target?.groupID }.min { abs($0.frame.midY - scrollDelta - logicalY) < abs($1.frame.midY - scrollDelta - logicalY) }
        // Frozen pre-drag geometry prevents a newly inserted gap from
        // feeding back into target selection or shifting the scroll origin.
        guard target != next.target || region?.region != next.region || drag?.expandedDropGroup != next.expandedDropGroup else { return }
        let rest = rows.filter { $0.groupID == target?.groupID && !next.blockIDs.contains($0.id) }
        let slot = target?.slot ?? 0
        next.target = target
        next.ghostBeforeID = rest.indices.contains(slot) ? rest[slot].id : nil
        next.ghostAfterID = slot >= rest.count ? rest.last?.id : nil
        next.targetIsEmpty = rest.isEmpty
        next.region = region?.region
        if drag?.initialTarget == nil {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { drag = next }
        } else {
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.12)) { drag = next }
        }
    }

    private func finishReorder() {
        guard let drag, !drag.committing else { return }
        guard let target = drag.target, listViewport.contains(dragMotion.location) || shelfTarget != nil else { cancelReorder(); return }
        self.drag?.committing = true
        let complete = { clearReorder() }
        if drag.rootIDs.count == 1 {
            model.commitReorder(taskID: drag.rootIDs[0], to: target, completed: complete, failed: { clearReorder() })
        } else {
            // Preflight every root before applying the gesture. Core owns
            // each subtree move and the model freezes observation until done.
            model.change(completed: complete, failed: { clearReorder() }) { store in
                try TaskDragBatch.commit(ids: drag.rootIDs, target: target, store: store)
            }
        }
    }

    private func cancelReorder() {
        guard drag != nil, drag?.committing == false else { return }
        dragCancelled = reorderGestureActive
        clearReorder()
    }

    private func clearReorder() {
        drag = nil
        ghostFrame = .zero
        shelfTarget = nil
        model.endDrag()
    }

    private func autoScrollReorder() {
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

    private var sortableToolbarItems: [ToolbarItem] {
        toolbarConfig.order.filter { $0 != .collapse && toolbarConfig.visibility(of: $0) != .hidden }
    }

    private var toolbarAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.16)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 4)
            ForEach(sortableToolbarItems, id: \.self) { item in
                toolbarItem(item)
                    .opacity(toolbarConfig.visibility(of: item) == .always || panelHovered || toolbarDrag != nil ? 1 : 0)
                    .allowsHitTesting(toolbarConfig.visibility(of: item) == .always || panelHovered)
                    .accessibilityHidden(toolbarConfig.visibility(of: item) == .hover && !panelHovered)
                    .offset(x: toolbarDrag?.offset(for: item) ?? 0)
                    .zIndex(toolbarDrag?.item == item ? 1 : 0)
                    .animation(toolbarDrag?.item == item ? nil : toolbarAnimation, value: toolbarDrag?.target)
                    .animation(toolbarAnimation, value: panelHovered)
                    .highPriorityGesture(toolbarReorderGesture(item))
            }
            if !primary, let close { toolbarButton("xmark", label: model.text("关闭面板"), action: close) }
            toolbarItem(.collapse)
        }.padding(.leading, 16).padding(.trailing, 10).frame(height: 44).background(WindowDragArea())
    }

    private func toolbarReorderGesture(_ item: ToolbarItem) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.listSpace))
            .updating($toolbarGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard item != .collapse else { return }
                if toolbarDrag == nil {
                    guard (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.command) else { return }
                    toolbarDrag = ToolbarDragSession(item: item, items: sortableToolbarItems)
                }
                guard toolbarDrag?.item == item else { return }
                toolbarDrag?.translation = value.translation.width
            }
            .onEnded { _ in
                guard let session = toolbarDrag, session.item == item else { return }
                withAnimation(toolbarAnimation) {
                    if session.items.indices.contains(session.target) {
                        toolbarConfig.move(item, onto: session.items[session.target])
                    }
                    toolbarDrag = nil
                }
            }
    }

    private func toolbarItem(_ item: ToolbarItem) -> some View {
        let symbol: String = switch item {
        case .views: "rectangle.split.2x1"
        case .pin: model.settings.alwaysOnTop ? "pin.fill" : "pin"
        case .lock: model.settings.locked ? "lock.fill" : "lock.open"
        case .color: "circle"
        case .collapse: "arrow.down.right.and.arrow.up.left"
        }
        let labelKey: String = switch item {
        case .views: "任务视图"
        case .pin: "置顶窗口"
        case .lock: "固定窗口"
        case .color: "颜色"
        case .collapse: "收起为悬浮球"
        }
        let label = model.text(labelKey)
        return Button {
            guard toolbarDrag == nil else { return }
            switch item {
            case .views: showViews()
            case .color: showColorPicker.toggle()
            case .collapse: collapse()
            case .pin: var patch = DotistSettingsPatch(); patch.alwaysOnTop = !model.settings.alwaysOnTop; model.updateSettings(patch)
            case .lock: var patch = DotistSettingsPatch(); patch.locked = !model.settings.locked; model.updateSettings(patch)
            }
        } label: {
            Group {
                if item == .color {
                    let color = state.selectedColor(in: model)
                    Circle().fill(color == .none ? Color.clear : DotistTheme.swatch(color))
                        .overlay { if color == .none { Circle().strokeBorder(DotistDesign.faint, lineWidth: 1) } }
                        .frame(width: 14, height: 14)
                } else { OpticalSymbol(name: symbol, size: 14) }
            }.frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(DotistDesign.muted)
            .help(label).accessibilityLabel(Text(label)).accessibilityIdentifier("toolbar:\(item.rawValue)")
            .popover(isPresented: Binding(get: { item == .color && showColorPicker }, set: { if item == .color { showColorPicker = $0 } })) { colorPicker }
            .background(GeometryReader { geometry in
                Color.clear.preference(key: ToolbarFrameKey.self, value: [item: geometry.frame(in: .named(Self.listSpace))])
            })
    }

    private var colorPicker: some View {
        HStack(spacing: 8) {
            ForEach(DotistGroupColor.allCases, id: \.self) { color in
                let selected = state.selectedColor(in: model) == color
                Button {
                    state.selectColor(color, in: model)
                    showColorPicker = false
                } label: {
                    Circle().fill(color == .none ? Color.clear : DotistTheme.swatch(color))
                        .overlay {
                            if color == .none {
                                Circle().strokeBorder(DotistDesign.faint, lineWidth: 1)
                                Path { path in
                                    path.move(to: CGPoint(x: 4, y: 18)); path.addLine(to: CGPoint(x: 18, y: 4))
                                }.stroke(DotistDesign.faint, lineWidth: 1)
                            }
                        }.frame(width: 22, height: 22)
                        .padding(4)
                        .overlay { if selected { Circle().strokeBorder(DotistDesign.accent, lineWidth: 2) } }
                        .contentShape(Circle())
                }.buttonStyle(.plain)
                    .help(model.text(colorLabel(color)))
                    .accessibilityLabel(Text(model.text(colorLabel(color))))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("panel-color:\(color.rawValue)")
            }
        }.padding(12)
    }

    @ViewBuilder private func groupColorMenu(_ groupID: String) -> some View {
        let current = model.groups.first { $0.id == groupID }.map { DotistGroupColor(rawValue: $0.color) } ?? .none
        ForEach(DotistGroupColor.allCases, id: \.self) { color in
            Button { model.setGroupColor(groupID, color) } label: {
                if current == color { Label(model.text(colorLabel(color)), systemImage: "checkmark") }
                else { Text(model.text(colorLabel(color))) }
            }.accessibilityIdentifier("group-color:\(groupID):\(color.rawValue)")
        }
    }

    private func colorLabel(_ color: DotistGroupColor) -> String {
        switch color {
        case .none: "无颜色"
        case .red: "红色"
        case .orange: "橙色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .teal: "青色"
        case .blue: "蓝色"
        case .purple: "紫色"
        case .pink: "粉色"
        }
    }

    private var dateFilters: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(model.settings.filters, id: \.self) { id in
                        DraggableFilterButton(title: model.text(filterLabel(id)), selected: customStart == nil && state.scope == id, language: model.language) {
                            state.scope = id; customStart = nil; customEnd = nil
                        }.accessibilityIdentifier("date-filter:\(id)")
                    }
                }
            }
            Button { showCalendar.toggle() } label: { OpticalSymbol(name: "calendar", size: 13).frame(width: 24, height: 24).contentShape(Rectangle()).foregroundColor(customStart == nil ? DotistDesign.muted : DotistDesign.accent) }
                .buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("日历")))
                .popover(isPresented: $showCalendar) {
                    RangeCalendar(model: model, start: customStart ?? Date().dotistDay, end: customEnd ?? Date().dotistDay, choose: { start, end in
                        state.scope = "today"
                        customStart = start
                        customEnd = end
                    }, close: { showCalendar = false })
                }
        }.padding(.leading, 16).padding(.trailing, 11).frame(height: 30).background(WindowDragArea())
    }

    private func toolbarButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { OpticalSymbol(name: symbol, size: 14).frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(DotistDesign.muted).help(label).accessibilityLabel(Text(label))
    }

    private var tagBar: some View {
        HStack(spacing: 14) {
            ForEach(model.tagCounts.filter { $0.open > 0 }) { tag in
                Button { state.activeTag = state.activeTag == tag.tag ? nil : tag.tag } label: {
                    OpticalText(title: "#" + tag.tag, size: 12, weight: state.activeTag == tag.tag ? .medium : .regular, language: model.language).frame(height: 24)
                }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(state.activeTag == tag.tag ? DotistDesign.ink : DotistDesign.faint)
            }
            Spacer()
            Button { manageTags = true } label: { OpticalText(title: model.text("管理…"), size: 12, language: model.language).frame(height: 24) }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(DotistDesign.faint)
        }.font(font(12)).padding(.horizontal, 16).frame(height: 24)
    }

    private func icon(_ symbol: String, label: String, active: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(font(15, .regular)).frame(width: 24, height: 24).contentShape(Rectangle()).foregroundColor(active == true ? DotistDesign.accent : DotistDesign.faint) }
            .buttonStyle(.plain).modifier(DotistFocusRing()).help(label).accessibilityLabel(Text(label))
            .accessibilityValue(Text(active.map { model.text($0 ? "已开启" : "已关闭") } ?? ""))
    }

    private func filterLabel(_ id: String) -> String {
        switch id {
        case "today": return "今天"
        case "tomorrow": return "明天"
        case "week": return "本周"
        case "nextweek": return "下周"
        case "next7": return "未来 7 天"
        case "overdue": return "已逾期"
        case "undated": return "无日期"
        case "done": return "已完成"
        default: return "全部"
        }
    }

    private var dropGroupIDs: [String] { [DotistGroup.inboxID] + model.visibleGroups.map(\.id) }

    @ViewBuilder private var allGroups: some View {
        if state.groupID == nil || state.groupID == DotistGroup.inboxID, let inbox = model.groups.first(where: { $0.id == DotistGroup.inboxID }) {
            taskGroup(inbox, showsHeader: false)
        }
        ForEach(model.visibleGroups.filter { state.groupID == nil || $0.id == state.groupID }) { group in
            taskGroup(group)
        }
    }

    private func taskGroup(_ group: DotistGroup, showsHeader: Bool = true) -> some View {
        let roots = showsHeader ? model.ordered(panelTasks.filter { $0.category == group.id && $0.parentId == nil })
            : model.ungroupedTasks.filter { root in panelTasks.contains { $0.id == root.id } }
        let openResult = model.filteredTasks(scope: "all", groupID: group.id, tag: state.activeTag)
        let completedResult = model.filteredTasks(scope: "done", groupID: group.id, tag: state.activeTag)
        let open = openResult.roots
        // A completed descendant belongs to its visible parent's full tree.
        // Only roots absent from the open trees belong in the folded section.
        let openRootIDs = Set(open.map(\.id))
        let completed = completedResult.roots.filter { !openRootIDs.contains($0.id) }
        let firstGroup = model.visibleGroups.first { state.groupID == nil || $0.id == state.groupID }?.id
        let firstSection = !showsHeader || (group.id == firstGroup && (state.groupID != nil || model.ungroupedTasks.isEmpty))
        return VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                groupHeader(group, empty: roots.isEmpty, after: open.last)
            }
            if state.showsGroupContents(group.id, hasHeader: showsHeader) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(open.enumerated()), id: \.element.id) { index, task in taskTree(task, previous: index > 0 ? open[index - 1].id : nil, next: index + 1 < open.count ? open[index + 1].id : nil, result: openResult) }
                    emptyGroupGhost(group.id, region: group.id)
                    if addingToGroup == group.id {
                        TaskRowLayout(depth: 0) {
                            TaskCheckmark(depth: 0, completed: false, children: [], emphasized: false)
                            TaskEditor(text: Binding(get: { groupTitles[group.id] ?? "" }, set: { groupTitles[group.id] = $0 }), height: $draftHeight, font: DotistDesign.nativeFont(13, language: model.language), label: model.text("新任务（{name}）").replacingOccurrences(of: "{name}", with: group.name), commit: { saveGroupDraft(group, continuing: true) }, cancel: { clearInputs() }, indent: { _ in }, blur: { saveGroupDraft(group, continuing: false) })
                                .id("group:\(group.id)").frame(height: draftHeight)
                            Color.clear.frame(width: 0, height: 0)
                        }

                    }
                    if !completed.isEmpty {
                        Button {
                            if state.folded.contains(group.id) { state.folded.remove(group.id) } else { state.folded.insert(group.id) }
                        } label: {
                            DisclosureRow(title: model.text("已完成"), expanded: state.folded.contains(group.id), language: model.language)
                        }.buttonStyle(.plain).modifier(DotistFocusRing())
                        if state.folded.contains(group.id) { ForEach(Array(completed.enumerated()), id: \.element.id) { index, task in taskTree(task, previous: index > 0 ? completed[index - 1].id : nil, next: index + 1 < completed.count ? completed[index + 1].id : nil, result: completedResult) } }
                    }
                }.transition(.opacity)
            }
        }.animation(groupCollapseAnimation, value: state.collapsedGroups.contains(group.id))
            .padding(.top, firstSection ? 6 : 20).id(group.id).contentShape(Rectangle())
            .background(groupGeometry(group.id, region: group.id))
    }

    private var groupCollapseAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.16)
    }

    private func toggleGroup(_ id: String) {
        leaveInputs()
        withAnimation(groupCollapseAnimation) { state.setGroupCollapsed(!state.collapsedGroups.contains(id), id: id) }
    }

    private func groupHeader(_ group: DotistGroup, empty: Bool, after task: DotistTask?, region: String? = nil) -> some View {
        let hoverID = region ?? group.id
        return GroupCollapseHeader(title: group.name, language: model.language, collapsed: state.collapsedGroups.contains(group.id),
                            hovered: hoveredGroup == hoverID, empty: empty, toggle: { toggleGroup(group.id) })
            .accessibilityLabel(Text(model.text(state.collapsedGroups.contains(group.id) ? "展开 {name}" : "折叠 {name}").replacingOccurrences(of: "{name}", with: group.name)))
            .accessibilityIdentifier("group-header:\(group.id)")
            .overlay(alignment: .trailing) {
                Button { beginGroupDraft(group, after: task) } label: { OpticalSymbol(name: "plus", size: 11).frame(width: 22, height: 22) }
                    .buttonStyle(.plain).modifier(DotistFocusRing()).foregroundStyle(DotistDesign.faint)
                    .accessibilityLabel(Text(model.text("添加任务（{name}）").replacingOccurrences(of: "{name}", with: group.name)))
                    .accessibilityIdentifier("group-add:\(group.id)")
                    .opacity(hoveredGroup == hoverID || addingToGroup == group.id ? 1 : 0)
                    .allowsHitTesting(hoveredGroup == hoverID || addingToGroup == group.id)
            }
            .padding(.top, 4)
            .onHover { over in if over { hoveredGroup = hoverID } else if hoveredGroup == hoverID { hoveredGroup = nil } }
            .contextMenu {
                Button(model.text("添加任务")) { beginGroupDraft(group, after: task) }
                Button(model.text("在独立面板中打开")) { showGroupPanel(group.id) }
                Menu(model.text("颜色")) { groupColorMenu(group.id) }
            }
    }

    private func taskTree(_ task: DotistTask, previous: String?, next: String?, result: TaskFilterResult) -> AnyView {
        // Group trees always show their complete subtree, including completed
        // children. Date-filtered lists render their own matching rows separately.
        let children = model.visibleChildren(of: task).filter { child in panelTasks.contains { $0.id == child.id } }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            taskRow(task, children: model.children(of: task), sub: model.depth(of: task) > 0, allTasks: false, previous: previous, next: next)
                .opacity(result.contextIDs.contains(task.id) ? 0.5 : 1)
            if model.depth(of: task) < DotistTask.maxDepth {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    taskTree(child, previous: index > 0 ? children[index - 1].id : nil, next: index + 1 < children.count ? children[index + 1].id : nil, result: result)
                }
            }
            draftRow(after: task, sub: model.depth(of: task) > 0)
        })
    }

    private var customDateRange: TaskDateRange? {
        customStart.map { TaskDateRange($0, customEnd ?? $0) }
    }

    private func dateFilterResult(completed: Bool = false, range: TaskDateRange? = nil) -> TaskFilterResult {
        model.filteredTasks(scope: state.scope, groupID: state.groupID, tag: state.activeTag,
                            customRange: range ?? customDateRange, completed: completed)
    }

    @ViewBuilder private var filteredTasks: some View {
        let result = dateFilterResult()
        if customDateRange == nil && state.scope == "overdue" {
            if result.matches.isEmpty { Text(model.text("没有逾期的任务。")).font(font(12)).foregroundColor(DotistDesign.muted) }
            else { todaySection("已逾期", result: result) }
        } else if customDateRange == nil && state.scope == "undated" {
            if result.matches.isEmpty { Text(model.text("每个任务都有到期日。")).font(font(12)).foregroundColor(DotistDesign.muted) }
            else { flatRows(result.tasks, contextIDs: result.contextIDs) }
        } else if customDateRange == nil && state.scope == "done" {
            if result.matches.isEmpty { Text(model.text("还没有完成的任务。")).font(font(12)).foregroundColor(DotistDesign.muted) }
            else { todaySection("已完成", result: result) }
        } else {
            let dates = Array(Set(result.matches.compactMap(\.dueDate))).sorted()
            let done = dateFilterResult(completed: true)
            VStack(alignment: .leading, spacing: 20) {
                ForEach(dates, id: \.self) { date in
                    todaySection(model.dueLabel(date), result: dateFilterResult(range: TaskDateRange(date, date)), hideDue: true)
                }
                if dates.isEmpty { Text(model.text("所选日期范围内没有未完成任务。")).font(font(12)).foregroundColor(DotistDesign.muted) }
                if !done.matches.isEmpty {
                    Button { todayDoneOpen.toggle() } label: {
                        DisclosureRow(title: model.text("已完成"), expanded: todayDoneOpen, language: model.language)
                    }.buttonStyle(.plain).modifier(DotistFocusRing())
                    if todayDoneOpen { flatRows(done.tasks, contextIDs: done.contextIDs) }
                }
            }
        }
    }

    private var rangeBounds: (String, String) {
        let range = customDateRange ?? model.dateFilterRange(scope: state.scope)
        return (range.start, range.end)
    }

    private var todayList: some View {
        let sections = model.todayTaskSections(groupID: state.groupID, tag: state.activeTag)
        return VStack(alignment: .leading, spacing: 20) {
            if !sections.overdue.matches.isEmpty { todaySection("已逾期", result: sections.overdue) }
            if !sections.today.matches.isEmpty { flatRows(sections.today.tasks, hideDue: true, contextIDs: sections.today.contextIDs) }
            if sections.overdue.matches.isEmpty && sections.today.matches.isEmpty {
                Text(model.text("今天没有要做的事。")).font(font(12)).foregroundColor(DotistDesign.muted)
            }
            if !sections.upcoming.matches.isEmpty {
                Button { upcomingOpen.toggle() } label: {
                    DisclosureRow(title: model.text("接下来 {n} 天").replacingOccurrences(of: "{n}", with: "7"), expanded: upcomingOpen, language: model.language)
                }.buttonStyle(.plain).modifier(DotistFocusRing())
                if upcomingOpen { flatRows(sections.upcoming.tasks, contextIDs: sections.upcoming.contextIDs) }
            }
            if !sections.completed.matches.isEmpty {
                Button { todayDoneOpen.toggle() } label: {
                    DisclosureRow(title: model.text("已完成"), expanded: todayDoneOpen, language: model.language)
                }.buttonStyle(.plain).modifier(DotistFocusRing())
                if todayDoneOpen { flatRows(sections.completed.tasks, contextIDs: sections.completed.contextIDs) }
            }
        }
    }
    private func todaySection(_ title: String, result: TaskFilterResult, hideDue: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .opticalCenter, spacing: 6) { OpticalText(title: model.text(title), size: 15, weight: .semibold, language: model.language).foregroundColor(title == "已逾期" ? DotistDesign.danger : DotistDesign.ink) }.frame(height: 30).padding(.top, 4).accessibilityIdentifier("section-heading:\(title)").preference(key: TaskSectionHeadingKey.self, value: [title])
            flatRows(result.tasks, hideDue: hideDue, contextIDs: result.contextIDs)
        }
    }
    private func flatRows(_ items: [DotistTask], hideDue: Bool = false, contextIDs: Set<String> = []) -> some View {
        ForEach(dropGroupIDs.filter { state.groupID == nil || $0 == state.groupID }, id: \.self) { id in
            let values = items.filter { $0.category == id }
            if !values.isEmpty { flatGroupRows(values, groupID: id, hideDue: hideDue, contextIDs: contextIDs) }
        }
    }

    private func flatGroupRows(_ items: [DotistTask], groupID: String, hideDue: Bool, contextIDs: Set<String> = []) -> some View {
        let region = "flat:\(items.first?.id ?? ""):\(groupID)"
        let ids = Set(items.map(\.id))
        let children = Dictionary(grouping: items.filter { $0.parentId != nil }, by: { $0.parentId! })
        let heads = items.filter { $0.parentId == nil || !ids.contains($0.parentId!) }
        func outline(_ task: DotistTask) -> [DotistTask] {
            [task] + (children[task.id] ?? []).flatMap(outline)
        }
        let outlined = heads.flatMap(outline)
        return VStack(alignment: .leading, spacing: 0) {
            if groupID != DotistGroup.inboxID, let group = model.groups.first(where: { $0.id == groupID }) {
                groupHeader(group, empty: false, after: heads.last, region: region)
            }
            if state.showsGroupContents(groupID, hasHeader: groupID != DotistGroup.inboxID) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(outlined.enumerated()), id: \.element.id) { index, task in
                        taskRow(task, children: model.children(of: task), sub: task.parentId != nil, allTasks: true, previous: index > 0 ? outlined[index - 1].id : nil, next: index + 1 < outlined.count ? outlined[index + 1].id : nil, hideDue: hideDue)
                            .opacity(contextIDs.contains(task.id) ? 0.5 : 1)

                        draftRow(after: task, sub: task.parentId != nil)

                    }
                    emptyGroupGhost(groupID, region: region)
                }.transition(.opacity)
            }
        }.animation(groupCollapseAnimation, value: state.collapsedGroups.contains(groupID))
            .background(groupGeometry(groupID, region: region))
    }

    private func taskRow(_ task: DotistTask, children: [DotistTask], sub: Bool, allTasks: Bool, previous: String?, next: String?, hideDue: Bool = false) -> some View {
        let titleParts = model.tags(for: task)
        let actionsVisible = drag == nil && model.dragId == nil && (hoveredTask == task.id || pickingTask == task.id)
        return VStack(alignment: .leading, spacing: 0) {
            if ghostBeforeID == task.id { taskGhost(compensatingIndent: 0) }
            interactiveTaskRow(task, children: children, sub: sub, allTasks: allTasks, previous: previous, next: next, hideDue: hideDue, titleParts: titleParts, actionsVisible: actionsVisible)
            if ghostAfterID == task.id { taskGhost(compensatingIndent: 0) }
        }
    }

    private func interactiveTaskRow(_ task: DotistTask, children: [DotistTask], sub: Bool, allTasks: Bool, previous: String?, next: String?, hideDue: Bool, titleParts: DotistTaskTags?, actionsVisible: Bool) -> some View {
        let carried = drag?.blockIDs.contains(task.id) == true
        return TaskSelectableContent(selection: selection.row(task.id)) { selected, focused in
            rowContent(task, children: children, sub: sub, allTasks: allTasks, previous: previous, hideDue: hideDue, titleParts: titleParts, actionsVisible: (actionsVisible || focused) && drag == nil && model.dragId == nil, selected: selected, focused: focused)
                .background {
                    let background = TaskRowBackgroundState(hovered: hoveredTask == task.id, selected: selected, editing: editing == task.id, dragging: drag != nil || model.dragId != nil, carried: carried)
                    RoundedRectangle(cornerRadius: 6).fill(DotistDesign.rule.opacity(background.opacity)).padding(.horizontal, -6)
                        .allowsHitTesting(false)
                        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || drag != nil || model.dragId != nil ? nil : .easeInOut(duration: 0.1), value: background)
                }
        }
        .frame(minHeight: sub ? 28 : 32)
        .contentShape(Rectangle())
        .onKeyPress(keys: [.return, .space, .tab, .escape, .upArrow, .downArrow], phases: .down) { press in
            handleRowKey(press, task: task, previous: previous, allTasks: allTasks)
        }
        .onTapGesture { clickRow(task) }
        .gesture(reorderGesture(task), including: editing == nil && draftAfter == nil ? .all : .subviews)
        .onHover { over in if over { hoveredTask = task.id } else if hoveredTask == task.id { hoveredTask = nil } }
        .popover(isPresented: Binding(get: { pickingTask == task.id }, set: { if !$0 && pickingTask == task.id { pickingTask = nil } })) {
            RangeCalendar(model: model, start: task.dueDate ?? "", end: task.dueDate ?? "", choose: { date, _ in
                if task.dueDate == date { pickingTask = nil; return }
                model.change(completed: { pickingTask = nil }) { _ = try $0.setDueDate(task.id, date: date) }
            }, close: { pickingTask = nil }, single: true, clear: {
                model.change(completed: { pickingTask = nil }) { _ = try $0.setDueDate(task.id, date: nil) }
            })
        }
        .contextMenu { rowMenu(task, sub: sub, allTasks: allTasks, previous: previous, next: next) }
        .accessibilityElement(children: .contain)
        // Preserve the full source geometry and the live gesture throughout.
        .opacity(carried ? 0.35 : 1)
        .background(rowGeometry(task, sub: sub, allTasks: allTasks, hideDue: hideDue))
        .accessibilityIdentifier("task-row:\(task.id)")
    }

    @ViewBuilder private func rowMenu(_ task: DotistTask, sub: Bool, allTasks: Bool, previous: String?, next: String?) -> some View {
            Button(model.text("编辑 {title}").replacingOccurrences(of: "{title}", with: task.title)) { beginEditing(task) }
            if model.depth(of: task) < 4 { Button(model.text("添加子任务")) { startDraft(after: task, asChild: true) } }
            if task.parentId != nil { Button(model.text("取消缩进")) { changeIndent(ids: [task.id], reverse: true) } }
            if previous != nil {
                Button(model.text("缩进为上一条的子任务")) {
                    changeIndent(ids: [task.id], reverse: false)
                }
            }
            if let previous { Button(model.text("上移")) { model.reorder(task.id, relativeTo: previous, after: false, allTasks: allTasks) } }
            if let next { Button(model.text("下移")) { model.reorder(task.id, relativeTo: next, after: true, allTasks: allTasks) } }
            Menu(model.text("到期日")) {
                Button(model.text("今天")) { let date = Date().dotistDay; model.change { _ = try $0.setDueDate(task.id, date: date) } }
                Button(model.text("明天")) { let date = Calendar.current.date(byAdding: .day, value: 1, to: Date())!.dotistDay; model.change { _ = try $0.setDueDate(task.id, date: date) } }
                Button(model.text(task.dueDate == nil ? "设置到期日…" : "修改到期日…")) { pickingTask = task.id }
                if task.dueDate != nil { Button(model.text("清除到期日")) { model.change { _ = try $0.setDueDate(task.id, date: nil) } } }
            }
            if !sub {
                Menu(model.text("分组")) {
                    ForEach(dropGroupIDs, id: \.self) { id in Button(model.groupDisplayName(id)) { model.change { _ = try $0.patchTask(id: task.id, category: id) } }.font(font(13, serif: true)) }
                }
            }
            Button(model.text(task.completed ? "恢复" : "完成")) { model.complete(task) }
            Button(model.text("删除")) { model.delete(task) }
    }

    private func rowContent(_ task: DotistTask, children: [DotistTask], sub: Bool, allTasks: Bool, previous: String?, hideDue: Bool, titleParts: DotistTaskTags?, actionsVisible: Bool, selected: Bool = false, focused: Bool = false) -> some View {
        let depth = model.depth(of: task)
        let actionCount = (depth < 4 ? 1 : 0) + (task.dueDate == nil ? 1 : 0) + 1
        let fadeWidth = actionsVisible ? TaskRowActionMetrics.width(count: actionCount) : 0
        return TaskRowLayout(depth: depth) {
            Button { selection.update { $0.clear() }; model.complete(task) } label: {
                TaskCheckmark(depth: depth, completed: task.completed, children: children.map(\.completed), emphasized: selected || focused || drag?.target?.parentID == task.id)
            }.buttonStyle(.plain).focusEffectDisabled()
                .accessibilityLabel(Text(model.text(task.completed ? "恢复 {title}" : "完成 {title}").replacingOccurrences(of: "{title}", with: task.title)))
            if editing == task.id {
                TaskEditor(text: $editedTitle, height: $editHeight, font: DotistDesign.nativeFont(13, language: model.language), label: model.text("任务内容"), commit: {
                    saveEditing(task) { startDraft(after: task) }
                }, cancel: { clearEditing() }, indent: { reverse in
                    saveEditing(task) { changeIndent(ids: [task.id], reverse: reverse); selection.row(task.id).focusRequest.send() }
                }, blur: { saveEditing(task) }).id("edit:\(task.id)").frame(height: editHeight)
            } else {
                HStack(alignment: .opticalCenter, spacing: 4) {
                    OpticalText(title: titleParts?.tags.isEmpty == false ? (titleParts?.text ?? task.title) : task.title, size: 13, weight: selected ? .medium : .regular, language: model.language).lineLimit(1).truncationMode(.tail)
                        .foregroundColor(task.completed ? DotistDesign.faint : focused ? DotistDesign.accent : DotistDesign.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(titleParts?.tags ?? [], id: \.self) { tag in
                        Button {
                            if NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty { state.activeTag = state.activeTag == tag ? nil : tag }
                            else { clickRow(task, edit: false) }
                        } label: {
                            OpticalText(title: "#" + tag, size: 12, weight: state.activeTag == tag ? .medium : .regular, language: model.language)
                        }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(state.activeTag == tag ? DotistDesign.ink : DotistDesign.faint).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .mask { if fadeWidth > 0 { TaskTitleFade(trailing: fadeWidth, rowRight: listViewport.maxX - 16) } else { Rectangle() } }
                    .contentShape(Rectangle())
                    .onTapGesture { clickRow(task) }

            }
            rowMetadata(task, children: children, allTasks: allTasks)
                .opacity(editing == task.id ? 0 : 1)
                .allowsHitTesting(editing != task.id)
            rowActions(task, allTasks: allTasks, visible: actionsVisible)
        }
    }

    private func rowMetadata(_ task: DotistTask, children: [DotistTask], allTasks: Bool) -> some View {
            HStack(alignment: .opticalCenter, spacing: 8) {
            if let due = task.dueDate {
                Button { pickingTask = task.id } label: { OpticalText(title: model.dueLabel(due), size: 12, language: model.language) }.buttonStyle(.plain).modifier(DotistFocusRing())
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .foregroundColor(due < Date().dotistDay && !task.completed ? DotistDesign.danger : due == Date().dotistDay ? DotistDesign.accent : DotistDesign.muted)
                    .accessibilityLabel(Text(model.text("到期日 {date}，点击修改").replacingOccurrences(of: "{date}", with: model.dueLabel(due))))
                    .accessibilityIdentifier("task-due:\(task.id)")
            }
            if allTasks, state.groupID == nil, let group = model.group(for: task) { OpticalText(title: group.name, size: 12, weight: .semibold, serif: true, language: model.language).foregroundColor(DotistDesign.faint).lineLimit(1).fixedSize(horizontal: true, vertical: false) }
            if !children.isEmpty {
                OpticalText(title: "\(children.filter(\.completed).count)/\(children.count)", size: 12, language: model.language).foregroundColor(DotistDesign.faint)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("task-progress:\(task.id)")
                    .accessibilityLabel(Text(model.text("子任务 {done}/{total}").replacingOccurrences(of: "{done}", with: "\(children.filter(\.completed).count)").replacingOccurrences(of: "{total}", with: "\(children.count)")))
            }
            }.lineLimit(1).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                .contentShape(Rectangle()).onTapGesture { }
    }

    @ViewBuilder private func rowActions(_ task: DotistTask, allTasks: Bool, visible: Bool) -> some View {
            if editing != task.id {
                HStack(spacing: 1) {
                    if model.depth(of: task) < 4 {
                        Button { startDraft(after: task, asChild: true) } label: { OpticalSymbol(name: "plus", size: 11).frame(width: 22, height: 22) }
                            .help(model.text("添加子任务"))
                            .accessibilityLabel(Text(model.text("添加子任务 {title}").replacingOccurrences(of: "{title}", with: task.title)))
                    }
                    if task.dueDate == nil {
                        Button { pickingTask = task.id } label: { OpticalSymbol(name: "calendar", size: 11).frame(width: 22, height: 22) }
                            .help(model.text("设置到期日"))
                            .accessibilityLabel(Text(model.text("设置到期日 {title}").replacingOccurrences(of: "{title}", with: task.title)))
                    }
                    Button { model.delete(task) } label: { OpticalSymbol(name: "xmark", size: 11).frame(width: 22, height: 22) }
                        .help(model.text("删除"))
                        .accessibilityLabel(Text(model.text("删除 {title}").replacingOccurrences(of: "{title}", with: task.title)))
                }.buttonStyle(.plain).font(font(11, .regular)).foregroundColor(DotistDesign.muted)
                    .fixedSize()
                    .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
                    .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15), value: visible)
            }
    }

    private var displayOrder: [String] {
        var seen: Set<String> = []
        return rowFrames.filter { $0.frame.height > 0 }.sorted { $0.frame.minY < $1.frame.minY }.compactMap { seen.insert($0.task.id).inserted ? $0.task.id : nil }
    }

    private func clickRow(_ task: DotistTask, edit: Bool = true) {
        let flags = NSEvent.modifierFlags
        selection.update { $0.click(task.id, order: displayOrder, shift: flags.contains(.shift), command: flags.contains(.command)) }
        selection.row(task.id).focusRequest.send()
        if flags.intersection([.shift, .command]).isEmpty && edit { beginEditing(task) }
    }

    private func changeIndent(ids: [String], reverse: Bool) {
        let complete = { }
        let failed = { showNotice(model.error ?? model.text("无法更改任务层级")); model.error = nil }
        if reverse { model.outdent(ids: ids, completed: complete, failed: failed) }
        else { model.indent(ids: ids, completed: complete, failed: failed) }
    }

    private func showNotice(_ message: String) {
        noticeLifetime.restart(at: ProcessInfo.processInfo.systemUptime)
        notice = message
    }

    private func handleUndoShortcut(redo: Bool) -> Bool {
        guard !composerFocused, editing == nil, draftAfter == nil, addingToGroup == nil else { return false }
        if redo {
            guard model.canRedoAction else { return false }
            model.redoLast()
            showNotice("已重做")
        } else {
            guard model.canUndoAction else { return false }
            model.undoLast()
            showNotice("已撤销")
        }
        return true
    }

    private func handleRowKey(_ press: KeyPress, task: DotistTask, previous: String?, allTasks: Bool) -> KeyPress.Result {
        guard editing == nil else { return .ignored }
        let order = displayOrder
        if press.key == .escape { selection.update { $0.clear() }; clearInputs(); return .handled }
        if press.key == .upArrow || press.key == .downArrow {
            let direction = press.key == .upArrow ? -1 : 1
            if press.modifiers.contains(.option) {
                let siblings = model.ordered(model.tasks.filter { $0.parentId == task.parentId && $0.category == task.category && $0.completed == task.completed })
                if let i = siblings.firstIndex(where: { $0.id == task.id }), siblings.indices.contains(i + direction) { model.reorder(task.id, relativeTo: siblings[i + direction].id, after: direction > 0, allTasks: false) }
            } else if let i = order.firstIndex(of: task.id), order.indices.contains(i + direction) {
                let id = order[i + direction]
                selection.update {
                    if press.modifiers.contains(.shift) {
                        if $0.anchor == nil { $0.anchor = task.id }
                        $0.click(id, order: order, shift: true, command: false)
                    } else { $0.clear() }
                }
                selection.row(id).focusRequest.send(); selection.navigation.send(id)
            }
            return .handled
        }
        if press.key == .return {
            if press.modifiers.contains(.command) { model.complete(task) }
            else {
                let last = selection.value.last(in: order).flatMap { id in model.tasks.first { $0.id == id } } ?? task
                selection.update { $0.clear() }; startDraft(after: last)
            }
            return .handled
        }
        if press.key == .space { model.complete(task); return .handled }
        if press.key == .tab {
            let ids = selection.value.ids.isEmpty ? [task.id] : order.filter { selection.value.ids.contains($0) }
            clearInputs()
            changeIndent(ids: ids, reverse: press.modifiers.contains(.shift))
            return .handled
        }
        return .ignored
    }

    private func beginGroupDraft(_ group: DotistGroup, after task: DotistTask?) {
        withAnimation(groupCollapseAnimation) { state.setGroupCollapsed(false, id: group.id) }
        if let task { startDraft(after: task) }
        else { clearInputs(); addingToGroup = group.id; groupTitles[group.id] = "" }
    }

    private func saveGroupDraft(_ group: DotistGroup, continuing: Bool) {
        guard addingToGroup == group.id, !groupSubmitting else { return }
        guard let title = TaskDraftFlow.titleToSave(groupTitles[group.id] ?? "") else { clearInputs(); return }
        groupSubmitting = true
        var created: DotistTask?
        model.change(completed: {
            groupSubmitting = false
            guard addingToGroup == group.id else { return }
            clearInputs()
            if continuing, let created { startDraft(after: created) }
        }, failed: { groupSubmitting = false }) { created = try $0.addTask(title: title, category: group.id) }
    }

    private func leaveInputs() {
        if let id = editing, let task = model.tasks.first(where: { $0.id == id }) {
            saveEditing(task) { clearInputs() }
        } else if let id = draftAfter, let task = model.tasks.first(where: { $0.id == id }) {
            saveDraft(after: task, continueEditing: false)
        } else if let id = addingToGroup, let group = model.groups.first(where: { $0.id == id }) {
            saveGroupDraft(group, continuing: false)
        } else { clearInputs() }
    }

    private func clearEditing() { editing = nil; editedTitle = ""; editHeight = 20; pendingEdit = nil }
    private func clearDraft() { draftAfter = nil; draftTitle = ""; draftParent = nil; draftHeight = 20 }
    private func clearInputs() {
        clearDraft(); clearEditing(); addingToGroup = nil; groupTitles.removeAll()
    }

    private func startDraft(after task: DotistTask, asChild: Bool = false) {
        clearInputs()
        draftAfter = task.id; draftParent = asChild && model.depth(of: task) < 4 ? task.id : task.parentId
    }

    @ViewBuilder private func draftRow(after task: DotistTask, sub: Bool) -> some View {
        if draftAfter == task.id {
            let depth = draftParent.flatMap { id in model.tasks.first { $0.id == id } }.map { model.depth(of: $0) + 1 } ?? 0
            TaskRowLayout(depth: depth) {
                TaskCheckmark(depth: depth, completed: false, children: [], emphasized: false)
                TaskEditor(text: $draftTitle, height: $draftHeight, font: DotistDesign.nativeFont(13, language: model.language), label: model.text("任务内容"), commit: {
                    saveDraft(after: task, continueEditing: true)
                }, cancel: { clearDraft() }, indent: { reverse in
                    draftParent = TaskDraftFlow.parent(reverse: reverse, current: draftParent, after: task, tasks: model.tasks)
                }, blur: { saveDraft(after: task, continueEditing: false) })
                    .id("draft:\(task.id)").frame(height: draftHeight)
                Color.clear.frame(width: 0, height: 0)
            }.background(RoundedRectangle(cornerRadius: 6).fill(DotistDesign.rule.opacity(0.18)).padding(.horizontal, -6))
        }
    }

    private func saveDraft(after task: DotistTask, continueEditing: Bool) {
        guard draftAfter == task.id, !draftSaving else { return }
        guard let title = TaskDraftFlow.titleToSave(draftTitle) else { clearDraft(); return }
        draftSaving = true
        let parent = draftParent
        var created: DotistTask?
        model.change(completed: {
            draftSaving = false
            guard draftAfter == task.id else { return }
            clearDraft()
            if continueEditing, let created { startDraft(after: created) }
        }, failed: { draftSaving = false; showNotice(model.error ?? model.text("无法保存任务")); model.error = nil }) { store in
            let newTask = try store.addTask(title: title, category: task.category, parentId: parent, dueDate: task.dueDate)
            let hierarchy = TaskHierarchy(try store.listTasks())
            let anchor = ([task] + hierarchy.ancestors(of: task.id)).first { $0.parentId == parent }
            if let anchor { try store.reorder(newTask.id, relativeTo: anchor.id, after: true, allTasks: false) }
            created = newTask
        }
    }

    private func beginEditing(_ task: DotistTask) {
        guard editing != task.id else { return }
        if editSaving { pendingEdit = task; return }
        let start = { clearInputs(); editing = task.id; editedTitle = task.title }
        if let id = editing, let current = model.tasks.first(where: { $0.id == id }) { saveEditing(current, then: start) }
        else if let after = draftAfter, let current = model.tasks.first(where: { $0.id == after }), TaskDraftFlow.titleToSave(draftTitle) != nil {
            saveDraft(after: current, continueEditing: false)
            // The old draft callback is identity-guarded, so switching editor
            // cannot make a delayed blur save a different row's buffer.
            start()
        } else { start() }
    }

    private func saveEditing(_ task: DotistTask, then: @escaping () -> Void = {}) {
        guard editing == task.id, !editSaving else { return }
        guard let title = TaskDraftFlow.titleToSave(editedTitle), title != task.title else { clearEditing(); then(); return }
        editSaving = true
        model.change(completed: {
            editSaving = false
            if editing == task.id {
                let pending = pendingEdit
                clearEditing()
                if let pending { beginEditing(pending) } else { then() }
            }
        }, failed: { editSaving = false; pendingEdit = nil }) { _ = try $0.patchTask(id: task.id, title: title) }
    }

    private var composerBar: some View {
        let selectedID = dropGroupIDs.contains(category) ? category : DotistGroup.inboxID
        let selectedName = model.groupDisplayName(selectedID)
        let shownDue = dueDate?.dotistDay
        return ComposerLayout {
            Menu {
                Picker(model.text("分组"), selection: $category) {
                    ForEach(dropGroupIDs, id: \.self) { id in
                        Text(model.groupDisplayName(id)).font(font(13, serif: true)).tag(id)
                    }
                }.pickerStyle(.inline)
                Divider()
                Button(model.text("管理分组…")) { manageGroups = true }
            } label: {
                HStack(spacing: 4) {
                    ComposerGroupLabel(title: selectedName, language: model.language)
                }.foregroundColor(DotistDesign.muted).frame(height: ComposerMetrics.rowHeight)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height: ComposerMetrics.rowHeight).help(model.text("分组")).accessibilityLabel(Text(model.text("分组"))).accessibilityValue(Text(selectedName)).accessibilityIdentifier("composer-group")
            ZStack(alignment: .leading) {
                ComposerInput(text: $composer, focused: $composerFocused, placeholder: model.text("写下一件小事"), label: model.text("新任务"), font: DotistDesign.nativeFont(ComposerMetrics.fontSize, language: model.language), commit: addTask, navigate: { direction in
                    let values = tagSuggestions
                    guard !values.isEmpty else { return false }
                    selectedSuggestion = (selectedSuggestion + direction + values.count) % values.count
                    return true
                }, complete: { force in chooseSuggestion(force: force) }).tint(DotistDesign.accent).frame(height: ComposerMetrics.rowHeight).accessibilityIdentifier("composer-input")
                if !tagSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tagSuggestions.enumerated()), id: \.element) { index, tag in
                            Button("#" + tag) { selectedSuggestion = index; _ = chooseSuggestion(force: true) }
                                .buttonStyle(.plain).modifier(DotistFocusRing()).font(font(12, index == selectedSuggestion ? .medium : .regular)).foregroundColor(index == selectedSuggestion ? DotistDesign.ink : DotistDesign.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 28)
                        }
                    }.glassEffect(.regular, in: .rect(cornerRadius: 12)).offset(y: -CGFloat(tagSuggestions.count * 28 + 6)).zIndex(1)
                }
            }.frame(maxWidth: .infinity).frame(height: ComposerMetrics.rowHeight).onChange(of: composer) { _ in selectedSuggestion = -1 }
            Button { showDuePicker.toggle() } label: {
                IconTextRow(spacing: 4) {
                    if let shownDue { OpticalText(title: model.dueLabel(shownDue), size: 12, language: model.language).lineLimit(1) }
                    ComposerCalendarIcon(language: model.language).opacity(composerHovered || composerFocused ? 1 : 0)
                }.foregroundColor(shownDue == nil ? DotistDesign.muted : DotistDesign.accent)
            }
                .buttonStyle(.plain).frame(height: ComposerMetrics.rowHeight).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("设置到期日")))
                .help(model.text("设置到期日"))
                .accessibilityIdentifier("composer-due")
                .popover(isPresented: $showDuePicker) {
                    RangeCalendar(model: model, start: shownDue ?? "", end: shownDue ?? "", choose: { date, _ in dueDate = Date.dotistDay(date); showDuePicker = false }, close: { showDuePicker = false }, single: true, clear: { dueDate = nil; showDuePicker = false })
                }

        }.padding(.leading, 16).padding(.trailing, 11).frame(height: ComposerMetrics.barHeight).onHover { composerHovered = $0 }.overlay(alignment: .top) { Rectangle().fill(DotistDesign.rule).frame(height: 0.5) }
    }

    private var groupShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 18) {
            ForEach(dropGroupIDs, id: \.self) { id in
                OpticalText(title: model.groupDisplayName(id), size: 14, weight: shelfTarget == id ? .semibold : .regular, serif: true, language: model.language)
                    .foregroundColor(shelfTarget == id ? DotistDesign.ink : DotistDesign.faint)
                    .frame(height: 48).contentShape(Rectangle())
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: TaskShelfFrameKey.self, value: [id: geometry.frame(in: .named(Self.listSpace))])
                    })
            }
            Button { manageGroups = true } label: {
                IconTextRow(spacing: 4) {
                    OpticalSymbol(name: "plus", size: 11)
                    OpticalText(title: model.text("新分组"), size: 14, language: model.language)
                }.frame(height: 48)
            }.buttonStyle(.plain).foregroundColor(DotistDesign.faint)
        }.padding(.horizontal, 16).frame(height: 48)
        }.frame(height: ComposerMetrics.barHeight)
    }

    private var tagSuggestions: [String] {
        guard let range = composer.range(of: "(^|\\s)#([^\\s#]*)$", options: .regularExpression),
              let hash = composer[range].lastIndex(of: "#") else { return [] }
        let prefix = String(composer[composer.index(after: hash)...])
        return Array(model.tagCounts.filter { $0.open > 0 && $0.tag.lowercased().hasPrefix(prefix.lowercased()) && $0.tag != prefix }.prefix(6).map(\.tag))
    }
    private func chooseSuggestion(force: Bool) -> Bool {
        let values = tagSuggestions
        guard !values.isEmpty, force || selectedSuggestion >= 0,
              let range = composer.range(of: "#([^\\s#]*)$", options: .regularExpression) else { return false }
        composer.replaceSubrange(range, with: "#\(values[max(0, min(selectedSuggestion, values.count - 1))]) ")
        selectedSuggestion = -1
        return true
    }

    private func addTask() {
        let title = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !composerSubmitting else { return }
        let date = dueDate?.dotistDay ?? (["today", "tomorrow", "week", "nextweek", "next7"].contains(state.scope) ? rangeBounds.0 : nil)
        let selectedDue = dueDate
        let selectedCategory = dropGroupIDs.contains(category) ? category : DotistGroup.inboxID
        composerSubmitting = true
        model.change(completed: {
            composerSubmitting = false
            if composer.trimmingCharacters(in: .whitespacesAndNewlines) == title { composer = "" }
            if dueDate == selectedDue { dueDate = nil }
        }, failed: { composerSubmitting = false }) {
            _ = try $0.addTask(title: title, category: selectedCategory, dueDate: date)
        }
    }
}

struct DraggableFilterButton: View {
    let title: String
    let selected: Bool
    let language: String
    let choose: () -> Void
    @State private var hovering = false
    @State private var origin: (mouse: NSPoint, window: NSPoint)?

    var body: some View {
        Button { if origin == nil { choose() } } label: {
            OpticalText(title: title, size: TaskDateFilterMetrics.size(selected: selected), weight: TaskDateFilterMetrics.weight(selected: selected), language: language)
                .foregroundColor(selected ? DotistDesign.ink : hovering ? DotistDesign.muted : DotistDesign.faint)
                .lineLimit(1)
                .frame(width: TaskDateFilterMetrics.slotWidth(title: title, language: language), height: 30)
        }.buttonStyle(.plain).modifier(DotistFocusRing()).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .highPriorityGesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard let event = NSApp.currentEvent, let window = event.window else { return }
                    let mouse = window.convertPoint(toScreen: event.locationInWindow)
                    if origin == nil { origin = (NSPoint(x: mouse.x - value.translation.width, y: mouse.y + value.translation.height), window.frame.origin) }
                    guard let origin else { return }
                    window.setFrameOrigin(NSPoint(x: origin.window.x + mouse.x - origin.mouse.x, y: origin.window.y + mouse.y - origin.mouse.y))
                }.onEnded { _ in DispatchQueue.main.async { origin = nil } })
    }
}

/// The title and disclosure glyph retain the shared measured ink center.
struct GroupCollapseHeader: View {
    let title: String
    let language: String
    let collapsed: Bool
    let hovered: Bool
    var empty = false
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .opticalCenter, spacing: 6) {
                OpticalText(title: title, size: 15, weight: .semibold, serif: true, language: language)
                    .foregroundStyle(empty ? DotistDesign.faint : DotistDesign.ink).lineLimit(1)
                OpticalSymbol(name: collapsed ? "chevron.right" : "chevron.down", size: 9, weight: .semibold)
                    .foregroundStyle(DotistDesign.faint).opacity(collapsed || hovered ? 1 : 0)
                Spacer(minLength: 26)
            }.frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(DotistFocusRing())
    }
}

private struct HeaderMenuEscape: NSViewRepresentable {
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Hovering does not give a SwiftUI control keyboard focus.
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard event.keyCode == 53, let window = view?.window, event.window === window else { return event }
            isPresented = false
            return nil
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
    final class Coordinator {
        var monitor: Any?
    }
}
