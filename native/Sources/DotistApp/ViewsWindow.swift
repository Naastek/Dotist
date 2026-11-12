import AppKit
import DotistCore
import SwiftUI

struct ViewsWindow: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject var model: AppModel
    @State private var view = "calendar"
    @State private var scale = "month"
    @State private var selected = Date()
    @State private var visibleMonth = Date()
    @State private var ganttAnchor = Date()
    @State private var ganttScale = "month"
    @State private var grouped = false
    @State private var collapsed: Set<String> = []
    @State private var dropTarget: String?
    @State private var dropAfter = false
    @State private var ganttLabelHeights: [String: CGFloat] = [:]
    @State private var keyboardDate: String?
    @State private var showUnscheduled = false

    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> Font {
        (serif ? DotistDesign.nameFont(size, weight: weight, language: model.language) : DotistDesign.textFont(size, weight: weight, language: model.language))
    }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.firstWeekday = model.language == "en" ? 1 : 2
        return value
    }
    private func startOfWeek(_ date: Date) -> Date {
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)
        return calendar.date(byAdding: .day, value: -((weekday - calendar.firstWeekday + 7) % 7), to: start)!
    }
    private func startOfMonth(_ date: Date) -> Date { calendar.date(from: calendar.dateComponents([.year, .month], from: date))! }
    private func day(_ date: Date, _ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: date)! }
    private func choose(_ date: Date) { selected = date; visibleMonth = startOfMonth(date) }
    private func dateText(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: model.language)
        formatter.setLocalizedDateFormatFromTemplate(format)
        return formatter.string(from: date)
    }

    var body: some View {
        GeometryReader { geometry in
        let narrow = geometry.size.width <= 860
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                tabs([("calendar", "日历"), ("board", "看板"), ("gantt", "甘特")], selection: $view)
            }.padding(.leading, 88).padding(.trailing, 20).frame(height: 48).background(WindowDragArea())
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = model.error { Text(model.text(error)).foregroundColor(DotistDesign.danger).padding(.bottom, 12) }
                    if view == "calendar" { calendarView(narrow: narrow, wrapNavigation: geometry.size.width <= 700, height: max(340, geometry.size.height - 206)) }
                    if view == "board" { boardView(narrow: narrow) }
                    if view == "gantt" { ganttView(narrow: geometry.size.width <= 760) }
                }.padding(.horizontal, narrow ? 16 : 24).padding(.top, 12).padding(.bottom, 20).frame(minWidth: 632, maxWidth: .infinity, alignment: .topLeading).background(WindowDragArea())
            }
        }.foregroundColor(DotistDesign.ink).modifier(DotistControlTint()).background(WindowMaterial(opacity: 78, frost: model.settings.frost)).modifier(DotistTheme(theme: model.settings.theme))
            .clipShape(RoundedRectangle(cornerRadius: DotistDesign.windowCornerRadius, style: .continuous).inset(by: reduceTransparency || contrast == .increased ? 0 : ExpandedReadingMaterial.opticalClearance))
        }
    }

    private func tabs(_ choices: [(String, String)], selection: Binding<String>) -> some View {
        DotistGlassTabs(selection: selection, options: choices.map { ($0.0, model.text($0.1)) }, language: model.language)
    }

    private func calendarView(narrow: Bool, wrapNavigation: Bool, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if wrapNavigation {
                VStack(alignment: .leading, spacing: 12) {
                    calendarTitle
                    HStack(spacing: 8) { calendarNavigation; Spacer(minLength: 0) }
                }
            } else {
                HStack(spacing: 12) { calendarTitle; Spacer(minLength: 8); calendarNavigation }.frame(minHeight: 36)
            }
            if scale == "day" || scale == "week" {
                calendarColumns(height: height)
                unscheduledSection
            } else if narrow {
                calendarGrid
                selectedAgenda
                unscheduledSection
            } else {
                HStack(alignment: .top, spacing: 24) { calendarGrid; agenda.frame(width: 260) }
            }
        }
    }

    private var unscheduledSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { showUnscheduled.toggle() } label: {
                HStack(spacing: 8) {
                    OpticalSymbol(name: showUnscheduled ? "chevron.down" : "chevron.right", size: 9, weight: .semibold)
                    OpticalText(title: "\(model.text("未排期")) \(model.tasks.filter { $0.dueDate == nil }.count)", size: 13, weight: .medium, language: model.language)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle()).padding(.vertical, 8)
            }.buttonStyle(.plain).modifier(DotistFocusRing())
            if showUnscheduled { unscheduledAgenda }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func calendarColumns(height: CGFloat) -> some View {
        let dates = scale == "day" ? [selected] : (0..<7).map { day(startOfWeek(selected), $0) }
        return HStack(alignment: .top, spacing: 0) {
            ForEach(dates, id: \.self) { date in
                calendarColumn(date, height: height)
            }
        }.frame(maxWidth: .infinity)
    }

    private func calendarColumn(_ date: Date, height: CGFloat) -> some View {
        let items = model.ordered(model.tasks.filter { $0.dueDate == date.dotistDay })
        let isSelected = date.dotistDay == selected.dotistDay
        let isToday = date.dotistDay == Date().dotistDay
        return VStack(alignment: .leading, spacing: 10) {
            Button { choose(date); keyboardDate = date.dotistDay } label: {
                VStack(alignment: .center, spacing: 4) {
                    Text(dateText(date, format: "EEE")).font(font(12)).foregroundColor(DotistDesign.muted)
                    Text("\(calendar.component(.day, from: date))").font(font(20, isToday || isSelected ? .semibold : .regular))
                        .foregroundColor(isToday ? DotistDesign.accent : DotistDesign.ink)
                        .frame(minWidth: 32, minHeight: 30)
                }.frame(maxWidth: .infinity).padding(.bottom, 8)
            }.buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .modifier(CalendarFocusModifier(date: date.dotistDay, keyboardDate: $keyboardDate))
                .onMoveCommand { direction in moveDate(date, direction: direction) }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, task in
                ViewTaskCard(model: model, task: task, previous: index > 0 ? items[index - 1].id : nil, next: index + 1 < items.count ? items[index + 1].id : nil, scope: "date", calendarColumn: true, dropTarget: $dropTarget, dropAfter: $dropAfter)
            }
            if items.isEmpty && scale == "day" {
                Text(model.text("当天没有任务")).font(font(12)).foregroundColor(DotistDesign.muted).padding(.top, 12)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, scale == "day" ? 12 : 6).padding(.top, 8)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        .overlay(Rectangle().fill(DotistDesign.rule.opacity(0.55)).frame(width: 0.5), alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { choose(date); keyboardDate = date.dotistDay }
        .onDrop(of: ["public.utf8-plain-text"], delegate: DateDrop(model: model, date: date.dotistDay))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(dateText(date, format: "yyyyMMMMEEEEd")))
        .accessibilityValue(Text(isSelected ? model.text("已选择") : isToday ? model.text("今天") : ""))
    }

    private func moveDate(_ date: Date, direction: MoveCommandDirection) {
        switch direction {
        case .left: choose(day(date, -1))
        case .right: choose(day(date, 1))
        case .up: choose(day(date, -7))
        case .down: choose(day(date, 7))
        @unknown default: break
        }
        keyboardDate = selected.dotistDay
    }

    private var calendarTitle: some View {
        OpticalText(title: scale == "month" ? dateText(visibleMonth, format: "yyyyMMMM") : scale == "day" ? dateText(selected, format: "yyyyMMMMEEEEd") : "\(dateText(startOfWeek(selected), format: "MMMd")) – \(dateText(day(startOfWeek(selected), 6), format: "MMMd"))", size: 20, weight: .semibold, language: model.language)
    }
    private var calendarNavigation: some View {
        Group {
            tabs([("day", "日"), ("week", "周"), ("month", "月")], selection: Binding(get: { scale }, set: { value in
                if scale == "month" && value != "month" && !calendar.isDate(selected, equalTo: visibleMonth, toGranularity: .month) { choose(startOfMonth(visibleMonth)) }
                scale = value
            }))
            navigationButton("chevron.left", label: "上一段") { movePeriod(-1) }
            Button { choose(Date()) } label: { OpticalText(title: model.text("今天"), size: 13, language: model.language) }.buttonStyle(DotistActionStyle()).modifier(DotistFocusRing())
            navigationButton("chevron.right", label: "下一段") { movePeriod(1) }
        }
    }
    private var calendarGrid: some View {
        let month = startOfMonth(visibleMonth)
        let start = day(month, -((calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7))
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(dateText(day(start, index), format: "EEE")).font(font(12)).foregroundColor(DotistDesign.muted).frame(maxWidth: .infinity).padding(.bottom, 12)
                }
            }
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { weekday in calendarCell(day(start, week * 7 + weekday), height: 90) }
                }
            }
        }.frame(maxWidth: .infinity)
    }

    private func movePeriod(_ direction: Int) {
        switch scale {
        case "day": choose(day(selected, direction))
        case "week": choose(day(selected, direction * 7))
        default: visibleMonth = calendar.date(byAdding: .month, value: direction, to: startOfMonth(visibleMonth))!
        }
    }
    private func navigationButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { OpticalSymbol(name: symbol, size: 11) }.buttonStyle(DotistActionStyle(icon: true)).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text(label)))
    }
    private func calendarCell(_ date: Date, height: CGFloat) -> some View {
        let items = model.ordered(model.tasks.filter { $0.dueDate == date.dotistDay })
        return VStack(alignment: .leading, spacing: 2) {
            Button { choose(date); keyboardDate = date.dotistDay } label: {
                Text("\(calendar.component(.day, from: date))").font(font(12, date.dotistDay == Date().dotistDay || date.dotistDay == selected.dotistDay ? .semibold : .regular))
                    .foregroundColor(date.dotistDay == Date().dotistDay ? DotistDesign.accent : calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month) ? DotistDesign.ink : DotistDesign.faint)
                    .frame(width: 26, height: 24)
            }.buttonStyle(.plain)
                .accessibilityAddTraits(date.dotistDay == selected.dotistDay ? .isSelected : [])
                .modifier(CalendarFocusModifier(date: date.dotistDay, keyboardDate: $keyboardDate))
                .onMoveCommand { direction in moveDate(date, direction: direction) }
            ForEach(Array(items.prefix(2))) { task in
                IconTextRow(spacing: 3) {
                    if task.completed { OpticalSymbol(name: "checkmark", size: 9) }
                    else if task.dueDate.map({ $0 < Date().dotistDay }) == true { OpticalSymbol(name: "exclamationmark.triangle", size: 9) }
                    OpticalText(title: task.title, size: 11, language: model.language)
                }.foregroundColor(task.completed ? DotistDesign.faint : DotistDesign.ink).lineLimit(1)
                    .foregroundColor(date.dotistDay == selected.dotistDay ? DotistDesign.accent : DotistDesign.ink)
                    .overlay(TaskDragSource(model: model, task: task, scope: "calendar", font: DotistDesign.nativeFont(11, language: model.language), click: { choose(date); keyboardDate = date.dotistDay }).accessibilityHidden(true))
            }
            if items.count > 2 { Text(model.text("另有 {n} 件").replacingOccurrences(of: "{n}", with: "\(items.count - 2)")).font(font(11)).foregroundColor(DotistDesign.muted) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .overlay(Rectangle().fill(DotistDesign.rule).frame(height: 0.5), alignment: .top)
        .contentShape(Rectangle()).onTapGesture { choose(date); keyboardDate = date.dotistDay }
        .onDrop(of: ["public.utf8-plain-text"], delegate: DateDrop(model: model, date: date.dotistDay))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(dateText(date, format: "yyyyMMMMEEEEd")))
        .accessibilityValue(Text(date.dotistDay == selected.dotistDay ? model.text("已选择") : date.dotistDay == Date().dotistDay ? model.text("今天") : ""))
    }
    private var agenda: some View {
        VStack(alignment: .leading, spacing: 12) {
            selectedAgenda
            unscheduledSection
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var selectedAgenda: some View {
        VStack(alignment: .leading, spacing: 12) {
            if scale != "day" { Text(dateText(selected, format: "yyyyMMMMEEEEd")).font(font(16, .medium)) }
            let current = model.ordered(model.tasks.filter { $0.dueDate == selected.dotistDay })
            ForEach(Array(current.enumerated()), id: \.element.id) { index, task in
                ViewTaskCard(model: model, task: task, previous: index > 0 ? current[index - 1].id : nil, next: index + 1 < current.count ? current[index + 1].id : nil, scope: "date", dropTarget: $dropTarget, dropAfter: $dropAfter)
            }
            if current.isEmpty { Text(model.text("当天没有任务")).font(font(12)).foregroundColor(DotistDesign.muted) }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var unscheduledAgenda: some View {
        VStack(alignment: .leading, spacing: 12) {
            let undated = model.ordered(model.tasks.filter { $0.dueDate == nil })
            ForEach(Array(undated.enumerated()), id: \.element.id) { index, task in
                ViewTaskCard(model: model, task: task, previous: index > 0 ? undated[index - 1].id : nil, next: index + 1 < undated.count ? undated[index + 1].id : nil, scope: "date", dropTarget: $dropTarget, dropAfter: $dropAfter)
            }
            if undated.isEmpty { Text(model.text("所有任务均已排期")).font(font(12)).foregroundColor(DotistDesign.muted) }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func boardView(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.text("拖动任务更改状态；也可在「调整任务」中更改状态或上下排序。"))
                .font(font(12)).foregroundColor(DotistDesign.muted)
            HStack(alignment: .top, spacing: narrow ? 12 : 20) {
                boardColumn(.todo, "待办", "square")
                boardColumn(.doing, "进行中", "rectangle.fill")
                boardColumn(.done, "完成", "checkmark")
            }
        }
    }
    private func boardColumn(_ status: TaskStatus, _ label: String, _ symbol: String) -> some View {
        let values = model.ordered(model.tasks.filter { $0.parentId == nil && $0.status == status })
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                OpticalSymbol(name: symbol, size: 11)
                OpticalText(title: model.text(label), size: 16, weight: .medium, language: model.language)
                Spacer()
                OpticalText(title: "\(values.count)", size: 12, language: model.language).foregroundColor(DotistDesign.muted)
            }.padding(.bottom, 12).overlay(Rectangle().fill(DotistDesign.rule).frame(height: 1), alignment: .bottom)
            if values.isEmpty { Text(model.text("暂无任务")).font(font(12)).foregroundColor(DotistDesign.muted).padding(.top, 8) }
            ForEach(Array(values.enumerated()), id: \.element.id) { index, task in
                ViewTaskCard(model: model, task: task, previous: index > 0 ? values[index - 1].id : nil, next: index + 1 < values.count ? values[index + 1].id : nil, scope: "board", dropTarget: $dropTarget, dropAfter: $dropAfter)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading).contentShape(Rectangle())
            .onDrop(of: ["public.utf8-plain-text"], delegate: StatusDrop(model: model, status: status))
    }

    private var ganttStart: Date { ganttScale == "week" ? startOfWeek(ganttAnchor) : startOfMonth(ganttAnchor) }
    private var ganttCount: Int {
        if ganttScale == "week" { return 7 }
        return calendar.range(of: .day, in: .month, for: ganttStart)!.count
    }
    private var ganttTitle: some View {
        OpticalText(title:"\(ganttStart.dotistDay) – \(day(ganttStart, ganttCount - 1).dotistDay)", size: 20, weight: .semibold, language: model.language)
    }
    private var ganttNavigation: some View {
        HStack(spacing: 8) {
            tabs([("week", "周"), ("month", "月")], selection: $ganttScale)
            navigationButton("chevron.left", label: "上一段") { ganttAnchor = ganttScale == "week" ? day(ganttAnchor, -7) : calendar.date(byAdding: .month, value: -1, to: ganttAnchor)! }
            Button { ganttAnchor = Date() } label: { OpticalText(title: model.text("今天"), size: 13, language: model.language) }.buttonStyle(DotistActionStyle()).modifier(DotistFocusRing())
            navigationButton("chevron.right", label: "下一段") { ganttAnchor = ganttScale == "week" ? day(ganttAnchor, 7) : calendar.date(byAdding: .month, value: 1, to: ganttAnchor)! }
        }
    }
    private func ganttView(narrow: Bool) -> some View {
        let roots = model.ordered(model.tasks.filter { $0.parentId == nil })
        let scheduled = roots.filter { $0.startDate != nil || $0.dueDate != nil }
        let undated = roots.filter { $0.startDate == nil && $0.dueDate == nil }
        return VStack(alignment: .leading, spacing: 12) {
            Group {
                if narrow {
                    VStack(alignment: .leading, spacing: 12) { ganttTitle; ganttNavigation }
                } else {
                    HStack(spacing: 12) { ganttTitle; Spacer(minLength: 8); ganttNavigation }
                }
            }.padding(.bottom, 8)
            HStack(spacing: 12) {
                OpticalText(title: model.text("排序方式"), size: 12, language: model.language).foregroundColor(DotistDesign.muted)
                tabs([("manual", "手动排序"), ("grouped", "按分组")], selection: Binding(get: { grouped ? "grouped" : "manual" }, set: { grouped = $0 == "grouped" }))
            }
            Text(model.text("拖动横条或边缘调整日期；也可在「调整任务」中输入日期。") + " " + model.text("拖动排序；按住 Option 并使用上下方向键调整。"))
                .font(font(12)).foregroundColor(DotistDesign.muted).padding(.bottom, 8)
            HStack(spacing: 0) {
                Color.clear.frame(width: 220, height: 20)
                HStack(spacing: 0) { ForEach(0..<ganttCount, id: \.self) { index in Text("\(calendar.component(.day, from: day(ganttStart, index)))").font(font(10)).foregroundColor(DotistDesign.muted).frame(maxWidth: .infinity) } }
            }.frame(minWidth: 600)
            if grouped {
                ForEach(model.groups) { group in
                    let values = scheduled.filter { $0.category == group.id }
                    if !values.isEmpty {
                        HStack(spacing: 0) {
                            Button {
                                if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                            } label: {
                                HStack {
                                    OpticalSymbol(name: collapsed.contains(group.id) ? "chevron.right" : "chevron.down", size: 9, weight: .semibold)
                                    OpticalText(title: model.groupDisplayName(group.id), size: 13, weight: .semibold, serif: true, language: model.language).foregroundColor(DotistDesign.ink)
                                    Spacer()
                                    OpticalText(title: "\(values.count)", size: 12, language: model.language)
                                }.padding(.horizontal, 10).frame(width: 220, height: 38).contentShape(Rectangle())
                            }.buttonStyle(.plain).modifier(DotistFocusRing())
                            GanttGroupTrack(group: group, tasks: values, start: ganttStart, count: ganttCount)
                        }.frame(minWidth: 600, minHeight: 38).background(DotistDesign.surface)
                        if !collapsed.contains(group.id) { ganttRows(values) }
                    }
                }
            } else { ganttRows(scheduled) }
            if !undated.isEmpty {
                Text("\(model.text("未排期")) \(undated.count)").font(font(16, .medium)).padding(.top, 18)
                if grouped {
                    ForEach(model.groups) { group in
                        let values = undated.filter { $0.category == group.id }
                        if !values.isEmpty {
                            Text(model.groupDisplayName(group.id)).font(font(12, .semibold, serif: true)).foregroundColor(DotistDesign.ink).padding(.top, 8)
                            unscheduledRows(values)
                        }
                    }
                } else { unscheduledRows(undated) }
            }
        }
    }
    private func ganttRows(_ values: [DotistTask]) -> some View {
        ForEach(Array(values.enumerated()), id: \.element.id) { index, task in
            GanttRowLayout {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 4) {
                        OpticalText(title: task.title, size: 14, weight: .semibold, language: model.language).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(TaskDragSource(model: model, task: task, scope: "scheduled", font: DotistDesign.nativeFont(14, weight: .semibold, language: model.language)).accessibilityHidden(true))
                        ViewTaskCard(model: model, task: task, previous: index > 0 ? values[index - 1].id : nil, next: index + 1 < values.count ? values[index + 1].id : nil, scope: "scheduled", compact: true, grouped: grouped, dropTarget: $dropTarget, dropAfter: $dropAfter).frame(width: 22)
                    }
                    let children = model.children(of: task)
                    if !children.isEmpty { Text(model.text("子任务 {done}/{total}").replacingOccurrences(of: "{done}", with: "\(children.filter(\.completed).count)").replacingOccurrences(of: "{total}", with: "\(children.count)")).font(font(12)) }
                    if task.dueDate.map({ $0 < Date().dotistDay }) == true && !task.completed { IconTextRow(spacing: 3) { OpticalSymbol(name: "exclamationmark.triangle", size: 10); OpticalText(title: model.text("已逾期"), size: 12, language: model.language) }.foregroundColor(DotistDesign.danger) }
                }.padding(8).frame(width: 220, alignment: .leading)
                    .background(GeometryReader { geometry in
                        Color.clear.onAppear { ganttLabelHeights[task.id] = geometry.size.height }.onChange(of: geometry.size.height) { ganttLabelHeights[task.id] = $0 }
                    })
                    .contentShape(Rectangle())
                    .onDrop(of: ["public.utf8-plain-text"], delegate: ViewReorderDrop(model: model, task: task, scope: "scheduled", grouped: grouped, height: ganttLabelHeights[task.id] ?? 56, target: $dropTarget, after: $dropAfter))
                GanttTrack(model: model, task: task, start: ganttStart, count: ganttCount)
            }.frame(minWidth: 600, minHeight: 56).overlay(Rectangle().fill(DotistDesign.rule).frame(height: 1), alignment: .bottom)
        }
    }
    private func unscheduledRows(_ values: [DotistTask]) -> some View {
        ForEach(Array(values.enumerated()), id: \.element.id) { index, task in
            ViewTaskCard(model: model, task: task, previous: index > 0 ? values[index - 1].id : nil, next: index + 1 < values.count ? values[index + 1].id : nil, scope: "unscheduled", grouped: grouped, dropTarget: $dropTarget, dropAfter: $dropAfter).frame(maxWidth: 400)
        }
    }
}

