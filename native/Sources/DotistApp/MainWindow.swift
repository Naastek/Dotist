import AppKit
import Combine
import DotistCore
import SwiftUI

struct MainWindow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var composerCueVisible = false
    @State private var composerCueGeneration = UUID()
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
    @State private var emptyAddHovered = false
    @State private var emptyStateHeight: CGFloat = 0
    @State private var editedTitle = ""
    @State private var editSaving = false
    @State private var editHeight: CGFloat = 20
    @State private var pendingEdit: DotistTask?
    @State private var manageGroups = false
    @State private var manageTags = false
    @State private var showCalendar = false
    @StateObject var filterPresentation = DateFilterPresentation()
    @State private var hideCompleted = false
    @State private var showDuePicker = false
    @State private var pickingTask: String?
    @State private var hoveredTask: String?
    @State private var hoveredGroup: String?
    private var customStart: String? {
        get { state.customStart }
        nonmutating set { state.customStart = newValue }
    }
    private var customEnd: String? {
        get { state.customEnd }
        nonmutating set { state.customEnd = newValue }
    }
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
                DateFilterPushdown(isOpen: filterPresentation.isOpen) { filterStrip }
                VStack(spacing: 0) {
                    activeFilterLine
                    if model.tagCounts.contains(where: { $0.open > 0 }) { tagBar }
                    taskList
                }.background(DateFilterContentClickObserver(enabled: filterPresentation.isOpen, dismiss: filterPresentation.contentClicked))
            }
            if !manageGroups && !manageTags {
                composerArea
                    .background(DateFilterContentClickObserver(enabled: filterPresentation.isOpen, dismiss: filterPresentation.contentClicked))
            }
        }
        .coordinateSpace(name: Self.listSpace)
        .overlay(alignment: .topLeading) {
            ghostConnector
            if let drag {
                TaskLiftedBlock(drag: drag, motion: dragMotion) { row in
                    rowContent(row.task, children: model.children(of: row.task), sub: row.sub, allTasks: row.allTasks, previous: nil,
                               hideDue: row.hideDue, titleParts: model.tags(for: row.task), actionsVisible: false,
                               selected: selection.value.ids.contains(row.task.id), depthOverride: row.depth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: listViewport.width, height: listViewport.height).offset(x: listViewport.minX, y: listViewport.minY)
                }
            }
        }
        .background(TaskPickupFrameProbe(runtime: reorderRuntime, role: .panel))
        .background(TaskReorderInteractionGuard(rowFrames: rowFrames.map(\.frame) + Array(toolbarFrames.values), dragging: drag != nil, cancel: cancelReorder, undoRedo: handleUndoShortcut))
        .onPreferenceChange(TaskListRowFrame.Key.self) { if rowFrames != $0 { rowFrames = $0; updateGhostFrame() } }
        .onPreferenceChange(TaskListGroupFrame.Key.self) { if groupFrames != $0 { groupFrames = $0; updateGhostFrame() } }
        .preference(key: TaskGhostFrameKey.self, value: ghostFrame)
        .onChange(of: listViewport) { _ in updateGhostFrame() }
        .onPreferenceChange(ToolbarFrameKey.self) { toolbarFrames = $0 }
        .onChange(of: toolbarGestureActive) { active in if !active { toolbarDrag = nil } }
        .onPreferenceChange(TaskShelfFrameKey.self) { shelfFrames = $0 }
        .onChange(of: reorderGestureActive) { active in
            traceReorder("swiftui.active-change", fields: ["newActive": "\(active)"])
            if !active {
                DispatchQueue.main.async {
                    if drag?.committing == false { cancelReorder() }
                    dragCancelled = false
                }
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
        .onDisappear { filterPresentation.dismiss(); traceReorder("lifecycle.disappear"); cancelReorder(); reorderRuntime.handleInput = nil; leaveInputs(); selection.update { $0.clear() } }
        .onHover { panelHovered = $0 }
        .foregroundColor(textColor)
        .onAppear { category = state.groupID ?? DotistGroup.inboxID; reorderRuntime.handleInput = handleReorderInput }
        .onChange(of: showCalendar) { _, open in filterPresentation.dateControlsChanged(open) }
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
                TaskContentPresentation(state: state, dragging: drag != nil || model.dragId != nil) {
                    ScrollView {
                        // An eager stack keeps the gesture source alive while auto-scrolling
                        // beyond the viewport. A lazy stack may recycle it mid-drag.
                        VStack(alignment: .leading, spacing: 0) { listSections }
                            .animation(LayoutMotionInputs.shouldReduceMotion(reduceMotion) ? nil : .easeOut(duration: 0.16),
                                       value: TaskContentSelection(state: state))
                            // The viewport owns surplus height. Never propose that
                            // height to sections or their minimum-height row labels.
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 12)
                            .frame(minHeight: max(space.size.height, showsEmptyState ? emptyStateHeight : 0), alignment: .topLeading)
                            .overlay(alignment: .topLeading) {
                                if showsEmptyState {
                                    emptyState(viewportHeight: space.size.height)
                                        .background(GeometryReader { geometry in
                                            Color.clear.preference(key: TaskEmptyStateHeightKey.self, value: geometry.size.height)
                                        })
                                }
                            }
                            // Keep an overflowing empty block scrollable in short
                            // windows without letting it size the section stack.
                            .onPreferenceChange(TaskEmptyStateHeightKey.self) { emptyStateHeight = $0 }
                            .padding(.horizontal, 16)
                            .background(WindowDragArea())
                            .background(TaskReorderScrollBridge(runtime: reorderRuntime))
                    }
                .background(TaskPickupFrameProbe(runtime: reorderRuntime, role: .viewport))
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
    }

    /// One ForEach owns headers and task rows. Moving the invisible gesture
    /// owner through this array preserves its identity even across groups.
    private var listSections: some View {
        ForEach(presentedListEntries) { entry in
            if let row = entry.row {
                CollapsibleTaskSection(expanded: entry.expanded) {
                    interactiveTaskRow(row.task, children: model.children(of: row.task), sub: row.sub,
                        allTasks: row.allTasks, previous: row.previous, next: row.next, hideDue: row.hideDue,
                        titleParts: model.tags(for: row.task), actionsVisible: drag == nil && (hoveredTask == row.task.id || pickingTask == row.task.id),
                        region: row.region, date: row.date)
                        .opacity(row.context ? 0.5 : 1)
                }
            } else if let group = entry.group {
                entry.content
                    .background(groupGeometry(group.id, region: group.region, date: group.date))
                    .background(TaskPickupFrameProbe(runtime: reorderRuntime, role: .group(group.region), group: group))
                    .id(group.id)
            } else { entry.content }
        }
    }

    private var presentedListEntries: [TaskListEntry] {
        let entries = listEntries
        guard let drag, let head = entries.first(where: { $0.row?.task.id == drag.taskID && drag.carries(drag.taskID, region: $0.row?.region ?? "") }),
              let destination = drag.destination else { return entries }
        var rest = reorderRestEntries(entries, session: drag)
        // Slot is an index in the content array without the carried block.
        // Draft/spacing decorations are not part of midpoint counting.
        let index = TaskListEntry.insertionIndex(destination.slot, in: rest)
        rest.insert(head, at: index)
        return rest
    }

    /// Filtered groups exist only while they contain displayed rows. Apply
    /// that same rule to the projected outline before release, so removing an
    /// empty source heading cannot shift the committed destination a second time.
    private func reorderRestEntries(_ entries: [TaskListEntry], session: TaskListDrag) -> [TaskListEntry] {
        var rest = entries.filter { entry in
            guard let row = entry.row else { return true }
            return !session.carries(row.task.id, region: row.region)
        }
        if state.scope != "all" || customDateRange != nil {
            let regions = Set(rest.compactMap { $0.row?.region })
            rest.removeAll { entry in
                guard let group = entry.group else { return false }
                return !regions.contains(group.region) && group.region != session.destination?.region
            }
        }
        return rest
    }

    private var listEntries: [TaskListEntry] {
        var entries: [TaskListEntry] = []
        func extra(_ id: String, _ view: some View) {
            entries.append(.init(id: id, content: AnyView(view)))
        }
        func header(_ group: DotistGroup, region: String, date: String? = nil, empty: Bool, after: DotistTask?, inset: CGFloat = 0, visible: Bool = true) {
            entries.append(.init(id: "header:" + region,
                group: .init(id: group.id, region: region, frame: .zero, date: date),
                content: AnyView(Group {
                    if visible { groupHeader(group, empty: empty, after: after, region: region).padding(.top, inset) }
                    else { Color.clear.frame(height: inset) }
                })))
        }
        func row(_ task: DotistTask, region: String, date: String? = nil, flat: Bool = false, context: Bool = false, previous: String?, next: String?) {
            entries.append(.init(id: "row:" + region + ":" + task.id,
                expanded: state.showsGroupContents(task.category, hasHeader: task.category != DotistGroup.inboxID),
                row: .init(task: task, frame: .zero, sub: model.depth(of: task) > 0, allTasks: flat, hideDue: date != nil,
                    region: region, date: date, depth: model.depth(of: task), context: context, previous: previous, next: next)))
            extra("draft:" + region + ":" + task.id, draftRow(after: task, sub: model.depth(of: task) > 0))
        }
        func tree(_ task: DotistTask, region: String, result: TaskFilterResult, previous: String?, next: String?) {
            row(task, region: region, context: result.contextIDs.contains(task.id), previous: previous, next: next)
            // "Only open" also hides completed subtasks of an open parent.
            let children = model.visibleChildren(of: task).filter { child in
                panelTasks.contains { $0.id == child.id } && !(hideCompleted && child.completed)
            }
            for (index, child) in children.enumerated() {
                tree(child, region: region, result: result, previous: index > 0 ? children[index - 1].id : nil,
                     next: index + 1 < children.count ? children[index + 1].id : nil)
            }
        }
        func flat(_ result: TaskFilterResult, section: String, date: String? = nil) {
            for id in dropGroupIDs.filter({ state.groupID == nil || $0 == state.groupID }) {
                let items = result.tasks.filter { $0.category == id }
                guard !items.isEmpty, let group = model.groups.first(where: { $0.id == id }) else { continue }
                let region = section + ":" + id
                let ids = Set(items.map(\.id))
                let heads = items.filter { $0.parentId == nil || !ids.contains($0.parentId!) }
                let children = Dictionary(grouping: items.filter { $0.parentId != nil }, by: { $0.parentId! })
                func outline(_ task: DotistTask) -> [DotistTask] { [task] + (children[task.id] ?? []).flatMap(outline) }
                let ordered = heads.flatMap(outline)
                header(group, region: region, date: date, empty: false, after: heads.last, visible: id != DotistGroup.inboxID)
                for (index, task) in ordered.enumerated() {
                        row(task, region: region, date: date, flat: true, context: result.contextIDs.contains(task.id),
                            previous: index > 0 ? ordered[index - 1].id : nil, next: index + 1 < ordered.count ? ordered[index + 1].id : nil)
                }
            }
        }
        func section(_ title: String, result: TaskFilterResult, key: String, date: String? = nil, gap: CGFloat = 0) {
            extra("section:" + key, HStack(alignment: .opticalCenter, spacing: 6) {
                OpticalText(title: model.text(title), size: 15, weight: .semibold, language: model.language)
                    .foregroundColor(title == "已逾期" ? DotistDesign.danger : DotistDesign.ink)
            }.frame(height: 30).padding(.top, 4 + gap).accessibilityIdentifier("section-heading:\(title)")
                .preference(key: TaskSectionHeadingKey.self, value: [title]))
            flat(result, section: key, date: date)
        }
        func disclosure(_ title: String, result: TaskFilterResult, upcoming: Bool, gap: CGFloat) {
            let key = upcoming ? "upcoming" : "completed"
            extra("disclosure:" + key, Button {
                withAnimation(reorderAnimation()) { if upcoming { upcomingOpen.toggle() } else { todayDoneOpen.toggle() } }
            } label: {
                DisclosureRow(title: model.text(title), expanded: upcoming ? upcomingOpen : todayDoneOpen, language: model.language)
            }.buttonStyle(.plain).modifier(DotistFocusRing()).padding(.top, gap))
            if upcoming ? upcomingOpen : todayDoneOpen { flat(result, section: key) }
        }
        if state.scope == "all" && customDateRange == nil {
            guard !showsEmptyState else { return [] }
            let groups = model.groups.filter { dropGroupIDs.contains($0.id) && (state.groupID == nil || state.groupID == $0.id) }
                .sorted { dropGroupIDs.firstIndex(of: $0.id)! < dropGroupIDs.firstIndex(of: $1.id)! }
            var first = true
            for group in groups {
                let open = model.filteredTasks(scope: "all", groupID: group.id, tag: state.activeTag)
                let done = model.filteredTasks(scope: "done", groupID: group.id, tag: state.activeTag)
                let openIDs = Set(open.roots.map(\.id))
                let completed = done.roots.filter { !openIDs.contains($0.id) }
                let roots = model.ordered(panelTasks.filter { $0.category == group.id && $0.parentId == nil })
                let visible = group.id != DotistGroup.inboxID
                header(group, region: group.id, empty: roots.isEmpty, after: open.roots.last,
                       inset: first ? 6 : 8, visible: visible)
                if visible || !roots.isEmpty { first = false }
                for result in [open, done] {
                    let roots = result.roots.filter { result.roots == open.roots || (!hideCompleted && completed.contains($0)) }
                    for (index, task) in roots.enumerated() {
                        tree(task, region: group.id, result: result, previous: index > 0 ? roots[index - 1].id : nil,
                             next: index + 1 < roots.count ? roots[index + 1].id : nil)
                    }
                }
                if state.showsGroupContents(group.id, hasHeader: visible), addingToGroup == group.id {
                    extra("group-draft:" + group.id, groupDraft(group))
                }
            }
        } else if state.scope == "today" && customStart == nil {
            let values = model.todayTaskSections(groupID: state.groupID, tag: state.activeTag)
            var hasSection = false
            if !values.overdue.matches.isEmpty { section("已逾期", result: values.overdue, key: "overdue"); hasSection = true }
            if !values.today.matches.isEmpty {
                if hasSection { extra("today-gap", Color.clear.frame(height: 20)) }
                flat(values.today, section: "today", date: Date().dotistDay); hasSection = true
            }
            if !values.upcoming.matches.isEmpty { disclosure("接下来 {n} 天".replacingOccurrences(of: "{n}", with: "7"), result: values.upcoming, upcoming: true, gap: hasSection ? 20 : 0); hasSection = true }
            if !values.completed.matches.isEmpty { disclosure("已完成", result: values.completed, upcoming: false, gap: hasSection ? 20 : 0) }
        } else {
            let result = dateFilterResult()
            if customDateRange == nil && state.scope == "overdue" {
                if !result.matches.isEmpty { section("已逾期", result: result, key: "overdue") }
            } else if customDateRange == nil && state.scope == "undated" { flat(result, section: "undated") }
            else if customDateRange == nil && state.scope == "done" {
                if !result.matches.isEmpty { section("已完成", result: result, key: "done") }
            } else {
                let dates = Array(Set(result.matches.compactMap(\.dueDate))).sorted()
                for (index, date) in dates.enumerated() {
                    section(model.dueLabel(date), result: dateFilterResult(range: TaskDateRange(date, date)), key: date, date: date, gap: index > 0 ? 20 : 0)
                }
                let done = dateFilterResult(completed: true)
                if !done.matches.isEmpty { disclosure("已完成", result: done, upcoming: false, gap: dates.isEmpty ? 0 : 20) }
            }
        }
        return entries
    }

    private func groupDraft(_ group: DotistGroup) -> some View {
        TaskRowLayout(depth: 0) {
            TaskCheckmark(depth: 0, completed: false, children: [], emphasized: false)
            TaskEditor(text: Binding(get: { groupTitles[group.id] ?? "" }, set: { groupTitles[group.id] = $0 }), height: $draftHeight,
                font: DotistDesign.nativeFont(13, language: model.language), label: model.text("新任务（{name}）").replacingOccurrences(of: "{name}", with: group.name),
                commit: { saveGroupDraft(group, continuing: true) }, cancel: { clearInputs() }, indent: { _ in }, blur: { saveGroupDraft(group, continuing: false) })
                .id("group:\(group.id)").frame(height: draftHeight)
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private var emptyStateContext: TaskEmptyState {
        TaskEmptyState(scope: state.scope, groupID: state.groupID, customRange: customDateRange)
    }

    private var showsEmptyState: Bool {
        if customDateRange == nil && state.scope == "all" { return panelTasks.isEmpty }
        if customDateRange == nil && state.scope == "today" {
            let sections = model.todayTaskSections(groupID: state.groupID, tag: state.activeTag)
            return sections.today.matches.isEmpty && sections.overdue.matches.isEmpty
                && !(upcomingOpen && !sections.upcoming.matches.isEmpty)
                && !(todayDoneOpen && !sections.completed.matches.isEmpty)
        }
        let result = dateFilterResult()
        guard result.matches.isEmpty else { return false }
        let showsCompletedRows = todayDoneOpen && !dateFilterResult(completed: true).matches.isEmpty
            && (customDateRange != nil || !["all", "overdue", "undated", "done"].contains(state.scope))
        return !showsCompletedRows
    }

    // Folded auxiliary sections retain their original position. The empty-state
    // block stays below their hit boxes, even in a short resized window.
    private var emptyStateMinimumTop: CGFloat {
        if customDateRange == nil && state.scope == "today" {
            let sections = model.todayTaskSections(groupID: state.groupID, tag: state.activeTag)
            let count = (sections.upcoming.matches.isEmpty ? 0 : 1) + (sections.completed.matches.isEmpty ? 0 : 1)
            return count == 0 ? 0 : CGFloat(count * 28 + (count - 1) * 20 + 16)
        }
        if (customDateRange != nil || !["all", "overdue", "undated", "done"].contains(state.scope)),
           !dateFilterResult(completed: true).matches.isEmpty { return 44 }
        return 0
    }

    private func emptyState(viewportHeight: CGFloat) -> some View {
        let context = emptyStateContext
        return TaskEmptyStateLayout(viewportHeight: viewportHeight, minimumTop: emptyStateMinimumTop) {
            TaskEmptyStateContent(title: model.text(context.title), hint: context.hint.map { model.text($0) }, language: model.language) {
                if context.allowsAdding {
                    Button { focusEmptyStateComposer(context) } label: {
                        TaskEmptyAddLabel()
                            .background(RoundedRectangle(cornerRadius: 6).fill(DotistDesign.rule.opacity(emptyAddHovered ? 0.10 : 0)))
                    }.buttonStyle(.plain).modifier(DotistFocusRing())
                        .onHover { emptyAddHovered = $0 }
                        .accessibilityLabel(Text(model.text(TaskEmptyState.addAccessibilityLabel)))
                        .accessibilityIdentifier("empty-state-add")
                }
            }
        }.accessibilityElement(children: .contain)
    }

    private func focusEmptyStateComposer(_ context: TaskEmptyState) {
        clearInputs()
        selection.update { $0.clear() }
        category = context.groupID
        dueDate = context.dueDate.flatMap { Date.dotistDay($0) }
        composerFocused = true
        let generation = UUID()
        composerCueGeneration = generation
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { composerCueVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard composerCueGeneration == generation else { return }
            if reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                composerCueVisible = false
            } else {
                withAnimation(.easeOut(duration: 0.2)) { composerCueVisible = false }
            }
        }
    }

    private func dismissComposerCue() {
        composerCueGeneration = UUID()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { composerCueVisible = false }
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

    private func rowGeometry(_ task: DotistTask, sub: Bool, allTasks: Bool, hideDue: Bool, region: String, date: String?) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: TaskListRowFrame.Key.self, value: [TaskListRowFrame(
                task: task, frame: geometry.frame(in: .named(Self.listSpace)), sub: sub, allTasks: allTasks, hideDue: hideDue, region: region, date: date, depth: model.depth(of: task)
            )])
        }
    }

    private func groupGeometry(_ id: String, region: String, date: String? = nil) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: TaskListGroupFrame.Key.self, value: [TaskListGroupFrame(
                id: id, region: region, frame: geometry.frame(in: .named(Self.listSpace)), date: date
            )])
        }
    }

    private var showsInsertionGhost: Bool { drag?.destination != nil }

    private func updateGhostFrame() {
        guard let drag, let row = rowFrames.first(where: { $0.task.id == drag.taskID && drag.carries($0.task.id, region: $0.region) }) else { return }
        ghostFrame = row.frame
    }

    private func reorderAnimation(_ duration: Double = 0.16) -> Animation? {
        LayoutMotionInputs.shouldReduceMotion(reduceMotion) ? nil : .snappy(duration: duration)
    }

    @ViewBuilder private var ghostConnector: some View {
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

    private func traceReorder(_ event: String, taskID: String? = nil, point: CGPoint? = nil, fields: [String: String] = [:]) {
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

    private func reorderGesture(_ task: DotistTask) -> some Gesture {
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

    // Native gestures and other input adapters share the same mounted state.
    private func handleReorderInput(_ input: TaskReorderRuntime.Input) {
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

    private func cancelReorder() {
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
                headerControl(item)
                    .opacity(toolbarConfig.visibility(of: item) == .always || panelHovered || toolbarDrag != nil || isActive(item) ? 1 : 0)
                    .allowsHitTesting(toolbarConfig.visibility(of: item) == .always || panelHovered || isActive(item))
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

    /// A control whose state differs from the default stays visible even when hover-only.
    private func isActive(_ item: ToolbarItem) -> Bool {
        switch item {
        // Filter and calendar state is named by the line under the header, so their
        // visibility follows the user setting; only an open popover or the completion toggle pins.
        case .filter: filterPresentation.isOpen
        case .completion: hideCompleted
        case .calendar: showCalendar
        default: false
        }
    }

    @ViewBuilder private func headerControl(_ item: ToolbarItem) -> some View {
        switch item {
        case .filter: filterButton.background(frameReporter(item))
        case .completion: completionToggle.background(frameReporter(item))
        case .calendar: calendarButton.background(frameReporter(item))
        default: toolbarItem(item)
        }
    }

    private func frameReporter(_ item: ToolbarItem) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ToolbarFrameKey.self, value: [item: geometry.frame(in: .named(Self.listSpace))])
        }
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
        case .filter, .completion, .calendar: ""
        case .views: "rectangle.split.2x1"
        case .pin: model.settings.alwaysOnTop ? "pin.fill" : "pin"
        case .lock: model.settings.locked ? "lock.fill" : "lock.open"
        case .color: "circle"
        case .collapse: "arrow.down.right.and.arrow.up.left"
        }
        let labelKey: String = switch item {
        case .filter, .completion, .calendar: ""
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
            case .filter, .completion, .calendar: break
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

    /// The toolbar names the scope; clicking opens a timed, in-flow filter row.
    private var currentScopeLabel: String {
        if let start = customStart {
            let end = customEnd ?? start
            return start == end ? model.dueLabel(start) : model.dueLabel(start) + " – " + model.dueLabel(end)
        }
        return model.text(filterLabel(state.scope))
    }

    private var dateFilterActive: Bool { state.dateFilterActive }

    private var filterButton: some View {
        Button { filterPresentation.toggle() } label: {
            OpticalSymbol(name: "line.3.horizontal.decrease", size: 14).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(DotistFocusRing())
            .foregroundColor(dateFilterActive || filterPresentation.isOpen ? DotistDesign.accent : DotistDesign.muted)
            .animation(DateFilterSelectionMotion.animation(reduceMotion: reduceMotion), value: dateFilterActive || filterPresentation.isOpen)
            .help(model.text("日期筛选")).accessibilityLabel(Text(model.text("日期筛选")))
            .accessibilityValue(Text(currentScopeLabel))
            .accessibilityIdentifier("date-filter-current")
    }

    /// Reserve the summary's 22pt even for All. Selection must not insert a
    /// second, instantaneous push below the independently animated filter strip.
    private var activeFilterLine: some View {
        let summary = state.filterSummary(in: model)
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(summary ?? "").font(DotistDesign.textFont(12, language: model.language))
                .foregroundStyle(DotistDesign.faint).lineLimit(1)
                .contentTransition(.opacity)
        }.padding(.horizontal, 16).frame(height: 22)
            .accessibilityHidden(summary == nil)
            .accessibilityIdentifier("active-filter-line")
            .animation(DateFilterSelectionMotion.animation(reduceMotion: reduceMotion), value: summary)
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(model.settings.filters, id: \.self) { id in
                    DraggableFilterButton(title: model.text(filterLabel(id)), selected: customStart == nil && state.scope == id, language: model.language,
                                          distance: TaskDateFilterMetrics.distance(of: id, selected: customStart == nil ? state.scope : nil, in: model.settings.filters)) {
                        state.scope = id; customStart = nil; customEnd = nil
                        filterPresentation.selected()
                    }.accessibilityIdentifier("date-filter:\(id)")
                }
            }.padding(.horizontal, DateFilterEdgeMask.contentInset)
        }.frame(height: TaskDateFilterMetrics.rowHeight)
            .mask { DateFilterEdgeMask() }
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .background(DateFilterHoverObserver(enabled: filterPresentation.isOpen, changed: filterPresentation.hoverChanged))
            .padding(.horizontal, TaskRowMetrics.inset)
            .allowsHitTesting(filterPresentation.isOpen)
    }

    private var completionToggle: some View {
        let label = model.text(hideCompleted ? "显示已完成任务" : "只看未完成")
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { hideCompleted.toggle() }
        } label: {
            OpticalSymbol(name: hideCompleted ? "checkmark.circle.badge.xmark" : "checkmark.circle", size: 14).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(DotistFocusRing())
            .foregroundColor(hideCompleted ? DotistDesign.accent : DotistDesign.muted)
            .opacity(hideCompleted || panelHovered ? 1 : 0)
            .allowsHitTesting(hideCompleted || panelHovered)
            .help(label).accessibilityLabel(Text(label))
            .accessibilityValue(Text(model.text(hideCompleted ? "已隐藏已完成" : "显示全部")))
            .accessibilityIdentifier("completion-filter")
            .animation(toolbarAnimation, value: panelHovered)
    }

    private var calendarButton: some View {
        Button { showCalendar.toggle() } label: { OpticalSymbol(name: "calendar", size: 14).frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).modifier(DotistFocusRing())
            .foregroundColor(customStart == nil ? DotistDesign.muted : DotistDesign.accent)
            .help(model.text("日历")).accessibilityLabel(Text(model.text("日历")))
            .popover(isPresented: $showCalendar) {
                RangeCalendar(model: model, start: customStart ?? Date().dotistDay, end: customEnd ?? Date().dotistDay, choose: { start, end in
                    state.scope = "today"
                    customStart = start
                    customEnd = end
                }, close: { showCalendar = false })
            }
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
            .frame(height: 32)
            .onHover { over in if over { hoveredGroup = hoverID } else if hoveredGroup == hoverID { hoveredGroup = nil } }
            .contextMenu {
                Button(model.text("添加任务")) { beginGroupDraft(group, after: task) }
                Button(model.text("在独立面板中打开")) { showGroupPanel(group.id) }
                Menu(model.text("颜色")) { groupColorMenu(group.id) }
            }
    }

    private var customDateRange: TaskDateRange? {
        customStart.map { TaskDateRange($0, customEnd ?? $0) }
    }

    private var rangeBounds: (String, String) {
        let range = customDateRange ?? model.dateFilterRange(scope: state.scope)
        return (range.start, range.end)
    }

    private func dateFilterResult(completed: Bool = false, range: TaskDateRange? = nil) -> TaskFilterResult {
        model.filteredTasks(scope: state.scope, groupID: state.groupID, tag: state.activeTag,
                            customRange: range ?? customDateRange, completed: completed)
    }

    private func interactiveTaskRow(_ task: DotistTask, children: [DotistTask], sub: Bool, allTasks: Bool, previous: String?, next: String?, hideDue: Bool, titleParts: DotistTaskTags?, actionsVisible: Bool, region: String, date: String?) -> some View {
        let carried = drag?.carries(task.id, region: region) == true
        return TaskSelectableContent(selection: selection.row(task.id)) { selected, focused in
            rowContent(task, children: children, sub: sub, allTasks: allTasks, previous: previous, hideDue: hideDue, titleParts: titleParts, actionsVisible: (actionsVisible || focused) && drag == nil && model.dragId == nil, selected: selected, focused: focused)
                .background {
                    let background = TaskRowBackgroundState(hovered: hoveredTask == task.id, selected: selected, editing: editing == task.id, dragging: drag != nil || model.dragId != nil, carried: carried)
                    RoundedRectangle(cornerRadius: 6).fill(DotistDesign.rule.opacity(background.opacity)).padding(.horizontal, -6)
                        .allowsHitTesting(false)
                        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || drag != nil || model.dragId != nil ? nil : .easeInOut(duration: 0.1), value: background)
                }
        }
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
        // The mounted mouse-down owner is the single one-line placeholder.
        .opacity(carried ? 0 : 1)
        .frame(height: carried ? 32 : nil, alignment: .top).clipped()
        .overlay {
            if carried {
                RoundedRectangle(cornerRadius: 6).fill(DotistDesign.rule.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DotistDesign.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .padding(.leading, CGFloat(drag?.target?.level ?? 0) * TaskRowMetrics.indent)
                    .allowsHitTesting(false)
            }
        }
        .background(TaskPickupFrameProbe(runtime: reorderRuntime, role: .row(.before(task.id, region: region)),
            row: .init(task: task, frame: .zero, sub: sub, allTasks: allTasks, hideDue: hideDue, region: region, date: date, depth: model.depth(of: task))))
        .background(rowGeometry(task, sub: sub, allTasks: allTasks, hideDue: hideDue, region: region, date: date))
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

    private func rowContent(_ task: DotistTask, children: [DotistTask], sub: Bool, allTasks: Bool, previous: String?, hideDue: Bool, titleParts: DotistTaskTags?, actionsVisible: Bool, selected: Bool = false, focused: Bool = false, depthOverride: Int? = nil) -> some View {
        let depth = depthOverride ?? model.depth(of: task)
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
                        .strikethrough(task.completed, color: DotistDesign.faint)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: task.completed)
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
                    .fixedSize(horizontal: false, vertical: true)
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
        traceReorder("row.click", taskID: task.id, fields: ["edit": "\(edit)"])
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
        let selectedName = model.composerGroupDisplayName(selectedID)
        let shownDue = dueDate?.dotistDay
        return ComposerLayout {
            Menu {
                Picker(model.text("分组"), selection: $category) {
                    ForEach(dropGroupIDs, id: \.self) { id in
                        Text(model.composerGroupDisplayName(id)).font(font(13, serif: true)).tag(id)
                    }
                }.pickerStyle(.inline)
                Divider()
                Button(model.text("管理分组…")) { manageGroups = true }
            } label: {
                HStack(spacing: 4) {
                    ComposerGroupLabel(title: selectedName, language: model.language, sample: composer.isEmpty ? model.text("写下一件小事") : composer.components(separatedBy: .newlines).first ?? "")
                }.foregroundColor(DotistDesign.muted).frame(height: ComposerMetrics.rowHeight)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).focusEffectDisabled().fixedSize().frame(height: ComposerMetrics.rowHeight).help(model.text("分组")).accessibilityLabel(Text(model.text("分组"))).accessibilityValue(Text(selectedName)).accessibilityIdentifier("composer-group")
            ZStack(alignment: .leading) {
                ComposerInput(text: $composer, focused: $composerFocused, placeholder: model.text("写下一件小事"), label: model.text("新任务"), font: DotistDesign.nativeFont(ComposerMetrics.fontSize, language: model.language), commit: addTask, navigate: { direction in
                    let values = tagSuggestions
                    guard !values.isEmpty else { return false }
                    selectedSuggestion = (selectedSuggestion + direction + values.count) % values.count
                    return true
                }, complete: { force in chooseSuggestion(force: force) }).tint(DotistDesign.accent).frame(height: ComposerMetrics.rowHeight)
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DotistDesign.accent.opacity(composerCueVisible ? 0.5 : 0), lineWidth: 1).allowsHitTesting(false) }
                    .accessibilityIdentifier("composer-input")
                if !tagSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tagSuggestions.enumerated()), id: \.element) { index, tag in
                            Button("#" + tag) { selectedSuggestion = index; _ = chooseSuggestion(force: true) }
                                .buttonStyle(.plain).modifier(DotistFocusRing()).font(font(12, index == selectedSuggestion ? .medium : .regular)).foregroundColor(index == selectedSuggestion ? DotistDesign.ink : DotistDesign.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 28)
                        }
                    }.glassEffect(.regular, in: .rect(cornerRadius: 12)).offset(y: -CGFloat(tagSuggestions.count * 28 + 6)).zIndex(1)
                }
            }.frame(maxWidth: .infinity).frame(height: ComposerMetrics.rowHeight)
                .onChange(of: composer) { _ in selectedSuggestion = -1; dismissComposerCue() }
                .onChange(of: composerFocused) { focused in if !focused { dismissComposerCue() } }
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
            #if DEBUG
            .background(ComposerBarLayoutAnchor().allowsHitTesting(false).accessibilityHidden(true))
            #endif
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

