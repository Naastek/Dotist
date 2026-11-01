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
    @ObservedObject private var toolbarConfig = ToolbarConfig.shared
    @State private var panelHovered = false
    @State private var composerHovered = false
    @State private var composerFocused = false
    @State private var draggedToolbarItem: ToolbarItem?
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
    @State private var drag: TaskListDrag?
    @State private var dragCancelled = false
    @GestureState private var reorderGestureActive = false
    @StateObject private var reorderRuntime = TaskReorderRuntime()
    @State var dragMotion = TaskDragMotion()
    @StateObject var selection = TaskSelectionController()
    @State private var notice: String?
    @State private var noticeToken = UUID()

    private var textColor: Color { DotistDesign.ink }
    private var panelTasks: [DotistTask] {
        let tasks = state.activeTag.map { TaskTags.filter(model.tasks, tag: $0, description: model.tagDescription) } ?? model.tasks
        return tasks.filter { state.groupID == nil || $0.category == state.groupID }
    }
    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> Font {
        DotistDesign.font(size, weight: weight, serif: serif, language: model.language)
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
        .overlay(alignment: .topLeading) { liftedTaskBlock }
        .background(TaskReorderInteractionGuard(rowFrames: rowFrames.map(\.frame), dragging: drag != nil, cancel: cancelReorder))
        .onPreferenceChange(TaskListRowFrame.Key.self) { if rowFrames != $0 { rowFrames = $0 } }
        .onPreferenceChange(TaskListGroupFrame.Key.self) { if groupFrames != $0 { groupFrames = $0 } }
        .onPreferenceChange(TaskGhostFrameKey.self) { reorderRuntime.ghostFrame = $0 }
        .onPreferenceChange(TaskShelfFrameKey.self) { shelfFrames = $0 }
        .onChange(of: reorderGestureActive) { active in
            if !active {
                if drag?.committing == false { cancelReorder() }
                dragCancelled = false
            }
        }
        .onReceive(Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()) { _ in autoScrollReorder() }
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
            if let id = state.groupID, !groups.contains(where: { $0.id == id }) { state.groupID = DotistGroup.inboxID }
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
                        emptyDropGroups
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
                    state.groupID = id
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
                if drag != nil && state.groupID != nil { groupShelf } else { composerBar }
            }.overlay(alignment: .top) {
                if let notice {
                    Text(model.text(notice)).font(font(13)).foregroundStyle(DotistDesign.muted)
                        .padding(.horizontal, 16).frame(height: 36).glassEffect(.regular, in: .capsule).fixedSize().offset(y: -48)
                } else { undoToast }
            }
        }
    }

    @ViewBuilder private var undoToast: some View {
        if let undo = model.undo {
            HStack(spacing: 8) {
                Text(model.text("已删除「{title}」").replacingOccurrences(of: "{title}", with: undo.title)).lineLimit(1)
                Button(model.text("撤销")) { model.restore() }.font(font(13, .medium)).foregroundColor(DotistDesign.accent)
                Button { model.undo = nil } label: { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 22, height: 22) }
                    .accessibilityLabel(Text(model.text("关闭")))
            }.buttonStyle(.plain).font(font(13)).foregroundColor(DotistDesign.muted)
                .padding(.leading, 16).padding(.trailing, 6).frame(height: 36)
                .glassEffect(.regular, in: .capsule).fixedSize().offset(y: -48)
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

    @ViewBuilder private var emptyDropGroups: some View {
        if drag != nil && state.scope != "all" && state.groupID == nil {
            ForEach(model.groups.filter { group in !rowFrames.contains { $0.task.category == group.id } }) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.name).font(font(15, .semibold, serif: true)).foregroundColor(DotistDesign.faint).frame(height: 34)
                    emptyGroupGhost(group.id, region: "empty:\(group.id)")
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .background(groupGeometry(group.id, region: "empty:\(group.id)"))
            }
        }
    }

    private var ghostBeforeID: String? { shelfTarget == nil ? drag?.ghostBeforeID : nil }
    private var ghostAfterID: String? { shelfTarget == nil ? drag?.ghostAfterID : nil }

    @ViewBuilder private func emptyGroupGhost(_ id: String, region: String) -> some View {
        if let drag, drag.target?.groupID == id, drag.region == region, drag.targetIsEmpty, shelfTarget == nil {
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
                        Text(row.task.title).font(font(13)).foregroundStyle(DotistDesign.ink).fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder private var liftedTaskBlock: some View {
        if let drag {
            TaskLiftedLayer(motion: dragMotion, origin: drag.startFrame.origin, start: drag.startLocation, content:
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(drag.visibleBlock, id: \.task.id) { row in
                        rowContent(row.task, children: model.children(of: row.task), sub: row.sub, allTasks: row.allTasks, previous: nil, hideDue: row.hideDue, titleParts: model.tags(for: row.task), actionsVisible: false, selected: selection.value.ids.contains(row.task.id))
                            .frame(width: row.frame.width, height: row.frame.height)
                    }
                }.frame(width: drag.startFrame.width, alignment: .leading)
                    .background(DotistDesign.paper.opacity(0.96))
                    .overlay { Rectangle().strokeBorder(DotistDesign.rule, lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.07), radius: 3, y: 2)
            ).allowsHitTesting(false).accessibilityHidden(true)
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
        reorderRuntime.ghostFrame = .zero
        drag = TaskListDrag(taskID: task.id, blockIDs: ids, visibleBlock: block, startFrame: CGRect(x: head.frame.minX, y: first.frame.minY, width: head.frame.width, height: block.reduce(0) { $0 + $1.frame.height }), startLocation: start,
                            rootIDs: roots.map(\.id), sourceDepth: roots.first.map { model.depth(of: $0) } ?? model.depth(of: task), subtreeHeight: roots.map { model.subtreeHeight(of: $0) }.max() ?? 0)
        model.beginDrag(task.id, scope: "list:\(state.scope)")
        model.focusId = task.id
        retargetReorder()
    }

    private func retargetReorder() {
        guard var next = drag, !next.committing else { return }
        let location = dragMotion.location
        let shelf = state.groupID != nil ? shelfFrames.first(where: { $0.value.contains(location) })?.key : nil
        if shelfTarget != shelf { shelfTarget = shelf }
        if let shelf {
            let target = TaskReorderEngine.Target(groupID: shelf, slot: Int.max, level: 0, parentID: nil, beforeID: nil)
            if next.target != target { next.target = target; drag = next }
            return
        }
        let groups = groupFrames.sorted { $0.frame.minY < $1.frame.minY }
        let engineGroups = groups.map { TaskReorderEngine.Group(id: $0.id, minY: $0.frame.minY, maxY: $0.frame.maxY) }
        let rows = rowFrames.sorted { $0.frame.midY < $1.frame.midY }.map { row in
            TaskReorderEngine.Row(id: row.task.id, depth: model.depth(of: row.task), groupID: row.task.category, parentID: row.task.parentId, midY: row.frame.midY)
        }
        let target = TaskReorderEngine.target(rows: rows, groups: engineGroups, draggedID: next.rootIDs.first ?? next.taskID, blockIDs: next.blockIDs, startY: next.startLocation.y, offsetY: location.y - next.startLocation.y, offsetX: location.x - next.startLocation.x, indentStep: 22, subtreeHeight: next.subtreeHeight)
        let region = groups.first { $0.id == target?.groupID && location.y >= $0.frame.minY && location.y < $0.frame.maxY }
            ?? groups.filter { $0.id == target?.groupID }.min { abs($0.frame.midY - location.y) < abs($1.frame.midY - location.y) }
        // Pointer movement is published ONLY to TaskLiftedLayer. The outline
        // changes once per slot/level/region transition, never per mouse event.
        guard target != next.target || region?.region != next.region else { return }
        let rest = rows.filter { $0.groupID == target?.groupID && !next.blockIDs.contains($0.id) }
        let slot = target?.slot ?? 0
        next.target = target
        next.ghostBeforeID = rest.indices.contains(slot) ? rest[slot].id : nil
        next.ghostAfterID = slot >= rest.count ? rest.last?.id : nil
        next.targetIsEmpty = rest.isEmpty
        next.region = region?.region
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.16)) { drag = next }
    }

    private func finishReorder() {
        guard let drag, !drag.committing else { return }
        guard let target = drag.target, listViewport.contains(dragMotion.location) || shelfTarget != nil else { cancelReorder(); return }
        self.drag?.committing = true
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reorderRuntime.ghostFrame != .zero && shelfTarget == nil {
            withAnimation(reduced ? nil : .easeOut(duration: 0.14)) {
                dragMotion.location.y = drag.startLocation.y + reorderRuntime.ghostFrame.minY - drag.startFrame.minY
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduced ? 0 : 0.14)) {
            let complete = {
                if let parent = target.parentID {
                    state.expanded.insert(parent)
                    state.expanded.formUnion(TaskHierarchy(model.tasks).ancestors(of: parent).map(\.id))
                }
                clearReorder()
            }
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
    }

    private func cancelReorder() {
        guard drag != nil, drag?.committing == false else { return }
        dragCancelled = reorderGestureActive
        clearReorder()
    }

    private func clearReorder() {
        drag = nil
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

    private var header: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 4)
            ForEach(toolbarConfig.order, id: \.self) { item in
                if toolbarConfig.visibility(of: item) != .hidden {
                    toolbarItem(item)
                        .opacity(toolbarConfig.visibility(of: item) == .always || panelHovered ? 1 : 0)
                        .allowsHitTesting(toolbarConfig.visibility(of: item) == .always || panelHovered)
                        .accessibilityHidden(toolbarConfig.visibility(of: item) == .hover && !panelHovered)
                        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.15), value: panelHovered)
                }
            }
            if !primary, let close { toolbarButton("xmark", label: model.text("关闭面板"), action: close) }
        }.padding(.leading, 16).padding(.trailing, 10).frame(height: 44).background(WindowDragArea())
    }

    private func toolbarItem(_ item: ToolbarItem) -> some View {
        let symbol: String = switch item {
        case .views: "rectangle.split.2x1"
        case .pin: model.settings.alwaysOnTop ? "pin.fill" : "pin"
        case .lock: model.settings.locked ? "lock.fill" : "lock.open"
        case .search: "magnifyingglass"
        case .collapse: "arrow.down.right.and.arrow.up.left"
        }
        let labelKey: String = switch item {
        case .views: "任务视图"
        case .pin: "置顶窗口"
        case .lock: "固定窗口"
        case .search: "搜索"
        case .collapse: "收起为悬浮球"
        }
        let label = model.text(labelKey)
        return toolbarButton(symbol, label: label) {
            switch item {
            case .views: showViews()
            case .search: showSearch()
            case .collapse: collapse()
            case .pin: var patch = DotistSettingsPatch(); patch.alwaysOnTop = !model.settings.alwaysOnTop; model.updateSettings(patch)
            case .lock: var patch = DotistSettingsPatch(); patch.locked = !model.settings.locked; model.updateSettings(patch)
            }
        }.onDrag {
            guard NSEvent.modifierFlags.contains(.command) else { return NSItemProvider() }
            draggedToolbarItem = item
            return NSItemProvider(object: item.rawValue as NSString)
        }.onDrop(of: ["public.utf8-plain-text"], isTargeted: nil) { _ in
            guard let source = draggedToolbarItem else { return false }
            toolbarConfig.move(source, onto: item); draggedToolbarItem = nil; return true
        }
    }

    private var dateFilters: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(model.settings.filters, id: \.self) { id in
                        DraggableFilterButton(title: model.text(filterLabel(id)), selected: state.scope == id, language: model.language) {
                            state.scope = id; customStart = nil; customEnd = nil
                        }
                    }
                }
            }
            Button { showCalendar.toggle() } label: { Image(systemName: "calendar").font(.system(size: 13)).frame(width: 24, height: 24).contentShape(Rectangle()).foregroundColor(customStart == nil ? DotistDesign.muted : DotistDesign.accent) }
                .buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("日历")))
                .popover(isPresented: $showCalendar) {
                    RangeCalendar(model: model, start: customStart ?? Date().dotistDay, end: customEnd ?? Date().dotistDay, choose: { start, end in
                        state.scope = "today"
                        customStart = start == Date().dotistDay && end == start ? nil : start
                        customEnd = customStart == nil ? nil : end
                    }, close: { showCalendar = false })
                }
        }.padding(.leading, 16).padding(.trailing, 11).padding(.bottom, 4).frame(height: 30).background(WindowDragArea())
    }

    private func toolbarButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14)).frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(DotistDesign.muted).help(label).accessibilityLabel(Text(label))
    }

    private var tagBar: some View {
        HStack(spacing: 14) {
            ForEach(model.tagCounts.filter { $0.open > 0 }) { tag in
                Button("#" + tag.tag) { state.activeTag = state.activeTag == tag.tag ? nil : tag.tag }
                    .buttonStyle(.plain).modifier(DotistFocusRing()).font(font(12, state.activeTag == tag.tag ? .medium : .regular)).foregroundColor(state.activeTag == tag.tag ? DotistDesign.ink : DotistDesign.faint)
            }
            Spacer()
            Button(model.text("管理…")) { manageTags = true }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(DotistDesign.faint)
        }.font(font(12)).padding(.horizontal, 16).frame(height: 24)
    }

    private func icon(_ symbol: String, label: String, active: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15, weight: .regular)).frame(width: 24, height: 24).contentShape(Rectangle()).foregroundColor(active == true ? DotistDesign.accent : DotistDesign.faint) }
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

    private var allGroups: some View {
        ForEach(model.groups.filter { state.groupID == nil || $0.id == state.groupID }) { group in
            taskGroup(group)
        }
    }

    private func taskGroup(_ group: DotistGroup) -> some View {
            let roots = model.ordered(panelTasks.filter { $0.category == group.id && $0.parentId == nil })
            let open = roots.filter { !$0.completed }
            let completed = roots.filter(\.completed)
            return VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.name).font(font(15, .semibold, serif: true)).foregroundColor(roots.isEmpty ? DotistDesign.faint : DotistDesign.ink)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 30).padding(.top, 4)
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 2) {
                            Button { showGroupPanel(group.id) } label: { Image(systemName: "arrow.up.right.square").frame(width: 22, height: 22) }
                                .accessibilityLabel(Text(model.text("独立面板 {name}").replacingOccurrences(of: "{name}", with: group.name)))
                            Button { beginGroupDraft(group, after: open.last) } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                                .accessibilityLabel(Text(model.text("添加任务（{name}）").replacingOccurrences(of: "{name}", with: group.name)))
                        }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(DotistDesign.faint)
                            .opacity(hoveredGroup == group.id || addingToGroup == group.id ? 1 : 0)
                    }
                    .contextMenu {
                        Button(model.text("添加任务")) { beginGroupDraft(group, after: open.last) }
                        Button(model.text("在独立面板中打开")) { showGroupPanel(group.id) }
                    }
                ForEach(Array(open.enumerated()), id: \.element.id) { index, task in taskTree(task, previous: index > 0 ? open[index - 1].id : nil, next: index + 1 < open.count ? open[index + 1].id : nil) }
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
                        HStack(spacing: 8) {
                            Image(systemName: state.folded.contains(group.id) ? "chevron.down" : "chevron.right").offset(x: -1).frame(width: 18)
                            Text(model.text("已完成"))
                        }.font(font(12)).foregroundColor(DotistDesign.faint).frame(height: 28)
                    }.buttonStyle(.plain).modifier(DotistFocusRing())
                    if state.folded.contains(group.id) { ForEach(Array(completed.enumerated()), id: \.element.id) { index, task in taskTree(task, previous: index > 0 ? completed[index - 1].id : nil, next: index + 1 < completed.count ? completed[index + 1].id : nil) } }
                }
            }.padding(.top, group.id == model.groups.first(where: { state.groupID == nil || $0.id == state.groupID })?.id ? 6 : 20).id(group.id).contentShape(Rectangle())
                .onHover { over in if over { hoveredGroup = group.id } else if hoveredGroup == group.id { hoveredGroup = nil } }
                .background(groupGeometry(group.id, region: group.id))
    }

    private func taskTree(_ task: DotistTask, previous: String?, next: String?) -> AnyView {
        let children = model.visibleChildren(of: task).filter { child in panelTasks.contains { $0.id == child.id } }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            taskRow(task, children: model.children(of: task), sub: model.depth(of: task) > 0, allTasks: false, previous: previous, next: next)
            if state.expanded.contains(task.id) && model.depth(of: task) < DotistTask.maxDepth {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    taskTree(child, previous: index > 0 ? children[index - 1].id : nil, next: index + 1 < children.count ? children[index + 1].id : nil)
                }
            }
            draftRow(after: task, sub: model.depth(of: task) > 0)
        })
    }

    @ViewBuilder private var filteredTasks: some View {
        let today = Date().dotistDay
        if state.scope == "overdue" {
            let values = model.ordered(panelTasks.filter { !$0.completed && $0.dueDate.map { $0 < today } == true })
            if values.isEmpty { Text(model.text("没有逾期的任务。")).font(font(12)).foregroundColor(DotistDesign.muted) }
            else { todaySection("已逾期", items: values) }
        } else if state.scope == "undated" {
            let values = panelTasks.filter { !$0.completed && $0.dueDate == nil }
            if values.isEmpty { Text(model.text("每个任务都有到期日。")).font(font(12)).foregroundColor(DotistDesign.muted) }
            else {
                ForEach(model.groups) { group in
                    let items = model.ordered(values.filter { $0.category == group.id })
                    if !items.isEmpty { todaySection(group.name, items: items) }
                }
            }
        } else if state.scope == "done" {
            let values = model.ordered(Array(panelTasks.filter(\.completed).sorted { $0.updatedAt > $1.updatedAt }.prefix(200)))
            if values.isEmpty { Text(model.text("还没有完成的任务。")).font(font(12)).foregroundColor(DotistDesign.muted) }
            else { todaySection("已完成", items: values) }
        } else {
            let bounds = rangeBounds
            let values = panelTasks.filter { $0.dueDate.map { $0 >= bounds.0 && $0 <= bounds.1 } == true }
            let dates = Array(Set(values.filter { !$0.completed }.compactMap(\.dueDate))).sorted()
            VStack(alignment: .leading, spacing: 20) {
                ForEach(dates, id: \.self) { date in
                    todaySection(model.dueLabel(date), items: model.ordered(values.filter { !$0.completed && $0.dueDate == date }), hideDue: true)
                }
                if dates.isEmpty { Text(model.text("今天没有安排。在下方添加，或在「全部」里给任务设置到期日。")).font(font(12)).foregroundColor(DotistDesign.muted) }
                let done = model.ordered(values.filter(\.completed))
                if !done.isEmpty {
                    Button { todayDoneOpen.toggle() } label: {
                        HStack { Image(systemName: todayDoneOpen ? "chevron.down" : "chevron.right").offset(x: -1).frame(width: 18); Text(model.text("已完成")) }.font(font(12)).foregroundColor(DotistDesign.muted)
                    }.buttonStyle(.plain).modifier(DotistFocusRing())
                    if todayDoneOpen { flatRows(done) }
                }
            }
        }
    }

    private var rangeBounds: (String, String) {
        if let customStart, let customEnd { return (customStart, customEnd) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        switch state.scope {
        case "tomorrow": let date = calendar.date(byAdding: .day, value: 1, to: today)!.dotistDay; return (date, date)
        case "week": return (monday.dotistDay, calendar.date(byAdding: .day, value: 6, to: monday)!.dotistDay)
        case "nextweek": return (calendar.date(byAdding: .day, value: 7, to: monday)!.dotistDay, calendar.date(byAdding: .day, value: 13, to: monday)!.dotistDay)
        case "next7": return (today.dotistDay, calendar.date(byAdding: .day, value: 6, to: today)!.dotistDay)
        default: return (today.dotistDay, today.dotistDay)
        }
    }

    private var todayList: some View {
        let today = Date().dotistDay
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: Date())!.dotistDay
        let overdue = model.ordered(panelTasks.filter { !$0.completed && $0.dueDate.map { $0 < today } == true })
        let due = model.ordered(panelTasks.filter { !$0.completed && $0.dueDate == today })
        let upcoming = model.ordered(panelTasks.filter { !$0.completed && $0.dueDate.map { $0 > today && $0 <= horizon } == true })
        let done = model.ordered(panelTasks.filter { task in
            guard task.completed, let date = task.dueDate, date <= today else { return false }
            if date == today { return true }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: task.updatedAt)?.dotistDay == today
        })
        return VStack(alignment: .leading, spacing: 20) {
            if !overdue.isEmpty { todaySection("已逾期", items: overdue) }
            if !due.isEmpty { todaySection("今天", items: due, hideDue: true) }
            if overdue.isEmpty && due.isEmpty {
                Text(model.text("今天没有要做的事。")).font(font(12)).foregroundColor(DotistDesign.muted)
            }
            if !upcoming.isEmpty {
                Button { upcomingOpen.toggle() } label: {
                    HStack { Image(systemName: upcomingOpen ? "chevron.down" : "chevron.right").frame(width: 18); Text(model.text("接下来 {n} 天").replacingOccurrences(of: "{n}", with: "7")) }
                        .font(font(12)).foregroundColor(DotistDesign.faint).frame(height: 28)
                }.buttonStyle(.plain).modifier(DotistFocusRing())
                if upcomingOpen { flatRows(upcoming) }
            }
            if !done.isEmpty {
                Button { todayDoneOpen.toggle() } label: {
                    HStack { Image(systemName: todayDoneOpen ? "chevron.down" : "chevron.right").offset(x: -1).frame(width: 18); Text(model.text("已完成")) }
                        .font(font(12)).foregroundColor(DotistDesign.faint).frame(height: 28)
                }.buttonStyle(.plain).modifier(DotistFocusRing())
                if todayDoneOpen { flatRows(done) }
            }
        }
    }
    private func todaySection(_ title: String, items: [DotistTask], hideDue: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) { Text(model.text(title)).font(font(15, .semibold, serif: true)).foregroundColor(title == "已逾期" ? DotistDesign.danger : DotistDesign.ink) }.frame(height: 30).padding(.top, 4)
            flatRows(items, hideDue: hideDue)
        }
    }
    private func flatRows(_ items: [DotistTask], hideDue: Bool = false) -> some View {
        ForEach(model.groups.filter { state.groupID == nil || $0.id == state.groupID }) { group in
            let values = items.filter { $0.category == group.id }
            if !values.isEmpty { flatGroupRows(values, group: group, hideDue: hideDue) }
        }
    }

    private func flatGroupRows(_ items: [DotistTask], group: DotistGroup, hideDue: Bool) -> some View {
        let region = "flat:\(items.first?.id ?? ""):\(group.id)"
        let ids = Set(items.map(\.id))
        let children = Dictionary(grouping: items.filter { $0.parentId != nil }, by: { $0.parentId! })
        let heads = items.filter { $0.parentId == nil || !ids.contains($0.parentId!) }
        func outline(_ task: DotistTask) -> [DotistTask] {
            [task] + (children[task.id] ?? []).flatMap(outline)
        }
        let outlined = heads.flatMap(outline)
        return VStack(alignment: .leading, spacing: 0) {
            if state.groupID == nil {
                Text(group.name).font(font(12, .semibold, serif: true)).foregroundColor(DotistDesign.faint).frame(height: 26)
            }
            ForEach(Array(outlined.enumerated()), id: \.element.id) { index, task in
                taskRow(task, children: model.children(of: task), sub: task.parentId != nil, allTasks: true, previous: index > 0 ? outlined[index - 1].id : nil, next: index + 1 < outlined.count ? outlined[index + 1].id : nil, hideDue: hideDue)

                draftRow(after: task, sub: task.parentId != nil)

            }
            emptyGroupGhost(group.id, region: region)
        }.background(groupGeometry(group.id, region: region))
    }

    private func taskRow(_ task: DotistTask, children: [DotistTask], sub: Bool, allTasks: Bool, previous: String?, next: String?, hideDue: Bool = false) -> some View {
        let titleParts = model.tags(for: task)
        let actionsVisible = hoveredTask == task.id || pickingTask == task.id
        return VStack(alignment: .leading, spacing: 0) {
            if ghostBeforeID == task.id { taskGhost(compensatingIndent: 0) }
            interactiveTaskRow(task, children: children, sub: sub, allTasks: allTasks, previous: previous, next: next, hideDue: hideDue, titleParts: titleParts, actionsVisible: actionsVisible)
            if ghostAfterID == task.id { taskGhost(compensatingIndent: 0) }
        }
    }

    private func interactiveTaskRow(_ task: DotistTask, children: [DotistTask], sub: Bool, allTasks: Bool, previous: String?, next: String?, hideDue: Bool, titleParts: DotistTaskTags?, actionsVisible: Bool) -> some View {
        let carried = drag?.blockIDs.contains(task.id) == true
        return TaskSelectableContent(selection: selection.row(task.id)) { selected, focused in
            rowContent(task, children: children, sub: sub, allTasks: allTasks, previous: previous, hideDue: hideDue, titleParts: titleParts, actionsVisible: actionsVisible || focused, selected: selected, focused: focused)
                .overlay(alignment: .trailing) { rowActions(task, sub: sub, allTasks: allTasks, hideDue: hideDue, visible: actionsVisible || focused) }
        }
        .frame(minHeight: sub ? 28 : 32)
        .background { if editing == task.id { RoundedRectangle(cornerRadius: 6).fill(DotistDesign.rule.opacity(0.18)).padding(.horizontal, -6) } }
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
        // Keep the source and its gesture mounted, even when its layout space is
        // occupied by a ghost in another group. Removing it ends SwiftUI's drag.
        .opacity(carried ? 0 : 1)
        .frame(height: carried ? 0 : nil, alignment: .top)
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
                    ForEach(model.groups) { group in Button(group.name) { model.change { _ = try $0.patchTask(id: task.id, category: group.id) } } }
                }
            }
            Button(model.text(task.completed ? "恢复" : "完成")) { model.complete(task) }
            Button(model.text("删除")) { model.delete(task) }
    }

    private func rowContent(_ task: DotistTask, children: [DotistTask], sub: Bool, allTasks: Bool, previous: String?, hideDue: Bool, titleParts: DotistTaskTags?, actionsVisible: Bool, selected: Bool = false, focused: Bool = false) -> some View {
        let depth = model.depth(of: task)
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
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(titleParts?.tags.isEmpty == false ? (titleParts?.text ?? task.title) : task.title)
                        .font(font(13, selected ? .medium : .regular)).lineSpacing(4)
                        .foregroundColor(task.completed ? DotistDesign.faint : focused ? DotistDesign.accent : DotistDesign.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(titleParts?.tags ?? [], id: \.self) { tag in
                        Button("#" + tag) {
                            if NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty { state.activeTag = state.activeTag == tag ? nil : tag }
                            else { clickRow(task, edit: false) }
                        }.buttonStyle(.plain).modifier(DotistFocusRing())
                            .font(font(12, state.activeTag == tag ? .medium : .regular)).foregroundColor(state.activeTag == tag ? DotistDesign.ink : DotistDesign.faint)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)

            }
            rowMetadata(task, children: children, allTasks: allTasks, hideDue: hideDue, visible: actionsVisible)
                .opacity(editing == task.id ? 0 : 1)
        }
    }

    private func rowMetadata(_ task: DotistTask, children: [DotistTask], allTasks: Bool, hideDue: Bool, visible: Bool) -> some View {
            HStack(spacing: 8) {
            if let due = task.dueDate, !hideDue {
                Button(model.dueLabel(due)) { pickingTask = task.id }.buttonStyle(.plain).modifier(DotistFocusRing()).font(font(12))
                    .foregroundColor(due < Date().dotistDay && !task.completed ? DotistDesign.danger : due == Date().dotistDay ? DotistDesign.accent : DotistDesign.muted)
                    .accessibilityLabel(Text(model.text("到期日 {date}，点击修改").replacingOccurrences(of: "{date}", with: model.dueLabel(due))))
            }
            if allTasks, state.groupID == nil, let group = model.group(for: task) { Text(group.name).font(font(12, .semibold, serif: true)).foregroundColor(DotistDesign.faint).lineLimit(1) }
            if !children.isEmpty {
                Button {
                    if state.expanded.contains(task.id) { state.expanded.remove(task.id) } else { state.expanded.insert(task.id) }
                } label: {
                    HStack(spacing: 2) {
                        Text("\(children.filter(\.completed).count)/\(children.count)")
                        Image(systemName: state.expanded.contains(task.id) ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                    }.font(font(12)).foregroundColor(DotistDesign.faint)
                }.buttonStyle(.plain).modifier(DotistFocusRing())
                    .accessibilityLabel(Text(model.text("子任务 {done}/{total}").replacingOccurrences(of: "{done}", with: "\(children.filter(\.completed).count)").replacingOccurrences(of: "{total}", with: "\(children.count)")))
            }
            }.opacity(visible ? 0 : 1)
    }

    @ViewBuilder private func rowActions(_ task: DotistTask, sub: Bool, allTasks: Bool, hideDue: Bool, visible: Bool) -> some View {
            if editing != task.id {
                HStack(spacing: 1) {
                    if model.depth(of: task) < 4 {
                        Button { startDraft(after: task, asChild: true) } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                            .help(model.text("添加子任务"))
                            .accessibilityLabel(Text(model.text("添加子任务 {title}").replacingOccurrences(of: "{title}", with: task.title)))
                    }
                    if task.dueDate == nil || hideDue {
                        Button { pickingTask = task.id } label: { Image(systemName: "calendar").frame(width: 22, height: 22) }
                            .help(model.text("设置到期日"))
                            .accessibilityLabel(Text(model.text("设置到期日 {title}").replacingOccurrences(of: "{title}", with: task.title)))
                    }
                    Button { model.delete(task) } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                        .help(model.text("删除"))
                        .accessibilityLabel(Text(model.text("删除 {title}").replacingOccurrences(of: "{title}", with: task.title)))
                }.buttonStyle(.plain).font(.system(size: 11, weight: .regular)).foregroundColor(DotistDesign.muted)
                    .offset(x: 5).opacity(visible ? 1 : 0).disabled(!visible).accessibilityHidden(!visible)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
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
        let complete = {
            let hierarchy = TaskHierarchy(model.tasks)
            for id in ids { state.expanded.formUnion(hierarchy.ancestors(of: id).map(\.id)) }
        }
        let failed = { showNotice(model.error ?? model.text("无法更改任务层级")); model.error = nil }
        if reverse { model.outdent(ids: ids, completed: complete, failed: failed) }
        else { model.indent(ids: ids, completed: complete, failed: failed) }
    }

    private func showNotice(_ message: String) {
        let token = UUID(); noticeToken = token; notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if noticeToken == token { notice = nil } }
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
        if let parent = draftParent { state.expanded.insert(parent) }
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
        let selected = model.groups.first(where: { $0.id == category }) ?? model.groups.first
        let shownDue = dueDate?.dotistDay
        return ComposerLayout {
            Menu {
                ForEach(model.groups) { group in
                    Button { category = group.id } label: { Label(group.name, systemImage: group.id == selected?.id ? "checkmark" : "") }
                }
                Divider()
                Button(model.text("管理分组…")) { manageGroups = true }
            } label: {
                HStack(spacing: 4) {
                    Text(selected?.name ?? "").font(font(13, .semibold, serif: true)).lineLimit(1)
                }.foregroundColor(DotistDesign.muted).frame(height: 24)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(model.text("分组")).accessibilityLabel(Text(model.text("分组"))).accessibilityValue(Text(selected?.name ?? ""))
            ZStack(alignment: .topLeading) {
                ComposerInput(text: $composer, focused: $composerFocused, placeholder: model.text("写下一件小事"), label: model.text("新任务"), font: DotistDesign.nativeFont(13, language: model.language), commit: addTask, navigate: { direction in
                    let values = tagSuggestions
                    guard !values.isEmpty else { return false }
                    selectedSuggestion = (selectedSuggestion + direction + values.count) % values.count
                    return true
                }, complete: { force in chooseSuggestion(force: force) }).tint(DotistDesign.accent).frame(height: 24)
                if !tagSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tagSuggestions.enumerated()), id: \.element) { index, tag in
                            Button("#" + tag) { selectedSuggestion = index; _ = chooseSuggestion(force: true) }
                                .buttonStyle(.plain).modifier(DotistFocusRing()).font(font(12, index == selectedSuggestion ? .medium : .regular)).foregroundColor(index == selectedSuggestion ? DotistDesign.ink : DotistDesign.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 28)
                        }
                    }.glassEffect(.regular, in: .rect(cornerRadius: 12)).offset(y: -CGFloat(tagSuggestions.count * 28 + 6)).zIndex(1)
                }
            }.frame(maxWidth: .infinity).onChange(of: composer) { _ in selectedSuggestion = -1 }
            Button { showDuePicker.toggle() } label: {
                HStack(spacing: 4) {
                    if let shownDue { Text(model.dueLabel(shownDue)).font(font(12)).lineLimit(1) }
                    Image(systemName: "calendar").font(.system(size: 13)).frame(width: 24, height: 24).opacity(composerHovered || composerFocused ? 1 : 0)
                }.foregroundColor(shownDue == nil ? DotistDesign.muted : DotistDesign.accent)
            }
                .buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("设置到期日")))
                .help(model.text("设置到期日"))
                .popover(isPresented: $showDuePicker) {
                    RangeCalendar(model: model, start: shownDue ?? "", end: shownDue ?? "", choose: { date, _ in dueDate = Date.dotistDay(date); showDuePicker = false }, close: { showDuePicker = false }, single: true, clear: { dueDate = nil; showDuePicker = false })
                }

        }.padding(.leading, 16).padding(.trailing, 11).frame(height: 52).onHover { composerHovered = $0 }.overlay(alignment: .top) { Rectangle().fill(DotistDesign.rule).frame(height: 0.5) }
    }

    private var groupShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 18) {
            ForEach(model.groups) { group in
                Text(group.name).font(font(14, .semibold, serif: true))
                    .foregroundColor(shelfTarget == group.id ? DotistDesign.ink : DotistDesign.faint)
                    .frame(height: 48).contentShape(Rectangle())
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: TaskShelfFrameKey.self, value: [group.id: geometry.frame(in: .named(Self.listSpace))])
                    })
            }
            Button("＋ " + model.text("新分组")) { manageGroups = true }
                .buttonStyle(.plain).font(font(14, .semibold, serif: true)).foregroundColor(DotistDesign.faint)
        }.padding(.horizontal, 22).frame(height: 48)
        }.frame(height: 52)
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
        guard let selectedCategory = model.groups.first(where: { $0.id == category })?.id ?? model.groups.first?.id else { return }
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