struct CalendarFocusModifier: ViewModifier {
    let date: String
    @Binding var keyboardDate: String?
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focusable(true).focused($focused).focusEffectDisabled()
            .onAppear { if keyboardDate == date { focused = true } }
            .onChange(of: keyboardDate) { _, value in if value == date { focused = true } }
    }
}

private struct ViewTaskCard: View {
    @ObservedObject var model: AppModel
    let task: DotistTask
    let previous: String?
    let next: String?
    let scope: String
    var compact = false
    var calendarColumn = false
    var grouped = false
    @Binding var dropTarget: String?
    @Binding var dropAfter: Bool
    @State private var open = false
    @State private var hovered = false
    @State private var height: CGFloat = 64

    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font { DotistDesign.textFont(size, weight: weight, language: model.language) }
    private var groupColor: Color { DotistDesign.muted }

    private var completionButton: some View {
        Button { model.complete(task) } label: {
            ZStack {
                Circle().stroke(task.completed ? DotistDesign.accent : DotistDesign.faint, lineWidth: 1.5)
                if task.completed { Circle().fill(DotistDesign.accent); OpticalSymbol(name: "checkmark", size: calendarColumn ? 8 : 10, weight: .bold).foregroundColor(.white) }
            }.frame(width: calendarColumn ? 14 : 18, height: calendarColumn ? 14 : 18).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(DotistFocusRing())
            .accessibilityLabel(Text(model.text(task.completed ? "恢复 {title}" : "完成 {title}").replacingOccurrences(of: "{title}", with: task.title)))
    }

    private var adjustmentButton: some View {
        Button { open = true } label: {
            OpticalSymbol(name: "ellipsis", size: 12, weight: .medium).frame(width: 18, height: 18).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(DotistFocusRing())
            .foregroundColor(hovered || open ? DotistDesign.ink : DotistDesign.faint)
            .accessibilityLabel(Text(model.text("调整任务") + " " + task.title))
            .help(model.text("调整任务"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: calendarColumn ? 6 : 8) {
            if calendarColumn {
                Button { open = true } label: {
                    Text(task.title).font(font(12)).foregroundColor(task.completed ? DotistDesign.faint : DotistDesign.ink)
                        .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).contentShape(Rectangle())
                        .overlay(TaskDragSource(model: model, task: task, scope: scope, font: DotistDesign.nativeFont(12, language: model.language), click: { open = true }).accessibilityHidden(true))
                }.buttonStyle(.plain).modifier(DotistFocusRing())
                HStack(alignment: .center, spacing: 4) {
                    completionButton
                    VStack(alignment: .leading, spacing: 2) {
                        OpticalText(title: model.group(for: task)?.name ?? "", size: 10, serif: true, language: model.language).foregroundColor(groupColor).lineLimit(1)
                        if task.parentId != nil { Text(model.text("子任务")).lineLimit(1) }
                    }.font(font(10)).foregroundColor(DotistDesign.muted).frame(maxWidth: .infinity, alignment: .leading)
                    adjustmentButton
                }
                if task.dueDate.map({ $0 < Date().dotistDay }) == true && !task.completed {
                    Text(model.text("已逾期")).font(font(10)).foregroundColor(DotistDesign.danger)
                }
            } else {
                HStack(alignment: .center, spacing: 7) {
                    if !compact {
                        completionButton
                        OpticalText(title: task.title, size: 14, language: model.language).foregroundColor(task.completed ? DotistDesign.faint : DotistDesign.ink).frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(TaskDragSource(model: model, task: task, scope: scope, font: DotistDesign.nativeFont(14, language: model.language)).accessibilityHidden(true))
                    } else { Spacer(minLength: 0) }
                    adjustmentButton
                }
                if !compact {
                    VStack(alignment: .leading, spacing: 3) {
                        OpticalText(title: model.group(for: task)?.name ?? "", size: 11, serif: true, language: model.language).foregroundColor(groupColor)
                        if task.parentId != nil { Text(model.text("子任务")) }
                        if let due = task.dueDate { Text(due) }
                        if task.dueDate.map({ $0 < Date().dotistDay }) == true && !task.completed {
                            Text(model.text("已逾期")).foregroundColor(DotistDesign.danger)
                        }
                        if scope == "board" {
                            let children = model.children(of: task)
                            if !children.isEmpty { Text(model.text("子任务 {done}/{total}").replacingOccurrences(of: "{done}", with: "\(children.filter(\.completed).count)").replacingOccurrences(of: "{total}", with: "\(children.count)")) }
                        }
                    }.font(font(12)).foregroundColor(DotistDesign.muted)
                }
            }
        }
        .padding(compact ? 0 : calendarColumn ? 6 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Color.clear : calendarColumn ? groupColor.opacity(0.07) : DotistDesign.surface)
        .cornerRadius(calendarColumn ? 6 : 8)
        .background(GeometryReader { geometry in
            Color.clear.onAppear { height = geometry.size.height }.onChange(of: geometry.size.height) { height = $0 }
        })
        .onHover { hovered = $0 }
        .focusable(true).modifier(DotistFocusRing())
        .onMoveCommand { direction in
            guard NSEvent.modifierFlags.contains(.option) else { return }
            if direction == .up, let previous { model.reorder(task.id, relativeTo: previous, after: false, allTasks: true) }
            if direction == .down, let next { model.reorder(task.id, relativeTo: next, after: true, allTasks: true) }
        }
        .onDrop(of: ["public.utf8-plain-text"], delegate: ViewReorderDrop(model: model, task: task, scope: scope, grouped: grouped, height: height, target: $dropTarget, after: $dropAfter))
        .contextMenu {
            Button(model.text("调整任务")) { open = true }
            Button(model.text("上移")) { if let previous { model.reorder(task.id, relativeTo: previous, after: false, allTasks: true) } }.disabled(previous == nil)
            Button(model.text("下移")) { if let next { model.reorder(task.id, relativeTo: next, after: true, allTasks: true) } }.disabled(next == nil)
        }
        .popover(isPresented: $open, arrowEdge: .trailing) { adjustments }
    }

    private var adjustments: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(task.title).font(font(14, .medium)).fixedSize(horizontal: false, vertical: true)
            Picker(model.text("状态"), selection: Binding(get: { task.status.rawValue }, set: { value in
                guard let status = TaskStatus(rawValue: value) else { return }
                model.change { _ = try $0.patchTask(id: task.id, status: status) }
            })) {
                Text(model.text("待办")).tag("todo")
                Text(model.text("进行中")).tag("doing")
                Text(model.text("完成")).tag("done")
            }.modifier(DotistFocusRing())
            TaskDateField(model: model, task: task, start: true)
            TaskDateField(model: model, task: task, start: false)
            HStack(spacing: 8) {
                Button(model.text("上移")) { if let previous { model.reorder(task.id, relativeTo: previous, after: false, allTasks: true) } }
                    .disabled(previous == nil).buttonStyle(DotistActionStyle()).modifier(DotistFocusRing())
                Button(model.text("下移")) { if let next { model.reorder(task.id, relativeTo: next, after: true, allTasks: true) } }
                    .disabled(next == nil).buttonStyle(DotistActionStyle()).modifier(DotistFocusRing())
                Spacer(minLength: 0)
                Button(model.text("完成")) { open = false }.buttonStyle(DotistActionStyle()).modifier(DotistFocusRing())
            }
        }.font(font(12)).modifier(DotistControlTint()).foregroundColor(DotistDesign.ink).padding(16).frame(width: 280)
    }
}

