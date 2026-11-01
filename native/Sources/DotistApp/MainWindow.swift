import AppKit
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
    @State private var hint = ""
    @State private var draggedToolbarItem: ToolbarItem?
    @State private var dropAsChild = false
    @State private var shelfTarget: String?
    @State private var composer = ""
    @State private var composerSubmitting = false
    @State private var selectedSuggestion = -1
    @State private var category = DotistGroup.inboxID
    @State private var dueDate: Date?
    @State private var addingChild: String?
    @State private var addingToGroup: String?
    @State private var groupTitles: [String: String] = [:]
    @State private var childTitles: [String: String] = [:]
    @State private var groupSubmitting = false
    @State private var childSubmitting = false
    @State private var groupIndented: Set<String> = []
    @State private var editing: String?
    @State private var editedTitle = ""
    @State private var editSaving = false
    @State private var editHeight: CGFloat = 20
    @State private var pendingEdit: DotistTask?
    @State private var dropTarget: String?
    @State private var dropAfter = false
    @State private var manageGroups = false
    @State private var manageTags = false
    @State private var showCalendar = false
    @State private var showDuePicker = false
    @State private var pickingTask: String?
    @State private var hoveredTask: String?
    @State private var hoveredGroup: String?
    @FocusState private var focusedTask: String?
    @State private var customStart: String?
    @State private var customEnd: String?
    @State private var upcomingOpen = false
    @State private var todayDoneOpen = false
    @State private var rowHeights: [String: CGFloat] = [:]

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
                ScrollViewReader { proxy in
                    GeometryReader { space in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if state.scope == "all" { allGroups }
                            else if state.scope == "today" && customStart == nil { todayList }
                            else { filteredTasks }
                        }.padding(.horizontal, 16).padding(.bottom, 12)
                            .frame(minHeight: space.size.height, alignment: .topLeading).background(WindowDragArea())
                    }.contextMenu {
                        Button(model.text("新建分组…")) { manageGroups = true }
                        Button(model.text("管理分组…")) { manageGroups = true }
                        Button(model.text("管理标签…")) { manageTags = true }
                        Button(model.text("任务视图"), action: showViews)
                        Button(model.text("收起为悬浮球"), action: collapse)
                    }.onChange(of: model.gotoGroup) { id in
                        guard primary, let id else { return }
                        state.groupID = id
                        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.22)) { proxy.scrollTo(id, anchor: .top) }
                        model.gotoGroup = nil
                    }
                    .onChange(of: model.focusNavigation) { _ in
                        guard primary, let id = model.focusId else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                    .onAppear {
                        // Management pages unmount the list; consume navigation when it returns.
                        if let id = model.focusId { proxy.scrollTo(id, anchor: .center) }
                        else if let id = model.gotoGroup { proxy.scrollTo(id, anchor: .top) }
                        model.gotoGroup = nil
                    }
                    }
                }
            }
            if !manageGroups && !manageTags {
                GlassEffectContainer(spacing: 12) {
                    Group {
                        if model.dragId != nil { groupShelf } else { composerBar }
                    }.overlay(alignment: .top) {
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
                }
                Text(hint.isEmpty ? " " : hint).font(font(12)).foregroundColor(DotistDesign.faint)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 22)
                    .accessibilityHidden(true)
            }
        }
        .onHover { panelHovered = $0 }
        .foregroundColor(textColor)
        .onAppear { category = state.groupID ?? DotistGroup.inboxID }
        .onChange(of: state.groupID) { id in
            category = id ?? DotistGroup.inboxID
            if addingToGroup != id { addingToGroup = nil }
            addingChild = nil
            if let id = editing, let task = model.tasks.first(where: { $0.id == id }) { saveEditing(task) }
        }
        .onChange(of: model.groups) { groups in
            if let id = state.groupID, !groups.contains(where: { $0.id == id }) { state.groupID = DotistGroup.inboxID }
            if !groups.contains(where: { $0.id == category }) { category = state.groupID ?? DotistGroup.inboxID }
        }
        .onChange(of: model.tagDescription) { _ in
            if let tag = state.activeTag, !model.tagCounts.contains(where: { $0.tag == tag && $0.open > 0 }) { state.activeTag = nil }
        }
        .onChange(of: model.scope) { scope in if primary { state.scope = scope } }
        .onChange(of: state.scope) { scope in if primary { model.scope = scope } }
        .onChange(of: model.scopeNavigation) { _ in
            guard primary else { return }
            state.activeTag = nil
            customStart = nil; customEnd = nil
            manageGroups = false; manageTags = false
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(model.groups.first(where: { $0.id == state.groupID })?.name ?? model.text("全部"))
                .font(font(18, .semibold, serif: true)).lineLimit(1).frame(height: 28)
                .accessibilityIdentifier("group-menu")
                .contextMenu {
                    Button(model.text("全部分组")) { state.groupID = nil }.accessibilityIdentifier("group-menu:all")
                    ForEach(model.groups) { group in
                        Button(group.name) { state.groupID = group.id }.accessibilityIdentifier("group-menu:" + group.id)
                    }
                    Menu(model.text("在独立面板中打开")) {
                        ForEach(model.groups) { group in Button(group.name) { showGroupPanel(group.id) }.accessibilityIdentifier("group-open:" + group.id) }
                    }
                    Button(model.text("管理分组…")) { manageGroups = true }
                }
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
            .buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(DotistDesign.muted).onHover { hint = $0 ? label : "" }.accessibilityLabel(Text(label))
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
            let roots = model.ordered(panelTasks.filter { $0.category == group.id && $0.parentId == nil })
            let open = roots.filter { !$0.completed }
            let completed = roots.filter(\.completed)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.name).font(font(15, .semibold, serif: true)).foregroundColor(roots.isEmpty ? DotistDesign.faint : DotistDesign.ink)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 30).padding(.top, 4)
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 2) {
                            Button { showGroupPanel(group.id) } label: { Image(systemName: "arrow.up.right.square").frame(width: 22, height: 22) }
                                .accessibilityLabel(Text(model.text("独立面板 {name}").replacingOccurrences(of: "{name}", with: group.name)))
                            Button { groupIndented.remove(group.id); addingToGroup = group.id } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                                .accessibilityLabel(Text(model.text("添加任务（{name}）").replacingOccurrences(of: "{name}", with: group.name)))
                        }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(DotistDesign.faint)
                            .opacity(hoveredGroup == group.id || addingToGroup == group.id ? 1 : 0)
                    }
                    .contextMenu {
                        Button(model.text("添加任务")) { groupIndented.remove(group.id); addingToGroup = group.id }
                        Button(model.text("在独立面板中打开")) { showGroupPanel(group.id) }
                    }
                ForEach(Array(open.enumerated()), id: \.element.id) { index, task in taskTree(task, previous: index > 0 ? open[index - 1].id : nil, next: index + 1 < open.count ? open[index + 1].id : nil) }
                if addingToGroup == group.id {
                    QuickInput(text: Binding(get: { groupTitles[group.id] ?? "" }, set: { groupTitles[group.id] = $0 }), placeholder: model.text(groupIndented.contains(group.id) ? "子任务" : "写下一件小事"), label: model.text("新任务（{name}）").replacingOccurrences(of: "{name}", with: group.name), font: DotistDesign.nativeFont(13, language: model.language), commit: {
                        let title = (groupTitles[group.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty, !groupSubmitting else { return }
                        let parent = groupIndented.contains(group.id) ? open.last?.id : nil
                        groupSubmitting = true
                        model.change(completed: {
                            groupSubmitting = false
                            if (groupTitles[group.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == title { groupTitles[group.id] = "" }
                            if let parent { state.expanded.insert(parent) }
                        }, failed: { groupSubmitting = false }) { _ = try $0.addTask(title: title, category: group.id, parentId: parent) }
                    }, cancel: { addingToGroup = nil }, cycle: { step in
                        if step > 0 && !open.isEmpty { groupIndented.insert(group.id) } else { groupIndented.remove(group.id) }
                    }).padding(.leading, groupIndented.contains(group.id) ? 48 : 26).frame(height: groupIndented.contains(group.id) ? 28 : 32)
                }
                if !completed.isEmpty {
                    Button {
                        if state.folded.contains(group.id) { state.folded.remove(group.id) } else { state.folded.insert(group.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: state.folded.contains(group.id) ? "chevron.down" : "chevron.right").frame(width: 18)
                            Text(model.text("已完成"))
                        }.font(font(12)).foregroundColor(DotistDesign.faint).frame(height: 28)
                    }.buttonStyle(.plain).modifier(DotistFocusRing())
                    if state.folded.contains(group.id) { ForEach(Array(completed.enumerated()), id: \.element.id) { index, task in taskTree(task, previous: index > 0 ? completed[index - 1].id : nil, next: index + 1 < completed.count ? completed[index + 1].id : nil) } }
                }
            }.padding(.top, group.id == model.groups.first(where: { state.groupID == nil || $0.id == state.groupID })?.id ? 6 : 20).id(group.id).contentShape(Rectangle())
                .onHover { over in if over { hoveredGroup = group.id } else if hoveredGroup == group.id { hoveredGroup = nil } }
                .onDrop(of: ["public.utf8-plain-text"], delegate: GroupDrop(model: model, group: group.id))
        }
    }

    @ViewBuilder private func taskTree(_ task: DotistTask, previous: String?, next: String?) -> some View {
        let children = model.visibleChildren(of: task)
        taskRow(task, children: children, sub: false, allTasks: false, previous: previous, next: next)
        if state.expanded.contains(task.id) {
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                taskRow(child, children: [], sub: true, allTasks: false, previous: index > 0 ? children[index - 1].id : nil, next: index + 1 < children.count ? children[index + 1].id : nil).padding(.leading, 26)
            }
            if addingChild == task.id {
                QuickInput(text: Binding(get: { childTitles[task.id] ?? "" }, set: { childTitles[task.id] = $0 }), placeholder: model.text("子任务"), label: model.text("新子任务"), font: DotistDesign.nativeFont(13, language: model.language), commit: {
                    let title = (childTitles[task.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, !childSubmitting else { return }
                    childSubmitting = true
                    model.change(completed: { childSubmitting = false; if (childTitles[task.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == title { childTitles[task.id] = "" } }, failed: { childSubmitting = false }) { _ = try $0.addTask(title: title, category: task.category, parentId: task.id) }
                }, cancel: { addingChild = nil }, cycle: { step in
                    guard step < 0 else { return }
                    let title = (childTitles[task.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if title.isEmpty { addingChild = nil; return }
                    guard !childSubmitting else { return }
                    childSubmitting = true
                    model.change(completed: {
                        childSubmitting = false
                        if (childTitles[task.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == title { childTitles[task.id] = "" }
                        addingChild = nil
                    }, failed: { childSubmitting = false }) { _ = try $0.addTask(title: title, category: task.category) }
                }).padding(.leading, 48).frame(height: 28)
            }
        }
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
                        HStack { Image(systemName: todayDoneOpen ? "chevron.down" : "chevron.right").frame(width: 18); Text(model.text("已完成")) }.font(font(12)).foregroundColor(DotistDesign.muted)
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
                    HStack { Image(systemName: todayDoneOpen ? "chevron.down" : "chevron.right").frame(width: 18); Text(model.text("已完成")) }
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
        ForEach(Array(items.enumerated()), id: \.element.id) { index, task in
            taskRow(task, children: [], sub: false, allTasks: true, previous: index > 0 ? items[index - 1].id : nil, next: index + 1 < items.count ? items[index + 1].id : nil, hideDue: hideDue)
        }
    }

    private func taskRow(_ task: DotistTask, children: [DotistTask], sub: Bool, allTasks: Bool, previous: String?, next: String?, hideDue: Bool = false) -> some View {
        let scope = allTasks
            ? (state.scope == "today" && customStart == nil
                ? (task.completed ? "today:done" : task.dueDate.map { $0 < Date().dotistDay ? "today:overdue" : $0 == Date().dotistDay ? "today:today" : "today:upcoming" } ?? "today:undated")
                : state.scope == "overdue" || state.scope == "done" ? "scope:\(state.scope)"
                : state.scope == "undated" ? "undated:\(task.category)"
                : task.completed ? "range:done"
                : "day:\(task.dueDate ?? "undated")")
            : (task.parentId.map { "children:\($0)" } ?? "group:\(task.category):\(task.completed)")
        let titleParts = model.tags(for: task)
        let actionsVisible = hoveredTask == task.id || focusedTask == task.id || pickingTask == task.id
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { model.complete(task) } label: {
                ZStack {
                    if task.completed {
                        Circle().fill(DotistDesign.accent)
                        Image(systemName: "checkmark").font(.system(size: sub ? 7.5 : 9, weight: .heavy)).foregroundColor(DotistDesign.paper)
                    } else {
                        Circle().strokeBorder(focusedTask == task.id ? DotistDesign.accent : DotistDesign.checkStroke, lineWidth: 1.25)
                    }
                }.frame(width: sub ? 13 : 16, height: sub ? 13 : 16).frame(width: sub ? 14 : 18, height: 20, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).focusEffectDisabled().accessibilityLabel(Text(model.text(task.completed ? "恢复 {title}" : "完成 {title}").replacingOccurrences(of: "{title}", with: task.title)))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }

            if editing == task.id {
                VStack(alignment: .leading, spacing: 3) {
                TaskEditor(text: $editedTitle, height: $editHeight, font: DotistDesign.nativeFont(13, language: model.language), label: model.text("任务内容"), commit: {
                    saveEditing(task)
                }, cancel: { editing = nil }, indent: { reverse in
                    if reverse && sub { saveEditing(task) { model.change { _ = try $0.reparent(task.id, parentId: nil) } } }
                    if !reverse && !sub, let previous { saveEditing(task) { model.change(completed: { state.expanded.insert(previous) }) { _ = try $0.reparent(task.id, parentId: previous) } } }
                }, blur: { saveEditing(task) }).frame(height: editHeight).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.top] + 14 }
                }
            } else {
                HStack(spacing: 4) {
                    Text(titleParts?.tags.isEmpty == false ? (titleParts?.text ?? task.title) : task.title).font(font(13)).foregroundColor(task.completed ? DotistDesign.faint : DotistDesign.ink)
                        .contentShape(Rectangle()).onTapGesture { beginEditing(task) }
                        .overlay(TaskDragSource(model: model, task: task, scope: scope, font: DotistDesign.nativeFont(13, language: model.language), click: { beginEditing(task) }).accessibilityHidden(true))
                    ForEach(titleParts?.tags ?? [], id: \.self) { tag in
                        Button("#" + tag) { state.activeTag = state.activeTag == tag ? nil : tag }.buttonStyle(.plain).modifier(DotistFocusRing()).font(font(12, state.activeTag == tag ? .medium : .regular)).foregroundColor(state.activeTag == tag ? DotistDesign.ink : DotistDesign.faint)
                    }
                    Color.clear.frame(maxWidth: .infinity, minHeight: 20)
                        .overlay(TaskDragSource(model: model, task: task, scope: scope, font: DotistDesign.nativeFont(13, language: model.language), click: { beginEditing(task) }).accessibilityHidden(true))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
            if let due = task.dueDate, !hideDue, editing != task.id {
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
            }.opacity(actionsVisible ? 0 : 1)
        }
        .overlay(alignment: .trailing) {
            if editing != task.id {
                HStack(spacing: 1) {
                    if !sub && !allTasks {
                        Button { state.expanded.insert(task.id); addingChild = task.id } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
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
                    .offset(x: 5).opacity(actionsVisible ? 1 : 0).disabled(!actionsVisible).accessibilityHidden(!actionsVisible)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
        .frame(minHeight: sub ? 28 : 32)
        .background { if editing == task.id { RoundedRectangle(cornerRadius: 6).fill(DotistDesign.rule.opacity(0.18)).padding(.horizontal, -6) } }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { rowHeights[task.id] = geometry.size.height }.onChange(of: geometry.size.height) { rowHeights[task.id] = $0 }
        })
        .contentShape(Rectangle())
        .focusable(true).focused($focusedTask, equals: task.id).focusEffectDisabled()
        .onMoveCommand { direction in
            guard NSEvent.modifierFlags.contains(.option) else { return }
            if direction == .up, let previous { model.reorder(task.id, relativeTo: previous, after: false, allTasks: allTasks) }
            if direction == .down, let next { model.reorder(task.id, relativeTo: next, after: true, allTasks: allTasks) }
        }
        .onTapGesture { model.focusId = task.id }
        .onDrop(of: ["public.utf8-plain-text"], delegate: TaskDrop(model: model, target: task.id, scope: scope, height: rowHeights[task.id] ?? (sub ? 28 : 32), allTasks: allTasks, sub: sub, dropTarget: $dropTarget, dropAfter: $dropAfter, dropAsChild: $dropAsChild))
        .overlay(alignment: dropAfter ? .bottom : .top) {
            if model.dragScope == scope, model.dragId != nil, model.dragId != task.id, dropTarget == task.id {
                Rectangle().fill(DotistDesign.accent).frame(height: 1.5).padding(.leading, dropAsChild && !sub ? 48 : 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onHover { over in if over { hoveredTask = task.id } else if hoveredTask == task.id { hoveredTask = nil } }
        .popover(isPresented: Binding(get: { pickingTask == task.id }, set: { if !$0 && pickingTask == task.id { pickingTask = nil } })) {
            RangeCalendar(model: model, start: task.dueDate ?? "", end: task.dueDate ?? "", choose: { date, _ in
                if task.dueDate == date { pickingTask = nil; return }
                model.change(completed: { pickingTask = nil }) { _ = try $0.setDueDate(task.id, date: date) }
            }, close: { pickingTask = nil }, single: true, clear: {
                model.change(completed: { pickingTask = nil }) { _ = try $0.setDueDate(task.id, date: nil) }
            })
        }
        .contextMenu {
            Button(model.text("编辑 {title}").replacingOccurrences(of: "{title}", with: task.title)) { beginEditing(task) }
            if !sub { Button(model.text("添加子任务")) { state.expanded.insert(task.id); addingChild = task.id } }
            if sub { Button(model.text("取消缩进")) { model.change { _ = try $0.reparent(task.id, parentId: nil) } } }
            if !sub && !allTasks, let previous {
                Button(model.text("缩进为上一条的子任务")) {
                    model.change(completed: { state.expanded.insert(previous) }) { _ = try $0.reparent(task.id, parentId: previous) }
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
        .accessibilityElement(children: .contain)
    }

    private func beginEditing(_ task: DotistTask) {
        guard editing != task.id else { return }
        if editSaving { pendingEdit = task; return }
        let start = { editHeight = 20; editing = task.id; editedTitle = task.title }
        if let id = editing, let current = model.tasks.first(where: { $0.id == id }) {
            saveEditing(current, then: start)
        } else { start() }
    }
    private func saveEditing(_ task: DotistTask, then: @escaping () -> Void = {}) {
        guard editing == task.id, !editSaving else { return }
        let title = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty && title != task.title else { editing = nil; then(); return }
        editSaving = true
        model.change(completed: {
            editSaving = false
            if editing == task.id {
                editing = nil
                if let pending = pendingEdit { pendingEdit = nil; editing = pending.id; editedTitle = pending.title } else { then() }
            }
        }, failed: { editSaving = false; pendingEdit = nil }) { _ = try $0.patchTask(id: task.id, title: title) }
    }

    private var composerBar: some View {
        let selected = model.groups.first(where: { $0.id == category }) ?? model.groups.first
        let shownDue = dueDate?.dotistDay ?? (["today", "tomorrow", "week", "nextweek", "next7"].contains(state.scope) ? rangeBounds.0 : nil)
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
            }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(Text(model.text("分组"))).accessibilityValue(Text(selected?.name ?? "")).onHover { hint = $0 ? model.text("分组") : "" }
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
                .onHover { hint = $0 ? model.text("设置到期日") : "" }
                .popover(isPresented: $showDuePicker) {
                    RangeCalendar(model: model, start: shownDue ?? "", end: shownDue ?? "", choose: { date, _ in dueDate = Date.dotistDay(date); showDuePicker = false }, close: { showDuePicker = false }, single: true, clear: { dueDate = nil; showDuePicker = false })
                }

        }.padding(.leading, 16).padding(.trailing, 11).frame(height: 52).onHover { composerHovered = $0 }.overlay(alignment: .top) { Rectangle().fill(DotistDesign.rule).frame(height: 0.5) }
    }

    private var groupShelf: some View {
        HStack(spacing: 18) {
            ForEach(model.groups) { group in
                Text(group.name).font(font(14, .semibold, serif: true))
                    .foregroundColor(shelfTarget == group.id ? DotistDesign.ink : DotistDesign.faint)
                    .frame(height: 48).contentShape(Rectangle())
                    .onDrop(of: ["public.utf8-plain-text"], delegate: ShelfDrop(model: model, group: group.id, target: $shelfTarget))
            }
            Button("＋ " + model.text("新分组")) { manageGroups = true }
                .buttonStyle(.plain).font(font(14, .semibold, serif: true)).foregroundColor(DotistDesign.faint)
        }.padding(.horizontal, 22).frame(maxWidth: .infinity).frame(height: 48)
            .glassEffect(.regular, in: .capsule).frame(height: 52)
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

private struct GroupDrop: DropDelegate {
    let model: AppModel
    let group: String
    func validateDrop(info: DropInfo) -> Bool {
        guard let id = model.dragId, let task = model.tasks.first(where: { $0.id == id }) else { return false }
        return task.parentId == nil && task.category != group
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let id = model.dragId else { return false }
        model.endDrag()
        model.change { _ = try $0.patchTask(id: id, category: group) }
        return true
    }
}

private struct TaskDrop: DropDelegate {
    let model: AppModel
    let target: String
    let scope: String
    let height: CGFloat
    let allTasks: Bool
    let sub: Bool
    @Binding var dropTarget: String?
    @Binding var dropAfter: Bool
    @Binding var dropAsChild: Bool
    func validateDrop(info: DropInfo) -> Bool { model.dragScope == scope && model.dragId != target }
    func dropEntered(info: DropInfo) { if model.dragScope == scope { dropTarget = target } }
    func dropExited(info: DropInfo) { if dropTarget == target { dropTarget = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let after = info.location.y >= height / 2
        dropAsChild = !allTasks && !sub && info.location.x >= 48
        if dropAfter != after { dropAfter = after }
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        guard model.dragScope == scope, let id = model.dragId else { return false }
        let asChild = !allTasks && !sub && info.location.x >= 48
        model.endDrag()
        dropTarget = nil
        dropAsChild = false
        if asChild { model.change { _ = try $0.reparent(id, parentId: target) } }
        else { model.reorder(id, relativeTo: target, after: info.location.y >= height / 2, allTasks: allTasks) }
        return true
    }
}

private struct ShelfDrop: DropDelegate {
    let model: AppModel
    let group: String
    @Binding var target: String?
    func dropEntered(info: DropInfo) { target = group }
    func dropExited(info: DropInfo) { if target == group { target = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        target = nil
        return GroupDrop(model: model, group: group).performDrop(info: info)
    }
}