private struct ComposerLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { CGSize(width: proposal.width ?? 324, height: 24) }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let date = subviews[2].sizeThatFits(.unspecified).width
        let group = min(subviews[0].sizeThatFits(.unspecified).width, max(0, bounds.width - date - 70))
        subviews[0].place(at: CGPoint(x: bounds.minX - 3, y: bounds.minY), proposal: ProposedViewSize(width: group, height: 24))
        subviews[1].place(at: CGPoint(x: bounds.minX + group + 8, y: bounds.minY), proposal: ProposedViewSize(width: max(0, bounds.width - group - date - 16), height: 24))
        subviews[2].place(at: CGPoint(x: bounds.maxX - date, y: bounds.minY), proposal: ProposedViewSize(width: date, height: 24))
    }
}

private struct DraggableFilterButton: View {
    let title: String
    let selected: Bool
    let language: String
    let choose: () -> Void
    @State private var hovering = false
    @State private var origin: (mouse: NSPoint, window: NSPoint)?

    var body: some View {
        Button { if origin == nil { choose() } } label: {
            Text(title)
                .font(DotistDesign.font(13, weight: selected ? .medium : .regular, language: language))
                .foregroundColor(selected ? DotistDesign.ink : hovering ? DotistDesign.muted : DotistDesign.faint)
                .lineLimit(1)
                .frame(width: ceil((title as NSString).size(withAttributes: [.font: DotistDesign.nativeFont(13, weight: .medium, language: language)]).width) + 2, height: 30)
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