private struct TaskDateField: View {
    @ObservedObject var model: AppModel
    let task: DotistTask
    let start: Bool
    @State private var draft = ""
    @State private var base = ""
    @State private var conflict = false
    @State private var saving = false
    @State private var pendingSave: String?
    private var current: String {
        let latest = model.tasks.first { $0.id == task.id } ?? task
        return (start ? latest.startDate : latest.dueDate) ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.text(start ? "开始日" : "到期日"))
                TextField("YYYY-MM-DD", text: $draft, onCommit: save)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(DotistDesign.surface))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DotistDesign.rule, lineWidth: 0.5))
                    .modifier(DotistFocusRing())
                    .accessibilityLabel(Text(model.text(start ? "开始日" : "到期日")))
            }
            if conflict {
                Text(model.text("日期已被其他操作更新，请先确认当前值。")).foregroundColor(DotistDesign.danger)
                Button(model.text("使用最新日期")) { draft = current; base = current; conflict = false }.buttonStyle(DotistActionStyle()).modifier(DotistFocusRing())
            }
        }
        .onAppear { draft = current; base = current }
        .onChange(of: current) { value in
            if draft == base { draft = value; base = value }
        }
    }
    private func save() { submit(draft) }
    private func submit(_ requested: String) {
        guard !saving else { pendingSave = requested; return }
        guard current == base || requested == current else { conflict = true; return }
        if requested == current { base = current; conflict = false; return }
        let value = requested.isEmpty ? nil : requested
        saving = true
        model.change(completed: {
            base = value ?? ""; conflict = false; saving = false
            if let pending = pendingSave { pendingSave = nil; DispatchQueue.main.async { submit(pending) } }
        }, failed: { saving = false; pendingSave = nil }) { store in
            if start { _ = try store.setStartDate(task.id, date: value) } else { _ = try store.setDueDate(task.id, date: value) }
        }
    }
}

