import AppKit
import DotistCore
import SwiftUI

struct MainWindow: View {
    @ObservedObject var model: AppModel
    let showViews: () -> Void
    let showSettings: () -> Void
    let collapse: () -> Void
    @State private var composer = ""
    @State private var composerSubmitting = false
    @State private var selectedSuggestion = -1
    @State private var category = "work"
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
    @State private var showGroupPicker = false
    @State private var customStart: String?
    @State private var customEnd: String?
    @State private var upcomingOpen = false
    @State private var todayDoneOpen = false
    @State private var rowHeights: [String: CGFloat] = [:]

    private var textColor: Color { DotistDesign.ink }
    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> Font {
        DotistDesign.font(size, weight: weight, serif: serif, language: model.language)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Text(model.text(error)).font(font(12)).foregroundColor(DotistDesign.danger).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
            if manageTags {
                TagManager(model: model, close: { manageTags = false }, groups: { manageTags = false; manageGroups = true })
            } else if manageGroups {
                GroupManager(model: model, close: { manageGroups = false }, tags: { manageGroups = false; manageTags = true })
            } else {
                header
                if model.tagCounts.contains(where: { $0.open > 0 }) { tagBar }
                ScrollViewReader { proxy in
                    GeometryReader { space in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if model.scope == "all" { allGroups }
                            else if model.scope == "today" && customStart == nil { todayList }
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
                        guard let id else { return }
                        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.22)) { proxy.scrollTo(id, anchor: .top) }
                        model.gotoGroup = nil
                    }
                    }
                }
            }
            if let undo = model.undo {
                HStack {
                    Text(model.text("已删除「{title}」").replacingOccurrences(of: "{title}", with: undo.title))
                    Spacer()
                    Button(model.text("撤销")) { model.restore() }.buttonStyle(.plain).modifier(DotistFocusRing())
                    Button { model.undo = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).modifier(DotistFocusRing())
                }.font(font(12)).padding(10).background(DotistDesign.surface).cornerRadius(8).padding(.horizontal, 12)
            }
            if !manageGroups && !manageTags { composerBar }
        }
        .foregroundColor(textColor)
        .onChange(of: model.scopeNavigation) { _ in customStart = nil; customEnd = nil }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(model.settings.filters, id: \.self) { id in
                        Button { model.scope = id; customStart = nil; customEnd = nil } label: {
                            Text(model.text(filterLabel(id)))
                                .font(font(14, model.scope == id ? .semibold : .regular, serif: true))
                                .foregroundColor(model.scope == id ? DotistDesign.ink : DotistDesign.faint)
                                .padding(.vertical, 5)
                        }.buttonStyle(.plain).modifier(DotistFocusRing())
                            .accessibilityAddTraits(model.scope == id ? .isSelected : [])
                    }
                }
            }
            Button { showCalendar.toggle() } label: { Image(systemName: "chevron.down").font(.system(size: 13)).frame(width: 24, height: 24).foregroundColor(DotistDesign.faint) }
                .buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("日历")))
                .popover(isPresented: $showCalendar) {
                    RangeCalendar(model: model, start: customStart ?? Date().dotistDay, end: customEnd ?? Date().dotistDay, choose: { start, end in
                        model.scope = "today"
                        customStart = start == Date().dotistDay && end == start ? nil : start
                        customEnd = customStart == nil ? nil : end
                    }, close: { showCalendar = false })
                }
            icon("rectangle.split.3x1", label: model.text("任务视图"), action: showViews)
            icon(model.settings.alwaysOnTop ? "pin.fill" : "pin", label: model.text(model.settings.alwaysOnTop ? "取消置顶" : "置顶窗口"), active: model.settings.alwaysOnTop) {
                var patch = DotistSettingsPatch(); patch.alwaysOnTop = !model.settings.alwaysOnTop; model.updateSettings(patch)
            }
            icon(model.settings.locked ? "lock" : "lock.open", label: model.text(model.settings.locked ? "取消固定" : "固定窗口"), active: model.settings.locked) {
                var patch = DotistSettingsPatch(); patch.locked = !model.settings.locked; model.updateSettings(patch)
            }
            icon("arrow.down.right.and.arrow.up.left", label: model.text("收起为悬浮球"), action: collapse)
        }.padding(.leading, 16).padding(.trailing, 10).frame(height: 44).background(WindowDragArea())
    }

    private var tagBar: some View {
        HStack(spacing: 14) {
            ForEach(model.tagCounts.filter { $0.open > 0 }) { tag in
                Button("#" + tag.tag) { model.selectTag(model.activeTag == tag.tag ? nil : tag.tag) }
                    .buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(model.activeTag == tag.tag ? DotistDesign.accent : DotistDesign.faint)
            }
            Spacer()
            Button(model.text("管理…")) { manageTags = true }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(DotistDesign.faint)
        }.font(font(12)).padding(.horizontal, 22).padding(.bottom, 6)
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
        ForEach(model.groups) { group in
            let roots = model.ordered(model.displayTasks.filter { $0.category == group.id && $0.parentId == nil })
            let open = roots.filter { !$0.completed }
            let completed = roots.filter(\.completed)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(group.name).font(font(14, .semibold, serif: true)).foregroundColor(model.settings.groupColors == "none" ? DotistDesign.muted : DotistDesign.category(group.color))
                    Spacer()
                    Button { groupIndented.remove(group.id); addingToGroup = group.id } label: { Image(systemName: "plus").frame(width: 24, height: 24) }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(DotistDesign.faint).help(model.text("添加任务"))
                    Text("\(open.count)").font(font(12)).foregroundColor(DotistDesign.faint)
                }.frame(height: 32)
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
                            if let parent { model.expanded.insert(parent) }
                        }, failed: { groupSubmitting = false }) { _ = try $0.addTask(title: title, category: group.id, parentId: parent) }
                    }, cancel: { addingToGroup = nil }, cycle: { step in
                        if step > 0 && !open.isEmpty { groupIndented.insert(group.id) } else { groupIndented.remove(group.id) }
                    }).padding(.leading, groupIndented.contains(group.id) ? 52 : 26).frame(height: 28)
                }
                if !completed.isEmpty {
                    Button {
                        if model.folded.contains(group.id) { model.folded.remove(group.id) } else { model.folded.insert(group.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: model.folded.contains(group.id) ? "chevron.down" : "chevron.right").frame(width: 18)
                            Text("\(model.text("已完成")) \(completed.count)")
                        }.font(font(12)).foregroundColor(DotistDesign.muted).frame(height: 28)
                    }.buttonStyle(.plain).modifier(DotistFocusRing())
                    if model.folded.contains(group.id) { ForEach(Array(completed.enumerated()), id: \.element.id) { index, task in taskTree(task, previous: index > 0 ? completed[index - 1].id : nil, next: index + 1 < completed.count ? completed[index + 1].id : nil) } }
                }
            }.id(group.id)
        }
    }

    @ViewBuilder private func taskTree(_ task: DotistTask, previous: String?, next: String?) -> some View {
        let children = model.visibleChildren(of: task)
        taskRow(task, children: children, sub: false, allTasks: false, previous: previous, next: next)
        if model.expanded.contains(task.id) {
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
                }).padding(.leading, 52).frame(height: 28)
            }
        }
    }

    @ViewBuilder private var filteredTasks: some View {
        let today = Date().dotistDay
        if model.scope == "overdue" {
            let values = model.ordered(model.displayTasks.filter { !$0.completed && $0.dueDate.map { $0 < today } == true })
            if values.isEmpty { Text(model.text("没有逾期的任务。")).font(font(12)).foregroundColor(DotistDesign.muted) }
            else { todaySection("已逾期", items: values) }
        } else if model.scope == "undated" {
            let values = model.displayTasks.filter { !$0.completed && $0.dueDate == nil }
            if values.isEmpty { Text(model.text("每个任务都有到期日。")).font(font(12)).foregroundColor(DotistDesign.muted) }
            else {
                ForEach(model.groups) { group in
                    let items = model.ordered(values.filter { $0.category == group.id })
                    if !items.isEmpty { todaySection(group.name, items: items) }
                }
            }
        } else if model.scope == "done" {
            let values = model.ordered(Array(model.displayTasks.filter(\.completed).sorted { $0.updatedAt > $1.updatedAt }.prefix(200)))
            if values.isEmpty { Text(model.text("还没有完成的任务。")).font(font(12)).foregroundColor(DotistDesign.muted) }
            else { todaySection("已完成", items: values) }
        } else {
            let bounds = rangeBounds
            let values = model.displayTasks.filter { $0.dueDate.map { $0 >= bounds.0 && $0 <= bounds.1 } == true }
            let dates = Array(Set(values.filter { !$0.completed }.compactMap(\.dueDate))).sorted()
            VStack(alignment: .leading, spacing: 20) {
                ForEach(dates, id: \.self) { date in
                    todaySection(model.dueLabel(date), items: model.ordered(values.filter { !$0.completed && $0.dueDate == date }), hideDue: true)
                }
                if dates.isEmpty { Text(model.text("今天没有安排。在下方添加，或在「全部」里给任务设置到期日。")).font(font(12)).foregroundColor(DotistDesign.muted) }
                let done = model.ordered(values.filter(\.completed))
                if !done.isEmpty {
                    Button { todayDoneOpen.toggle() } label: {
                        HStack { Image(systemName: todayDoneOpen ? "chevron.down" : "chevron.right").frame(width: 18); Text(model.text("已完成")); Text("\(done.count)") }.font(font(12)).foregroundColor(DotistDesign.muted)
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
        switch model.scope {
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
        let overdue = model.ordered(model.displayTasks.filter { !$0.completed && $0.dueDate.map { $0 < today } == true })
        let due = model.ordered(model.displayTasks.filter { !$0.completed && $0.dueDate == today })
        let upcoming = model.ordered(model.displayTasks.filter { !$0.completed && $0.dueDate.map { $0 > today && $0 <= horizon } == true })
        let done = model.ordered(model.displayTasks.filter { task in
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
                    HStack { Image(systemName: upcomingOpen ? "chevron.down" : "chevron.right").frame(width: 18); Text(model.text("接下来 {n} 天").replacingOccurrences(of: "{n}", with: "7")); Text("\(upcoming.count)") }
                        .font(font(12)).foregroundColor(DotistDesign.muted)
                }.buttonStyle(.plain).modifier(DotistFocusRing())
                if upcomingOpen { flatRows(upcoming) }
            }
            if !done.isEmpty {
                Button { todayDoneOpen.toggle() } label: {
                    HStack { Image(systemName: todayDoneOpen ? "chevron.down" : "chevron.right").frame(width: 18); Text(model.text("已完成")); Text("\(done.count)") }
                        .font(font(12)).foregroundColor(DotistDesign.muted)
                }.buttonStyle(.plain).modifier(DotistFocusRing())
                if todayDoneOpen { flatRows(done) }
            }
        }
    }
    private func todaySection(_ title: String, items: [DotistTask], hideDue: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(model.text(title)).font(font(14, .semibold, serif: true)); Spacer(); Text("\(items.count)").font(font(12)) }
                .foregroundColor(title == "已逾期" ? DotistDesign.danger : DotistDesign.muted).frame(height: 32)
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
            ? (model.scope == "today" && customStart == nil
                ? (task.completed ? "today:done" : task.dueDate.map { $0 < Date().dotistDay ? "today:overdue" : $0 == Date().dotistDay ? "today:today" : "today:upcoming" } ?? "today:undated")
                : model.scope == "overdue" || model.scope == "done" ? "scope:\(model.scope)"
                : model.scope == "undated" ? "undated:\(task.category)"
                : task.completed ? "range:done"
                : "day:\(task.dueDate ?? "undated")")
            : (task.parentId.map { "children:\($0)" } ?? "group:\(task.category):\(task.completed)")
        let titleParts = model.tags(for: task)
        return HStack(alignment: .center, spacing: 8) {
            Button { model.complete(task) } label: {
                ZStack {
                    if !task.completed && children.count > 1 {
                        let span = 1.0 / Double(children.count)
                        let gap = children.count > 12 ? 0.0 : min(14.0, 120.0 / Double(children.count)) / 360.0
                        let done = children.filter(\.completed).count
                        ForEach(0..<children.count, id: \.self) { index in
                            Circle().trim(from: Double(index) * span + gap / 2, to: min(1, Double(index) * span + gap / 2 + max(span - gap, 0.01)))
                                .stroke(index < done ? DotistDesign.accent : DotistDesign.faint.opacity(0.7), lineWidth: 1.5).rotationEffect(.degrees(-90))
                        }
                    } else {
                        Circle().stroke(task.completed ? DotistDesign.accent : DotistDesign.faint, lineWidth: 1.5)
                        if !task.completed && children.count == 1 && children[0].completed { Circle().stroke(DotistDesign.accent, lineWidth: 1.5) }
                    }
                    if task.completed { Circle().fill(DotistDesign.accent); Image(systemName: "checkmark").font(.system(size: sub ? 8 : 10, weight: .medium)).foregroundColor(.white) }
                }.frame(width: sub ? 14 : 18, height: sub ? 14 : 18).frame(width: 18).contentShape(Rectangle())
            }.buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text(task.completed ? "恢复 {title}" : "完成 {title}").replacingOccurrences(of: "{title}", with: task.title)))
            if editing == task.id {
                TaskEditor(text: $editedTitle, height: $editHeight, font: DotistDesign.nativeFont(13, language: model.language), label: model.text("任务内容"), commit: {
                    saveEditing(task) {
                        if let parent = task.parentId { model.expanded.insert(parent); addingChild = parent }
                        else { groupIndented.remove(task.category); addingToGroup = task.category }
                    }
                }, cancel: { editing = nil }, indent: { reverse in
                    if reverse && sub { saveEditing(task) { model.change { _ = try $0.reparent(task.id, parentId: nil) } } }
                    if !reverse && !sub, let previous { saveEditing(task) { model.change(completed: { model.expanded.insert(previous) }) { _ = try $0.reparent(task.id, parentId: previous) } } }
                }, blur: { saveEditing(task) }).frame(height: editHeight)
            } else {
                HStack(spacing: 4) {
                    Text(titleParts?.tags.isEmpty == false ? (titleParts?.text ?? task.title) : task.title).font(font(13)).strikethrough(task.completed).foregroundColor(task.completed ? DotistDesign.muted : DotistDesign.ink)
                        .contentShape(Rectangle()).onTapGesture { beginEditing(task) }
                    ForEach(titleParts?.tags ?? [], id: \.self) { tag in
                        Button("#" + tag) { model.selectTag(model.activeTag == tag ? nil : tag) }.buttonStyle(.plain).modifier(DotistFocusRing()).font(font(12)).foregroundColor(model.activeTag == tag ? DotistDesign.accent : DotistDesign.faint)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let due = task.dueDate, !hideDue, editing != task.id {
                Button(model.dueLabel(due)) { pickingTask = task.id }.buttonStyle(.plain).modifier(DotistFocusRing()).font(font(12))
                    .foregroundColor(due < Date().dotistDay && !task.completed ? DotistDesign.danger : due == Date().dotistDay ? DotistDesign.accent : DotistDesign.muted)
                    .accessibilityLabel(Text(model.text("到期日 {date}，点击修改").replacingOccurrences(of: "{date}", with: model.dueLabel(due))))
            }
            if allTasks, let group = model.group(for: task) { Text(group.name).font(font(12, .semibold, serif: true)).foregroundColor(model.settings.groupColors == "none" ? DotistDesign.muted : DotistDesign.category(group.color)) }
            if !children.isEmpty {
                Button {
                    if model.expanded.contains(task.id) { model.expanded.remove(task.id) } else { model.expanded.insert(task.id) }
                } label: {
                    HStack(spacing: 2) {
                        Text("\(children.filter(\.completed).count)/\(children.count)")
                        Image(systemName: model.expanded.contains(task.id) ? "chevron.down" : "chevron.right").font(.system(size: 10))
                    }.font(font(12)).foregroundColor(DotistDesign.faint)
                }.buttonStyle(.plain).modifier(DotistFocusRing())
                    .accessibilityLabel(Text(model.text("子任务 {done}/{total}").replacingOccurrences(of: "{done}", with: "\(children.filter(\.completed).count)").replacingOccurrences(of: "{total}", with: "\(children.count)")))
            }
        }
        .frame(minHeight: sub ? 28 : 32)
        .background(GeometryReader { geometry in
            Color.clear.onAppear { rowHeights[task.id] = geometry.size.height }.onChange(of: geometry.size.height) { rowHeights[task.id] = $0 }
        })
        .contentShape(Rectangle())
        .onHover { over in if over { hoveredTask = task.id } else if hoveredTask == task.id { hoveredTask = nil } }
        .opacity(editing != nil && editing != task.id ? 0.45 : 1)
        .focusable(true)
        .modifier(DotistFocusRing())
        .onMoveCommand { direction in
            guard NSEvent.modifierFlags.contains(.option) else { return }
            if direction == .up, let previous { model.reorder(task.id, relativeTo: previous, after: false, allTasks: allTasks) }
            if direction == .down, let next { model.reorder(task.id, relativeTo: next, after: true, allTasks: allTasks) }
        }
        .onTapGesture { model.focusId = task.id }
        .onDrag { model.beginDrag(task.id, scope: scope); return NSItemProvider(object: task.id as NSString) }
        .onDrop(of: ["public.utf8-plain-text"], delegate: TaskDrop(model: model, target: task.id, scope: scope, height: rowHeights[task.id] ?? (sub ? 28 : 32), allTasks: allTasks, dropTarget: $dropTarget, dropAfter: $dropAfter))
        .overlay(Group {
            if editing != task.id {
                HStack(spacing: 0) {
                    if !sub && !allTasks {
                        Button { model.expanded.insert(task.id); addingChild = task.id } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                            .modifier(DotistFocusRing())
                            .accessibilityLabel(Text(model.text("添加子任务 {title}").replacingOccurrences(of: "{title}", with: task.title)))
                    }
                    Button { pickingTask = task.id } label: { Image(systemName: "calendar").frame(width: 24, height: 24) }
                        .modifier(DotistFocusRing())
                        .accessibilityLabel(Text(model.text("设置到期日 {title}").replacingOccurrences(of: "{title}", with: task.title)))
                    Button { model.delete(task) } label: { Image(systemName: "trash").frame(width: 24, height: 24) }
                        .modifier(DotistFocusRing())
                        .accessibilityLabel(Text(model.text("删除 {title}").replacingOccurrences(of: "{title}", with: task.title)))
                }.buttonStyle(.plain).font(.system(size: 13)).foregroundColor(DotistDesign.faint)
                    .opacity(hoveredTask == task.id || model.focusId == task.id ? 1 : 0)
                    .allowsHitTesting(hoveredTask == task.id || model.focusId == task.id)
            }
        }, alignment: .trailing)
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
            if !sub { Button(model.text("添加子任务")) { model.expanded.insert(task.id); addingChild = task.id } }
            if sub { Button(model.text("取消缩进")) { model.change { _ = try $0.reparent(task.id, parentId: nil) } } }
            if !sub && !allTasks, let previous {
                Button(model.text("缩进为上一条的子任务")) {
                    model.change(completed: { model.expanded.insert(previous) }) { _ = try $0.reparent(task.id, parentId: previous) }
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
        let start = { editing = task.id; editedTitle = task.title }
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
        let shownDue = dueDate?.dotistDay ?? (["today", "tomorrow", "week", "nextweek", "next7"].contains(model.scope) ? rangeBounds.0 : nil)
        return HStack(spacing: 8) {
            Button { showGroupPicker.toggle() } label: {
                Text(selected?.name ?? "").font(font(12, .semibold, serif: true))
                    .foregroundColor(model.settings.groupColors == "none" ? DotistDesign.ink : DotistDesign.category(selected?.color ?? "work"))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).modifier(DotistFocusRing()).frame(width: 64)
                .accessibilityLabel(Text(model.text("分组")))
                .accessibilityValue(Text(selected?.name ?? ""))
                .popover(isPresented: $showGroupPicker) {
                    VStack(alignment: .leading, spacing: 0) {
                        GroupPickerRow(title: model.text("管理分组…"), language: model.language) { showGroupPicker = false; manageGroups = true }
                        GroupPickerRow(title: model.text("管理标签…"), language: model.language) { showGroupPicker = false; manageTags = true }
                        Divider().padding(.vertical, 5).padding(.horizontal, 8)
                        ForEach(model.groups) { group in
                            GroupPickerRow(title: group.name, language: model.language,
                                           color: model.settings.groupColors == "none" ? DotistDesign.ink : DotistDesign.category(group.color),
                                           selected: group.id == selected?.id) { category = group.id; showGroupPicker = false }
                        }
                    }.padding(6).frame(width: 172)
                }
            Button { showDuePicker.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").frame(width: 16, height: 24)
                    if let shownDue { Text(model.dueLabel(shownDue)).font(font(12)) }
                }.foregroundColor(shownDue == nil ? DotistDesign.faint : DotistDesign.ink)
            }
                .buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("设置到期日")))
                .popover(isPresented: $showDuePicker) {
                    RangeCalendar(model: model, start: shownDue ?? "", end: shownDue ?? "", choose: { date, _ in dueDate = Date.dotistDay(date); showDuePicker = false }, close: { showDuePicker = false }, single: true, clear: { dueDate = nil; showDuePicker = false })
                }
            ZStack(alignment: .topLeading) {
                ComposerInput(text: $composer, placeholder: model.text("写下一件小事"), label: model.text("新任务"), font: DotistDesign.nativeFont(13, language: model.language), commit: addTask, navigate: { direction in
                    let values = tagSuggestions
                    guard !values.isEmpty else { return false }
                    selectedSuggestion = (selectedSuggestion + direction + values.count) % values.count
                    return true
                }, complete: { force in chooseSuggestion(force: force) }).frame(height: 24)
                if !tagSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tagSuggestions.enumerated()), id: \.element) { index, tag in
                            Button("#" + tag) { selectedSuggestion = index; _ = chooseSuggestion(force: true) }
                                .buttonStyle(.plain).modifier(DotistFocusRing()).font(font(12)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 28)
                                .background(index == selectedSuggestion ? DotistDesign.surface : Color.clear)
                        }
                    }.background(DotistDesign.paper).cornerRadius(8).offset(y: -CGFloat(tagSuggestions.count * 28 + 6)).zIndex(1)
                }
            }.frame(maxWidth: .infinity).onChange(of: composer) { _ in selectedSuggestion = -1 }
            Text(model.text("还有 {n} 件").replacingOccurrences(of: "{n}", with: "\(model.tasks.filter { !$0.completed && $0.parentId == nil }.count)")).font(font(12)).foregroundColor(DotistDesign.faint)
        }.padding(.horizontal, 16).frame(height: 56)
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
        let date = dueDate?.dotistDay ?? (["today", "tomorrow", "week", "nextweek", "next7"].contains(model.scope) ? rangeBounds.0 : nil)
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

private struct GroupPickerRow: View {
    let title: String
    let language: String
    var color = DotistDesign.muted
    var selected = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DotistDesign.accent)
                    .opacity(selected ? 1 : 0)
            }
            .font(DotistDesign.font(13, language: language))
            .foregroundColor(hovering ? DotistDesign.ink : color)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(DotistFocusRing())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct TaskDrop: DropDelegate {
    let model: AppModel
    let target: String
    let scope: String
    let height: CGFloat
    let allTasks: Bool
    @Binding var dropTarget: String?
    @Binding var dropAfter: Bool
    func validateDrop(info: DropInfo) -> Bool { model.dragScope == scope && model.dragId != target }
    func dropEntered(info: DropInfo) { if model.dragScope == scope { dropTarget = target } }
    func dropExited(info: DropInfo) { if dropTarget == target { dropTarget = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropAfter = info.location.y >= height / 2
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        guard model.dragScope == scope, let id = model.dragId else { return false }
        model.endDrag()
        dropTarget = nil
        model.reorder(id, relativeTo: target, after: info.location.y >= height / 2, allTasks: allTasks)
        return true
    }
}
