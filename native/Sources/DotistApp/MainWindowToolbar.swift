import AppKit
import Combine
import DotistCore
import SwiftUI

extension MainWindow {
    private var sortableToolbarItems: [ToolbarItem] {
        toolbarConfig.order.filter { $0 != .collapse && toolbarConfig.visibility(of: $0) != .hidden }
    }

    private var toolbarAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.16)
    }

    var header: some View {
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
    var activeFilterLine: some View {
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

    var filterStrip: some View {
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
            .dotistGlass(.regular, in: RoundedRectangle(cornerRadius: 12)).dotistInlineShadow()
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

    var tagBar: some View {
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

    var dropGroupIDs: [String] { [DotistGroup.inboxID] + model.visibleGroups.map(\.id) }

    var groupCollapseAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.16)
    }

    private func toggleGroup(_ id: String) {
        leaveInputs()
        withAnimation(groupCollapseAnimation) { state.setGroupCollapsed(!state.collapsedGroups.contains(id), id: id) }
    }

    func groupHeader(_ group: DotistGroup, empty: Bool, after task: DotistTask?, region: String? = nil) -> some View {
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

    var customDateRange: TaskDateRange? {
        customStart.map { TaskDateRange($0, customEnd ?? $0) }
    }

    var rangeBounds: (String, String) {
        let range = customDateRange ?? model.dateFilterRange(scope: state.scope)
        return (range.start, range.end)
    }

    func dateFilterResult(completed: Bool = false, range: TaskDateRange? = nil) -> TaskFilterResult {
        model.filteredTasks(scope: state.scope, groupID: state.groupID, tag: state.activeTag,
                            customRange: range ?? customDateRange, completed: completed)
    }

}