private struct DateDrop: DropDelegate {
    let model: AppModel
    let date: String
    func validateDrop(info: DropInfo) -> Bool { return true }
    func performDrop(info: DropInfo) -> Bool {
        guard let id = model.dragId, let task = model.tasks.first(where: { $0.id == id }) else { return false }
        model.endDrag()
        if task.dueDate == date { return true }
        model.change { _ = try $0.setDueDate(id, date: date) }
        return true
    }
}
private struct StatusDrop: DropDelegate {
    let model: AppModel
    let status: TaskStatus
    func performDrop(info: DropInfo) -> Bool {
        guard let id = model.dragId, let task = model.tasks.first(where: { $0.id == id }) else { return false }
        model.endDrag()
        if task.status == status { return true }
        model.change { _ = try $0.patchTask(id: id, status: status) }
        return true
    }
}
private struct ViewReorderDrop: DropDelegate {
    let model: AppModel
    let task: DotistTask
    let scope: String
    let grouped: Bool
    let height: CGFloat
    @Binding var target: String?
    @Binding var after: Bool
    private var allowed: Bool {
        guard let source = model.tasks.first(where: { $0.id == model.dragId }), source.id != task.id else { return false }
        if scope == "board" { return source.status == task.status }
        if scope == "date" { return source.dueDate == task.dueDate }
        guard source.parentId == nil && task.parentId == nil else { return false }
        if grouped && source.category != task.category { return false }
        return scope == "scheduled" ? (source.startDate != nil || source.dueDate != nil) : (source.startDate == nil && source.dueDate == nil)
    }
    func validateDrop(info: DropInfo) -> Bool { allowed }
    func dropEntered(info: DropInfo) { if allowed { target = task.id } }
    func dropExited(info: DropInfo) { if target == task.id { target = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { after = info.location.y >= height / 2; return DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard allowed, let id = model.dragId else { return false }
        model.endDrag(); target = nil
        model.reorder(id, relativeTo: task.id, after: info.location.y >= height / 2, allTasks: true)
        return true
    }
}

private struct GanttGroupTrack: View {
    let group: DotistGroup
    let tasks: [DotistTask]
    let start: Date
    let count: Int
    var body: some View {
        GeometryReader { geometry in
            let calendar = Calendar(identifier: .gregorian)
            let width = geometry.size.width / CGFloat(count)
            let starts = tasks.compactMap { Date.dotistDay($0.startDate ?? $0.dueDate ?? "") }
            let ends = tasks.compactMap { Date.dotistDay($0.dueDate ?? $0.startDate ?? "") }
            let first = starts.min().map { calendar.dateComponents([.day], from: start, to: $0).day ?? 0 } ?? 0
            let last = ends.max().map { calendar.dateComponents([.day], from: start, to: $0).day ?? 0 } ?? -1
            let left = max(0, first)
            let right = min(count, last + 1)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) { ForEach(0..<count, id: \.self) { _ in Rectangle().fill(Color.clear).frame(width: width).overlay(Rectangle().fill(DotistDesign.rule).frame(width: 1), alignment: .trailing) } }
                if right > left {
                    RoundedRectangle(cornerRadius: 1).fill(DotistDesign.accent.opacity(0.8)).frame(width: CGFloat(right - left) * width, height: 5).offset(x: CGFloat(left) * width)
                }
            }
        }.frame(height: 38)
    }
}

