import AppKit
import Combine
import DotistCore
import SwiftUI

extension MainWindow {
    private var sortableToolbarItems: [ToolbarItem] {
        toolbarConfig.order.filter { $0 != .collapse && $0 != .completion && $0 != .calendar && toolbarConfig.visibility(of: $0) != .hidden }
    }

    var windowToolbarItems: [ToolbarItem] {
        sortableToolbarItems
    }

    func reorderItems(for item: ToolbarItem) -> [ToolbarItem] {
        windowToolbarItems
    }

    private var toolbarAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.16)
    }

    var header: some View {
        HeaderClusterLayout(reservedWindowWidth: CGFloat(windowToolbarItems.count + (!primary && close != nil ? 1 : 0)) * 25 + 1) {
            Group { if !primary { groupSelector } else { Color.clear.frame(width: 0, height: 24) } }
            Color.clear.frame(width: 0, height: 24)
            headerCluster {
                ForEach(windowToolbarItems, id: \.self) { item in configuredHeaderControl(item) }
                if !primary, let close { toolbarButton("xmark", label: model.text("关闭面板"), action: close) }
                toolbarItem(.collapse)
            }
        }.padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10).background(WindowDragArea())
            .overlayPreferenceValue(HeaderColorAnchorKey.self) { anchors in
                GeometryReader { geometry in
                    let anchor = anchors[.color]
                    if let anchor {
                        let rect = geometry[anchor]
                        Color.clear.frame(width: rect.width, height: rect.height)
                            .popover(isPresented: popoverBinding(.color)) { colorPicker }
                            .position(x: rect.midX, y: rect.midY)
                    }
                }.allowsHitTesting(false)
            }
    }

    private func controlVisible(_ item: ToolbarItem) -> Bool {
        toolbarConfig.visibility(of: item) == .always || panelHovered || isActive(item)
    }

    private func configuredHeaderControl(_ item: ToolbarItem) -> some View {
        headerControl(item)
            .opacity(controlVisible(item) || toolbarDrag != nil ? 1 : 0)
            .allowsHitTesting(controlVisible(item))
            .accessibilityHidden(!controlVisible(item))
            .offset(x: toolbarDrag?.offset(for: item) ?? 0)
            .zIndex(toolbarDrag?.item == item ? 1 : 0)
            .animation(toolbarDrag?.item == item ? nil : toolbarAnimation, value: toolbarDrag?.target)
            .animation(toolbarAnimation, value: panelHovered)
            .highPriorityGesture(toolbarReorderGesture(item, items: reorderItems(for: item)))
    }

    private func headerCluster<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 1, content: content).padding(1)
            .background(RoundedRectangle(cornerRadius: 9).fill(DotistDesign.rule.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(DotistDesign.rule.opacity(0.14), lineWidth: 0.5))
    }

    /// A control whose state differs from the default stays visible even when hover-only.
    private func isActive(_ item: ToolbarItem) -> Bool {
        switch item {
        // Active inline dates remain visible when their configured policy is hover-only.
        case .filter: filterPresentation.isOpen || showCalendar || dateFilterActive
        case .filters: showFilters
        case .completion: hideCompleted
        case .calendar: showCalendar || customStart != nil
        case .color: showColorPicker
        default: false
        }
    }

    @ViewBuilder private func headerControl(_ item: ToolbarItem) -> some View {
        switch item {
        case .filter: filterButton.background(frameReporter(item))
        case .filters: unifiedFilterButton.background(frameReporter(item))
        case .completion: EmptyView()
        case .calendar: calendarButton.background(frameReporter(item))
        default: toolbarItem(item)
        }
    }

    private func frameReporter(_ item: ToolbarItem) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ToolbarFrameKey.self, value: [item: geometry.frame(in: .named(Self.listSpace))])
        }
    }

    private func toolbarReorderGesture(_ item: ToolbarItem, items: [ToolbarItem]) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.listSpace))
            .updating($toolbarGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard item != .collapse else { return }
                if toolbarDrag == nil {
                    guard (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.command) else { return }
                    toolbarDrag = ToolbarDragSession(item: item, items: items, frames: toolbarFrames)
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

    private func toolbarSymbol(_ item: ToolbarItem) -> String {
        switch item {
        case .filters, .filter, .completion, .calendar: ""
        case .views: "rectangle.split.2x1"
        case .pin: model.settings.alwaysOnTop ? "pin.fill" : "pin"
        case .lock: model.settings.locked ? "lock.fill" : "lock.open"
        case .color: "circle"
        case .collapse: "arrow.down.right.and.arrow.up.left"
        }
    }

    private func toolbarLabel(_ item: ToolbarItem) -> String {
        switch item {
        case .filters, .filter, .completion, .calendar: ""
        case .views: "任务视图"
        case .pin: "置顶窗口"
        case .lock: "固定窗口"
        case .color: "颜色"
        case .collapse: "收起为悬浮球"
        }
    }

    func performToolbarAction(_ item: ToolbarItem) {
            guard toolbarDrag == nil else { return }
            switch item {
            case .filters, .filter, .completion, .calendar: break
            case .views: showViews()
            case .color: showColorPicker.toggle()
            case .collapse: collapse()
            case .pin: var patch = DotistSettingsPatch(); patch.alwaysOnTop = !model.settings.alwaysOnTop; model.updateSettings(patch)
            case .lock: var patch = DotistSettingsPatch(); patch.locked = !model.settings.locked; model.updateSettings(patch)
            }
    }

    private func toolbarItem(_ item: ToolbarItem) -> some View {
        let label = model.text(toolbarLabel(item))
        return Button { performToolbarAction(item) } label: {
            Group {
                if item == .color {
                    let color = state.selectedColor(in: model)
                    Circle().fill(color == .none ? Color.clear : DotistTheme.swatch(color))
                        .overlay { if color == .none { Circle().strokeBorder(DotistDesign.faint, lineWidth: 1) } }
                        .frame(width: 14, height: 14)
                } else { OpticalSymbol(name: toolbarSymbol(item), size: 14) }
            }.frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(HeaderToolStyle()).modifier(DotistFocusRing()).foregroundColor(DotistDesign.muted)
            .anchorPreference(key: HeaderColorAnchorKey.self, value: .bounds) { item == .color ? [.color: $0] : [:] }
            .help(label).accessibilityLabel(Text(label)).accessibilityIdentifier("toolbar:\(item.rawValue)")
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
            return HeaderDateLabel.full(start: start, end: end, language: model.language)
        }
        return model.text(filterLabel(state.scope))
    }

    private var dateFilterActive: Bool { state.dateFilterActive }

    private var filterButton: some View {
        inlineDateControl(symbol: "calendar", active: dateFilterActive,
                          title: customStart != nil ? HeaderDateLabel.compact(start: customStart, end: customEnd) : model.text(filterLabel(state.scope)), identifier: "date-filter-current", action: filterPresentation.toggle)
            .animation(DateFilterSelectionMotion.animation(reduceMotion: reduceMotion), value: dateFilterActive || filterPresentation.isOpen)
    }

    func clearDateFilter() { state.scope = "all"; customStart = nil; customEnd = nil }

    private func inlineDateControl(symbol: String, active: Bool, title: String, identifier: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Button(action: action) {
                HStack(spacing: 4) {
                    OpticalSymbol(name: symbol, size: 14).frame(width: 14, height: 24)
                    if active {
                        Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            .frame(width: min(66, ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium)]).width)))
                    }
                }.frame(height: 24).frame(minWidth: active ? nil : 24).contentShape(Rectangle())
            }.buttonStyle(HeaderToolStyle()).modifier(DotistFocusRing())
                .accessibilityIdentifier(identifier).accessibilityLabel(Text(model.text(identifier == "date-filter-current" ? "日期筛选" : "日历")))
                .accessibilityValue(Text(active ? currentScopeLabel : model.text("全部")))
            if active && identifier == "date-filter-current" {
                Button(action: clearDateFilter) { OpticalSymbol(name: "xmark", size: 9).frame(width: 14, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(HeaderToolStyle()).modifier(DotistFocusRing())
                    .accessibilityLabel(Text(model.text("取消：") + currentScopeLabel)).accessibilityIdentifier(identifier + ":clear")
            }
        }.padding(.horizontal, active ? 6 : 0)
            .foregroundStyle(active ? DotistDesign.accent : DotistDesign.muted)
            .background(RoundedRectangle(cornerRadius: 8).fill(DotistDesign.accent.opacity(active ? 0.12 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DotistDesign.accent.opacity(active ? 0.25 : 0), lineWidth: 0.5).allowsHitTesting(false))
            .help(currentScopeLabel)
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
                calendarButton
            }.padding(.horizontal, DateFilterEdgeMask.contentInset)
        }.focusSection().frame(height: TaskDateFilterMetrics.rowHeight)
            .mask { DateFilterEdgeMask() }
            .dotistGlass(.regular.tint(DotistTheme.tint(model.themeColor(forGroup: state.groupID), scheme)), in: RoundedRectangle(cornerRadius: 12)).dotistInlineShadow()
            .background(DateFilterHoverObserver(enabled: filterPresentation.isOpen, changed: filterPresentation.hoverChanged))
            .padding(.horizontal, TaskRowMetrics.inset)
            .allowsHitTesting(filterPresentation.isOpen)
    }

    private var calendarButton: some View {
        inlineDateControl(symbol: "calendar", active: true,
                          title: customStart != nil ? HeaderDateLabel.compact(start: customStart, end: customEnd) : model.text("自定义…"), identifier: "toolbar:calendar", action: { showCalendar.toggle() })
            .popover(isPresented: popoverBinding(.calendar)) {
                RangeCalendar(model: model, start: customStart ?? Date().dotistDay, end: customEnd ?? Date().dotistDay, choose: { start, end in
                    state.scope = "today"
                    customStart = start
                    customEnd = end
                }, close: { showCalendar = false })
            }
    }

    private func toolbarButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { OpticalSymbol(name: symbol, size: 14).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(HeaderToolStyle()).modifier(DotistFocusRing()).foregroundColor(DotistDesign.muted).help(label).accessibilityLabel(Text(label)).accessibilityIdentifier("toolbar:close")
    }

    var tagBar: some View {
        HStack {
            Menu {
                Button(model.text("全部")) { state.activeTag = nil }
                ForEach(model.orderedTagCounts) { tag in
                    Button {
                        state.activeTag = tag.tag
                    } label: {
                        if state.activeTag == tag.tag { Label("#" + tag.tag, systemImage: "checkmark") }
                        else { Text("#" + tag.tag) }
                    }
                }
                Divider()
                Button(model.text("管理…")) { headerPopover = nil; manageTags = true }
            } label: {
                Text(model.text("标签") + ": " + (state.activeTag.map { "#" + $0 } ?? model.text("全部")))
                    .lineLimit(1).frame(height: 28)
            }.menuStyle(.borderlessButton).modifier(DotistFocusRing()).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tag-filter")
            Spacer(minLength: 0)
            if state.activeTag != nil {
                Button { state.activeTag = nil } label: {
                    OpticalSymbol(name: "xmark", size: 11).frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(Text(model.text("全部")))
            }
        }.font(font(12)).foregroundStyle(DotistDesign.muted).padding(.horizontal, 16).frame(height: 28)
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

    var additionalFilterCount: Int {
        (state.activeTag != nil ? 1 : 0) + (hideCompleted ? 1 : 0)
    }

    func clearAdditionalFilters() {
        state.activeTag = nil
        hideCompleted = false
    }

    private var groupSelector: some View {
        let title = model.groups.first { $0.id == state.groupID }?.name ?? model.text("全部")
        return HeaderMenuButton(title: title, symbol: "", identifier: "filter-group", accessibilityTitle: model.text("分组") + ": " + title) {
            let menu = NSMenu()
            let all = HeaderMenuAction(title: model.text("全部")) { state.groupID = nil }
            all.state = state.groupID == nil ? .on : .off
            menu.addItem(all)
            for group in model.visibleGroups {
                let entry = HeaderMenuAction(title: group.name) { state.groupID = group.id }
                entry.state = state.groupID == group.id ? .on : .off
                menu.addItem(entry)
            }
            return menu
        }.frame(maxWidth: 136).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8).fill(DotistDesign.rule.opacity(0.06)))
    }

    private var unifiedFilterButton: some View {
        Button { showFilters.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")

            }.frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(HeaderToolStyle()).modifier(DotistFocusRing())
            .background(RoundedRectangle(cornerRadius: 8).fill(DotistDesign.rule.opacity(0.06)))
            .foregroundStyle(additionalFilterCount > 0 || showFilters ? DotistDesign.accent : DotistDesign.muted)
            .accessibilityLabel(Text(model.text("筛选")))
            .accessibilityValue(Text("\(additionalFilterCount)"))
            .accessibilityIdentifier("unified-filter")
            .popover(isPresented: Binding(get: { showFilters }, set: { showFilters = $0 })) { unifiedFilterPanel }
    }

    var unifiedFilterPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.text("筛选")).font(font(15, .semibold))
                Spacer()
                Button(model.text("清除附加条件"), action: clearAdditionalFilters)
                    .buttonStyle(.plain).modifier(DotistFocusRing())
                    .foregroundStyle(DotistDesign.accent).disabled(additionalFilterCount == 0)
            }
            additionalFilterLine
            tagBar.padding(.horizontal, -16)
            Toggle(model.text("只看未完成"), isOn: Binding(get: { hideCompleted }, set: { hideCompleted = $0 }))
                .accessibilityIdentifier("completion-filter")
        }.font(font(12)).padding(16).frame(width: 300)

    }

    private func filterChip(_ title: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 5) { Text(title).lineLimit(1); Image(systemName: "xmark").font(.system(size: 9)) }
                .padding(.horizontal, 8).frame(height: 25)
                .background(Capsule().fill(DotistDesign.rule.opacity(0.06)))
                .overlay(Capsule().strokeBorder(DotistDesign.rule.opacity(0.16), lineWidth: 0.5))
        }.buttonStyle(.plain).modifier(DotistFocusRing())
            .help((model.text("取消：")) + title)
    }

    @ViewBuilder var additionalFilterLine: some View {
        if additionalFilterCount > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let tag = state.activeTag { filterChip("#" + tag) { state.activeTag = nil } }
                    if hideCompleted { filterChip(model.text("只看未完成")) { hideCompleted = false } }
                }.padding(.horizontal, 16)
            }.frame(height: 33).font(font(11)).accessibilityIdentifier("active-filter-line")
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

enum HeaderDateLabel {
    static func full(start: String, end: String, language: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMd")
        func label(_ day: String) -> String { Date.dotistDay(day).map(formatter.string(from:)) ?? day }
        return start == end ? label(start) : label(start) + " – " + label(end)
    }

    static func compact(start: String?, end: String?) -> String {
        guard let start else { return "" }
        let end = end ?? start
        let a = start.split(separator: "-").map(String.init)
        let b = end.split(separator: "-").map(String.init)
        guard a.count == 3, b.count == 3 else { return start == end ? start : start + "–" + end }
        func md(_ p: [String]) -> String { String(Int(p[1]) ?? 0) + "/" + String(Int(p[2]) ?? 0) }
        if start == end { return md(a) }
        if a[0] != b[0] { return String(a[0].suffix(2)) + "/" + a[1] + "/" + a[2] + "–" + String(b[0].suffix(2)) + "/" + b[1] + "/" + b[2] }
        if a[1] == b[1] { return md(a) + "–" + String(Int(b[2]) ?? 0) }
        return md(a) + "–" + md(b)
    }
}