struct TaskEmptyAddLabel: View {
    var body: some View {
        OpticalSymbol(name: "plus", size: 16)
            .foregroundStyle(DotistDesign.faint)
            .frame(width: 32, height: 32).contentShape(Rectangle())
    }
}

private struct TaskEmptyStateHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Shared presentation keeps translated text constrained to the list width.
struct TaskEmptyStateContent<AddRow: View>: View {
    let title: String
    let hint: String?
    let language: String
    @ViewBuilder var addRow: () -> AddRow
    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                OpticalText(title: title, size: 15, weight: .medium, language: language)
                    .foregroundStyle(DotistDesign.ink).lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("empty-state-title")
                if let hint {
                    OpticalText(title: hint, size: 12, language: language)
                        .foregroundStyle(DotistDesign.faint).lineLimit(1).truncationMode(.tail)
                        .accessibilityIdentifier("empty-state-hint")
                }
            }.frame(maxWidth: .infinity)
            addRow()
        }
    }
}

struct DraggableFilterButton: View {
    let title: String
    let selected: Bool
    let language: String
    var distance: Int = 0
    let choose: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovering = false
    @State private var origin: (mouse: NSPoint, window: NSPoint)?
    @StateObject private var motion: DateFilterSelectionMotion

    init(title: String, selected: Bool, language: String, distance: Int = 0, choose: @escaping () -> Void) {
        self.title = title; self.selected = selected; self.language = language
        self.distance = distance; self.choose = choose
        _motion = StateObject(wrappedValue: DateFilterSelectionMotion(selected: selected))
    }