private struct GanttTrack: View {
    @ObservedObject var model: AppModel
    let task: DotistTask
    let start: Date
    let count: Int
    @State private var preview = 0
    @State private var edge = "move"
    @State private var dragging = false
    @State private var saving = false
    private var calendar: Calendar { Calendar(identifier: .gregorian) }
    private func distance(_ date: Date) -> Int { calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: date)).day ?? 0 }
    private func shift(_ value: String?, days: Int) -> String? {
        guard let value, let date = Date.dotistDay(value) else { return nil }
        return calendar.date(byAdding: .day, value: days, to: date)?.dotistDay
    }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width / CGFloat(count)
            let first = Date.dotistDay(task.startDate ?? task.dueDate!)!
            let last = Date.dotistDay(task.dueDate ?? task.startDate!)!
            let begin = distance(first) + (edge == "end" ? 0 : preview)
            let end = distance(last) + (edge == "start" ? 0 : preview)
            let left = dragging ? min(count - 1, max(0, begin)) : max(0, begin)
            let right = dragging ? max(left + 1, min(count, end + 1)) : min(count, end + 1)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) { ForEach(0..<count, id: \.self) { _ in Rectangle().fill(Color.clear).frame(width: width).overlay(Rectangle().fill(DotistDesign.rule).frame(width: 1), alignment: .trailing) } }
                let today = distance(Date())
                if today >= 0 && today < count {
                    Rectangle().fill(DotistDesign.accent.opacity(0.75)).frame(width: 1).offset(x: (CGFloat(today) + 0.5) * width)
                }
                if right > left {
                    RoundedRectangle(cornerRadius: 6).fill(DotistDesign.accent.opacity(task.completed ? 0.45 : 0.8))
                        .frame(width: max(8, CGFloat(right - left) * width), height: 20)
                        .overlay(GanttPointer(changed: { startX, translation in
                            guard !saving else { return }
                            if !dragging {
                                let barWidth = CGFloat(right - left) * width
                                edge = task.startDate != nil && distance(first) >= 0 && startX < min(8, barWidth / 2) ? "start" : task.dueDate != nil && distance(last) < count && startX > barWidth - min(8, barWidth / 2) ? "end" : "move"
                                dragging = true
                            }
                            preview = Int((translation / width).rounded())
                        }, ended: { cancelled in
                            guard !saving else { return }
                            if cancelled { preview = 0; edge = "move"; dragging = false; return }
                            let delta = preview
                            let start = edge == "end" ? task.startDate : shift(task.startDate, days: delta)
                            let due = edge == "start" ? task.dueDate : shift(task.dueDate, days: delta)
                            let finish = { preview = 0; edge = "move"; dragging = false; saving = false }
                            guard delta != 0 else { finish(); return }
                            saving = true
                            model.change(completed: finish, failed: finish) { _ = try $0.setDateRange(task.id, start: start, due: due) }
                        }).accessibilityHidden(true))
                        .offset(x: CGFloat(left) * width)
                }
            }
        }.frame(minHeight: 56).focusable(true).modifier(DotistFocusRing())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(model.text("甘特任务 {title}").replacingOccurrences(of: "{title}", with: task.title)))
        .onMoveCommand { direction in
            guard direction == .left || direction == .right else { return }
            let delta = direction == .left ? -1 : 1
            let adjustEnd = NSEvent.modifierFlags.contains(.shift)
            let first = adjustEnd ? task.startDate : shift(task.startDate, days: delta)
            let last = shift(task.dueDate, days: delta)
            model.change { _ = try $0.setDateRange(task.id, start: first, due: last) }
        }
    }
}

private struct GanttPointer: NSViewRepresentable {
    let changed: (CGFloat, CGFloat) -> Void
    let ended: (Bool) -> Void
    func makeNSView(context: Context) -> GanttPointerView { GanttPointerView() }
    func updateNSView(_ view: GanttPointerView, context: Context) { view.changed = changed; view.ended = ended }
}

private final class GanttPointerView: NSView {
    var changed: (CGFloat, CGFloat) -> Void = { _, _ in }
    var ended: (Bool) -> Void = { _ in }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startX = convert(event.locationInWindow, from: nil).x
        let origin = event.locationInWindow.x
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            if next.type == .leftMouseDragged { changed(startX, next.locationInWindow.x - origin) }
            else if next.type == .leftMouseUp { ended(false); return }
            else if next.keyCode == 53 { ended(true); return }
            else { NSApp.sendEvent(next) }
        }
    }
}
