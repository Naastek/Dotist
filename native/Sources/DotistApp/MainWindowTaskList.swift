import AppKit
import Combine
import DotistCore
import SwiftUI

extension MainWindow {
    #if DEBUG
    static var taskListRenders = 0
    #endif

    var taskList: some View {
        if QAPerf.enabled { QAPerf.count(.taskListBody) }
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
                    proxy.scrollTo("row:" + (model.tasks.first(where: { $0.id == id })?.category ?? "") + ":" + id, anchor: .center)
                }
                .onAppear {
                    if let id = model.focusId, let task = model.tasks.first(where: { $0.id == id }) { proxy.scrollTo("row:" + task.category + ":" + id, anchor: .center) }
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
    func reorderRestEntries(_ entries: [TaskListEntry], session: TaskListDrag) -> [TaskListEntry] {
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

    var listEntries: [TaskListEntry] {
        if QAPerf.enabled { QAPerf.count(.taskListEntries) }
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
                            .opacity(composerFocused || composerFlight ? 0 : 1)
                            .animation(LayoutMotionInputs.shouldReduceMotion(reduceMotion) ? nil : .easeOut(duration: composerFocused ? 0.12 : 0.15), value: composerFocused || composerFlight)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: ComposerFrameKey.self, value: ["plus": geometry.frame(in: .named(Self.listSpace))])
                            })
                            .background(RoundedRectangle(cornerRadius: 6).fill(DotistDesign.rule.opacity(emptyAddHovered && !composerFocused && !composerFlight ? 0.10 : 0)))
                    }.buttonStyle(.plain).modifier(DotistFocusRing())
                        .allowsHitTesting(!composerFocused && !composerFlight)
                        .accessibilityHidden(composerFocused || composerFlight)
                        .onHover { emptyAddHovered = $0 }
                        .accessibilityLabel(Text(model.text(TaskEmptyState.addAccessibilityLabel)))
                        .accessibilityIdentifier("empty-state-add")
                }
            }
        }.accessibilityElement(children: .contain)
            .onDisappear { dismissComposerCue() }
    }

    private func focusEmptyStateComposer(_ context: TaskEmptyState) {
        clearInputs()
        selection.update { $0.clear() }
        category = context.groupID
        dueDate = context.dueDate.flatMap { Date.dotistDay($0) }
        let canTravel = !LayoutMotionInputs.shouldReduceMotion(reduceMotion) && composerFrames["plus"] != nil && composerFrames["input"] != nil && !composerFlight && !composerFocused
        if canTravel {
            composerFlightGeneration = UUID()
            let generation = composerFlightGeneration
            composerFlight = true
            composerFlightAtField = false
            composerFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
                guard composerFlightGeneration == generation else { return }
                withAnimation(.easeOut(duration: composerTravelDuration)) { composerFlightAtField = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + composerTravelDuration) {
                    guard composerFlightGeneration == generation else { return }
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { composerFlight = false }
                }
            }
        } else { composerFocused = true }
    }

    func activateEmptyStateComposer() {
        if showsEmptyState && emptyStateContext.allowsAdding { focusEmptyStateComposer(emptyStateContext) }
        else { composerFocused = true }
    }

    var composerTravelDuration: Double {
        guard Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa",
              let value = ProcessInfo.processInfo.environment["DOTIST_QA_SLOW"],
              let factor = Double(value), factor.isFinite, factor > 0 else { return 0.32 }
        return 0.32 * factor
    }

    func dismissComposerCue() {
        composerFlightGeneration = UUID()
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { composerFlight = false }
    }

    @ViewBuilder private var listMenu: some View {
        Button(model.text("新建分组…")) { manageGroups = true }
        Button(model.text("管理分组…")) { manageGroups = true }
        Button(model.text("管理标签…")) { manageTags = true }
        Button(model.text("任务视图"), action: showViews)
        Button(model.text("收起为悬浮球"), action: collapse)
    }

    var composerArea: some View {
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

}

private struct TaskEmptyStateHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