    var body: some View {
        Button { if origin == nil { choose() } } label: {
            DateFilterInkLabel(title: title, language: language, fraction: motion.fraction,
                               regularColor: focused ? DotistDesign.accent : hovering ? DotistDesign.muted : DotistDesign.faint,
                               selectedColor: focused ? DotistDesign.accent : DotistDesign.ink,
                               regularOpacity: TaskDateFilterMetrics.opacity(distance: distance, hovered: hovering, focused: focused,
                                                                            increasedContrast: contrast == .increased, voiceOver: voiceOver),
                               feedbackAnimation: DateFilterSelectionMotion.animation(reduceMotion: reduceMotion))
                .frame(width: TaskDateFilterMetrics.slotWidth(title: title, language: language), height: TaskDateFilterMetrics.rowHeight)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focused).focusEffectDisabled().onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .onAppear { motion.setSelected(selected, reduceMotion: true) }
            .onChange(of: selected) { _, value in motion.setSelected(value, reduceMotion: reduceMotion) }
            .onChange(of: reduceMotion) { _, _ in motion.setSelected(selected, reduceMotion: reduceMotion) }
            .onDisappear { motion.stop() }
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

/// The title and disclosure glyph share the complete title's native ink axis.
struct GroupCollapseHeader: View {
    let title: String
    let language: String
    let collapsed: Bool
    let hovered: Bool
    var empty = false
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motion: DisclosureMotion
    init(title: String, language: String, collapsed: Bool, hovered: Bool, empty: Bool = false, toggle: @escaping () -> Void) {
        self.title = title; self.language = language; self.collapsed = collapsed
        self.hovered = hovered; self.empty = empty; self.toggle = toggle
        _motion = StateObject(wrappedValue: DisclosureMotion(expanded: !collapsed))
    }
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                GroupHeaderInkLabel(title: title, language: language, collapsed: collapsed,
                                    showsChevron: collapsed || hovered || motion.fraction < 1, empty: empty, disclosureProgress: motion.fraction)
                Spacer(minLength: 26)
            }.frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(GroupHeaderButtonStyle()).modifier(DotistFocusRing()).accessibilityLabel(Text(title))
            .onAppear { motion.setExpanded(!collapsed, reduceMotion: true) }
            .onChange(of: collapsed) { value in motion.setExpanded(!value, reduceMotion: LayoutMotionInputs.shouldReduceMotion(reduceMotion)) }
            .onChange(of: reduceMotion) { value in if value { motion.setExpanded(!collapsed, reduceMotion: true) } }
            .onDisappear { motion.stop() }
    }
}

/// Disclosure motion changes only the arrow. PlainButtonStyle applies a
/// transient pressed opacity to the complete label, including rasterized text.
private struct GroupHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
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


#if DEBUG
/// A transparent layout anchor lets panel fixtures read the actual bar box;
/// AX encloses accessible content rather than this bar's complete padding.
struct ComposerBarLayoutAnchor: NSViewRepresentable {
    final class Box: NSView {
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Box { Box() }
    func updateNSView(_ view: Box, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Box, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
#endif
