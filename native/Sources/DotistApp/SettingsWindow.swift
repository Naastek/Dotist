import AppKit
import DotistCore
import SwiftUI

struct SettingsWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: NativeUpdater
    let beginShortcutCapture: () -> Void
    let endShortcutCapture: (UInt32, String?) -> Void
    let resetWindowSize: () -> Void
    @ObservedObject private var toolbar = ToolbarConfig.shared
    @State private var active = SettingsModule.appearance
    @State private var query = ""
    @State private var searchTarget: String?
    @State private var searchRequest = UUID()
    @State private var emphasized: String?
    @State private var manager: Manager?
    @State private var draggedToolbarItem: ToolbarItem?
    @State private var toolbarTranslation: CGFloat = 0
    private enum Manager: String, Identifiable { case tags, groups; var id: String { rawValue } }
    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> Font {
        DotistDesign.font(size, weight: weight, serif: serif, language: model.language)
    }
    private func update(_ change: (inout DotistSettingsPatch) -> Void) {
        var patch = DotistSettingsPatch(); change(&patch); model.updateSettings(patch)
    }
    private var searchResults: [SettingsSearchEntry] {
        SettingsSearchIndex.matches(query, in: SettingsSearchIndex.entries + model.visibleGroups.map {
            SettingsSearchIndex.groupEntry(id: $0.id, name: $0.name)
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Text(model.text(error)).font(font(12)).foregroundStyle(DotistDesign.danger)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(DotistDesign.rule).frame(width: 0.5)
                detail
            }
        }.font(font(13)).foregroundStyle(DotistDesign.ink).controlSize(.small)
            .background(WindowDragArea()).modifier(DotistTheme(theme: model.settings.theme))
            .frame(minWidth: 800, minHeight: 540)
            .sheet(item: $manager) { current in
                Group {
                    switch current {
                    case .groups: GroupManager(model: model, close: { manager = nil }, tags: { manager = .tags })
                    case .tags: TagManager(model: model, close: { manager = nil }, groups: { manager = .groups }, select: { _ in })
                    }
                }.frame(minWidth: 420, minHeight: 400)
            }
    }
    private var sidebar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(DotistDesign.muted).accessibilityHidden(true)
                TextField(model.text("搜索设置"), text: $query).textFieldStyle(.plain)
                    .accessibilityIdentifier("settings-search")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark").font(font(10)).frame(width: 18, height: 22)
                    }.buttonStyle(.plain).accessibilityLabel(model.text("清除"))
                }
            }.padding(.horizontal, 11).frame(height: 34).glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 12)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(SettingsModule.allCases) { module in
                            Button {
                                active = module; searchTarget = nil; emphasized = nil; searchRequest = UUID()
                            } label: {
                                HStack(spacing: 10) {
                                    SettingsModuleIcon(module: module, language: model.language)
                                    Text(model.text(module.title)).font(font(13, active == module ? .semibold : .regular))
                                        .foregroundStyle(active == module ? DotistDesign.accent : DotistDesign.ink)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 15).frame(height: 38).contentShape(Rectangle())
                            }.buttonStyle(.plain).modifier(DotistFocusRing())
                                .accessibilityAddTraits(active == module ? .isSelected : [])
                                .accessibilityIdentifier("settings-module-" + module.rawValue)
                        }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if searchResults.isEmpty {
                            Text(model.text("没有匹配的设置")).font(font(12)).foregroundStyle(DotistDesign.muted).padding(12)
                        }
                        ForEach(searchResults) { result in
                            Button {
                                active = result.module
                                searchTarget = result.target
                                searchRequest = UUID()
                            } label: {
                                HStack(alignment: .center, spacing: 9) {
                                    SettingsModuleIcon(module: result.module, language: model.language)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.text(result.title)).font(font(12, searchTarget == result.target ? .semibold : .regular))
                                            .foregroundStyle(searchTarget == result.target ? DotistDesign.accent : DotistDesign.ink)
                                        Text(model.text(result.module.title)).font(font(11)).foregroundStyle(DotistDesign.muted)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 12).padding(.vertical, 5).contentShape(Rectangle())
                            }.buttonStyle(.plain).modifier(DotistFocusRing())
                                .accessibilityIdentifier("settings-result-" + result.target)
                        }
                    }
                }.accessibilityIdentifier("settings-search-results")
            }
        }.padding(.top, 46).frame(width: 214).frame(maxHeight: .infinity)
            .background(.bar)
    }
    private var detail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(model.text(active.title)).font(font(23, .semibold))
                        .accessibilityAddTraits(.isHeader)
                    moduleContent
                }.padding(.horizontal, 26).padding(.top, 46).padding(.bottom, 32)
                    .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
                    .id(active)
            }.background(DotistDesign.paper)
                .task(id: searchRequest) {
                    guard let target = searchTarget else { return }
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center); emphasized = target }
                    do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { return }
                    withAnimation(.easeOut(duration: 0.2)) { emphasized = nil }
                }
                .onChange(of: active) { _, _ in
                    if searchTarget == nil { proxy.scrollTo(active, anchor: .top) }
                }
        }
    }
    @ViewBuilder private var moduleContent: some View {
        switch active {
        case .appearance: appearance
        case .general: general
        case .filters: filters
        case .menubar: menubar
        case .toolbar: toolbarSettings
        case .shortcuts: shortcuts
        case .mcp: MCPSettings(model: model, service: model.mcp, emphasized: emphasized)
        case .data: data
        case .about: about
        }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsGroup("外观") {
                settingRow("主题") {
                    SettingsSegmentedPicker(selection: Binding(get: { model.settings.theme }, set: { value in update { $0.theme = value } }),
                                          options: [("system", model.text("跟随系统")), ("light", model.text("浅色")), ("dark", model.text("深色"))],
                                          label: model.text("主题"), language: model.language).frame(width: 244, height: 24)
                }
                settingRow("玻璃预设") {
                    SettingsSegmentedPicker(selection: Binding(get: { glassPreset }, set: { value in
                        let preset = value == "clear" ? (UInt8(38), UInt8(22)) : value == "ultra" ? (UInt8(8), UInt8(4)) : (UInt8(60), UInt8(40))
                        update { $0.opacity = preset.0; $0.frost = preset.1 }
                    }), options: [("standard", model.text("标准")), ("clear", model.text("透明玻璃")), ("ultra", model.text("极致通透"))],
                        label: model.text("玻璃预设"), language: model.language).frame(width: 244, height: 24)
                }
                settingRow("透明程度") {
                    Slider(value: Binding(get: { transparency }, set: { value in update { $0.opacity = UInt8((95 - 91 * pow(value / 100, 1.5)).rounded()) } }), in: 0...100).frame(width: 110).modifier(DotistFocusRing())
                    numericValue("\(Int(transparency.rounded()))%")
                }
                numberRow("磨砂程度", value: Double(model.settings.frost), range: 0...100, unit: "%") { $0.frost = UInt8($1.rounded()) }
            }
            settingsGroup("颜色主题", footer: "分组未设置颜色时使用‘全部’的默认颜色") {
                settingRow("全部(默认颜色)") {
                    SettingsColorPalette(model: model, selected: DotistGroupColor(rawValue: model.settings.allColor), identifier: "settings-all-color") { color in
                        update { $0.allColor = color.rawValue }
                    }
                }
                ForEach(model.visibleGroups) { group in
                    SettingsFormRow(title: group.name, language: model.language, emphasized: emphasized == "appearance.color-" + group.id, serif: true) {
                        SettingsColorPalette(model: model, selected: DotistGroupColor(rawValue: group.color), identifier: "settings-group-color-" + group.id) { model.setGroupColor(group.id, $0) }
                    }.id("appearance.color-" + group.id)
                }
            }
            settingsGroup("失焦淡出") {
                boolRow("失焦淡出", value: model.settings.idleFade) { $0.idleFade = $1 }
                numberRow("淡出前等待", value: Double(model.settings.idleDelaySecs), range: 1...60) { $0.idleDelaySecs = UInt8($1.rounded()) }
                numberRow("淡出用时", value: Double(model.settings.idleFadeSecs), range: 1...10) { $0.idleFadeSecs = UInt8($1.rounded()) }
                numberRow("淡出后的不透明度", value: Double(model.settings.idleOpacity), range: 20...95, unit: "%") { $0.idleOpacity = UInt8($1.rounded()) }
            }
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsGroup("通用") {
                settingRow("语言") {
                    settingMenu("语言", value: model.settings.language, options: [("system", model.text("跟随系统")), ("zh-CN", "简体中文"), ("zh-TW", "繁體中文"), ("en", "English"), ("ja", "日本語")]) { value in update { $0.language = value } }
                }
                boolRow("显示在 Dock", value: model.settings.showDock) { $0.showDock = $1 }
                boolRow("显示在菜单栏", value: model.settings.showMenubar) { $0.showMenubar = $1 }
                settingRow("开机启动") {
                    Toggle(model.text("开机启动"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(DotistDesign.accent).modifier(DotistFocusRing())
                }
            }
            settingsGroup("窗口大小") {
                settingRow("窗口大小") { Button(model.text("恢复默认"), action: resetWindowSize) }
                boolRow("固定窗口", value: model.settings.locked) { $0.locked = $1 }
                boolRow("窗口置顶", value: model.settings.alwaysOnTop) { $0.alwaysOnTop = $1 }
                boolRow("悬停显示详情", value: model.settings.hoverExpand) { $0.hoverExpand = $1 }
                boolRow("自动收起", value: model.settings.autoCollapse) { $0.autoCollapse = $1 }
                numberRow("收起等待时间", value: Double(model.settings.autoCollapseSecs), range: 5...120) { $0.autoCollapseSecs = UInt16($1.rounded()) }
            }
            settingsGroup("管理") {
                settingRow("分组") { Button(model.text("管理分组…")) { manager = .groups } }
                settingRow("标签") { Button(model.text("管理标签…")) { manager = .tags } }
            }
        }
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsGroup("启动时打开") {
                settingRow("启动时打开") {
                    settingMenu("启动时打开", value: model.settings.defaultFilter, options: model.settings.filters.map { ($0, model.text(filterLabel($0))) }) { value in update { $0.defaultFilter = value } }
                }
            }
            settingsGroup("筛选器", footer: "主窗口顶部的筛选条可以左右滑动。在这里选择显示哪些，拖动手柄调整顺序。") {
                List {
                    ForEach(model.settings.filters, id: \.self) { id in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(DotistDesign.faint).accessibilityHidden(true)
                            Text(model.text(filterLabel(id)))
                            Spacer()
                            Button { setFilter(id, enabled: false) } label: { Image(systemName: "xmark").frame(width: 20, height: 20) }
                                .buttonStyle(.plain).modifier(DotistFocusRing()).disabled(model.settings.filters.count == 1)
                                .accessibilityLabel(Text(model.text("清除") + " " + model.text(filterLabel(id))))
                        }.frame(height: 44).contentShape(Rectangle())
                            .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                            .listRowBackground(Color.clear)
                    }.onMove { source, destination in
                        var values = model.settings.filters; values.move(fromOffsets: source, toOffset: destination)
                        update { $0.filters = values }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 44)
                    .frame(height: CGFloat(model.settings.filters.count * 44 + 4))
                    .accessibilityIdentifier("settings-filter-order")
                ForEach(["today", "all", "tomorrow", "week", "nextweek", "next7", "overdue", "undated", "done"].filter { !model.settings.filters.contains($0) }, id: \.self) { id in
                    HStack {
                        Button("+ " + model.text(filterLabel(id))) { setFilter(id, enabled: true) }
                        Spacer()
                    }.padding(.horizontal, 14).frame(height: 44)
                }
            }.id(rowID("筛选器"))
        }
    }
    private var menubar: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsGroup("显示内容") {
                settingRow("显示内容") {
                    settingMenu("显示内容", value: model.settings.trayMode, options: [("icon", model.text("仅图标")), ("count", model.text("剩余数字")), ("next", model.text("下一个任务")), ("next_date", model.text("下一个任务与日期")), ("rotate", model.text("轮播：数字与最近的任务"))]) { value in update { $0.trayMode = value } }
                }
                settingRow("日期透视") {
                    settingMenu("日期透视", value: model.settings.trayFilter, options: ["today", "all", "tomorrow", "week", "nextweek", "next7", "overdue", "undated", "done"].map { ($0, model.text(filterLabel($0))) }) { value in update { $0.trayFilter = value } }
                }
                settingRow("分组") {
                    settingMenu("分组", value: model.settings.trayGroup == "all" || model.groups.contains(where: { $0.id == model.settings.trayGroup }) ? model.settings.trayGroup : "all", options: [("all", model.text("全部分组"))] + model.groups.map { ($0.id, $0.name) }) { value in update { $0.trayGroup = value } }
                }
                numberRow("轮播间隔", value: Double(model.settings.trayRotateSecs), range: 2...30) { $0.trayRotateSecs = UInt16($1.rounded()) }
            }
            settingsGroup("菜单栏") {
                clickRow("左键点击", value: model.settings.trayLeftClick) { $0.trayLeftClick = $1 }
                clickRow("右键点击", value: model.settings.trayRightClick) { $0.trayRightClick = $1 }
            }
        }
    }
    private var orderedToolbarItems: [ToolbarItem] {
        toolbar.order.filter { ToolbarItem.allCases.contains($0) } + ToolbarItem.allCases.filter { !toolbar.order.contains($0) }
    }
    private var toolbarSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsGroup("工具栏", footer: "在面板上按住 ⌘ 可以左右拖动图标调整顺序") {
                ForEach(orderedToolbarItems, id: \.self) { item in
                    toolbarRow(item)
                }
            }.accessibilityIdentifier("settings-toolbar-order")
            settingRow("恢复默认") { Button(model.text("恢复默认")) { toolbar.reset() } }
        }
    }
    private func toolbarRow(_ item: ToolbarItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(font(13))
                .foregroundStyle(draggedToolbarItem == item ? DotistDesign.accent : DotistDesign.faint)
                .frame(width: 24, height: 32).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                    draggedToolbarItem = item; toolbarTranslation = value.translation.height
                }.onEnded { value in
                    let items = orderedToolbarItems
                    if let from = items.firstIndex(of: item) {
                        let to = min(max(from + Int((value.translation.height / 44).rounded()), 0), items.count - 1)
                        if from != to { withAnimation(.easeInOut(duration: 0.18)) { toolbar.move(item, onto: items[to]) } }
                    }
                    draggedToolbarItem = nil; toolbarTranslation = 0
                })
                .accessibilityLabel(model.text("拖动调整顺序") + " " + model.text(toolbarTitle(item)))
                .accessibilityIdentifier("settings-toolbar-drag-" + item.rawValue)
                .accessibilityAdjustableAction { direction in
                    let items = orderedToolbarItems
                    guard let from = items.firstIndex(of: item) else { return }
                    let to = direction == .increment ? min(from + 1, items.count - 1) : max(from - 1, 0)
                    if from != to { toolbar.move(item, onto: items[to]) }
                }
            Image(systemName: toolbarSymbol(item)).font(font(13)).foregroundStyle(DotistDesign.muted)
                .frame(width: 18).accessibilityHidden(true)
            Text(model.text(toolbarTitle(item))).font(font(13, emphasized == rowID(toolbarTitle(item)) ? .semibold : .regular))
                .foregroundStyle(emphasized == rowID(toolbarTitle(item)) ? DotistDesign.accent : DotistDesign.ink)
            Spacer(minLength: 8)
            SettingsSegmentedPicker(selection: Binding(
                get: { toolbar.visibility(of: item).rawValue },
                set: { if let visibility = ToolbarVisibility(rawValue: $0) { toolbar.setVisibility(visibility, for: item) } }),
                options: [("always", model.text("常驻")), ("hover", model.text("悬停显示"))] + (item == .collapse ? [] : [("hidden", model.text("隐藏"))]),
                label: model.text(toolbarTitle(item)), language: model.language).frame(width: 230, height: 24)
                .accessibilityLabel(model.text(toolbarTitle(item)))
                .accessibilityIdentifier("settings-toolbar-visibility-" + item.rawValue)
        }.padding(.horizontal, 14).frame(height: 44)
            .overlay(alignment: .bottom) { Rectangle().fill(DotistDesign.rule).frame(height: 0.5).padding(.leading, 14) }
            .offset(y: draggedToolbarItem == item ? toolbarTranslation : 0)
            .zIndex(draggedToolbarItem == item ? 1 : 0)
            .id(rowID(toolbarTitle(item)))
    }
    private func toolbarTitle(_ item: ToolbarItem) -> String {
        switch item {
        case .views: return "任务视图"
        case .pin: return "置顶窗口"
        case .lock: return "固定窗口"
        case .collapse: return "收起为悬浮球"
        default: return "颜色"
        }
    }
    private func toolbarSymbol(_ item: ToolbarItem) -> String {
        switch item {
        case .views: return "rectangle.split.2x1"
        case .pin: return "pin"
        case .lock: return "lock"
        case .collapse: return "arrow.down.right.and.arrow.up.left"
        default: return "paintpalette"
        }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsGroup("面板内") {
                infoRow("移动焦点", "↑↓")
                infoRow("调整顺序", "⌥↑↓")
                infoRow("缩进", "Tab")
                infoRow("新建同级任务", "Return")
                infoRow("换行", "⇧Return")
                infoRow("取消", "Esc")
                infoRow("完成 / 取消完成", model.text("空格"))
            }
            settingsGroup("全局快捷键", footer: ["Command+Comma", "CommandOrControl+Comma"].contains(model.settings.settingsShortcut) ? "⌘, 仅在 Dotist 位于前台时打开设置。" : "") {
                shortcutRow("显示 / 收起窗口", id: 1, value: model.settings.toggleShortcut)
                shortcutRow("打开设置", id: 3, value: model.settings.settingsShortcut)
                shortcutRow("打开任务视图", id: 4, value: model.settings.viewsShortcut)
                shortcutRow("快速添加", id: 2, value: model.settings.quickAddShortcut)
            }
        }
    }
    private var data: some View {
        settingsGroup("数据") {
            settingRow("数据库路径") {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(model.databasePath).font(font(12)).foregroundStyle(DotistDesign.muted).lineLimit(3).textSelection(.enabled)
                    Button(model.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.databasePath)]) }
                }.padding(.vertical, 6)
            }
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsGroup("关于") {
                infoRow("版本", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            }
            settingsGroup("更新", footer: "新版本在退出 Dotist 时安装，重新打开后生效") {
                settingRow("更新") { Button(model.text("检查更新"), action: updater.check).disabled(updater.busy) }
                boolRow("自动检查更新", value: model.settings.autoCheckUpdates) { $0.autoCheckUpdates = $1 }
                boolRow("自动安装更新", value: model.settings.autoInstallUpdates) { $0.autoInstallUpdates = $1 }
            }
            updateStatus.font(font(12)).foregroundStyle(DotistDesign.muted).padding(.horizontal, 12)
        }
    }
    @ViewBuilder private var updateStatus: some View {
        if !model.settings.lastUpdateError.isEmpty {
            Text(model.text("上次自动安装失败：{message}").replacingOccurrences(of: "{message}", with: model.settings.lastUpdateError)).foregroundStyle(DotistDesign.danger)
        }
        if updater.state == .unconfigured { Text(model.text("更新尚未配置。")) }
        if updater.state == .upToDate { Text(model.text("已是最新版本。")) }
        if updater.state == .checking || updater.state == .downloading || updater.state == .installing {
            Text(model.text("正在处理更新…"))
            if let progress = updater.progress { ProgressView(value: progress).frame(width: 160) }
        }
        if updater.state == .error {
            Text(model.text("检查更新失败：{message}").replacingOccurrences(of: "{message}", with: updater.message)).foregroundStyle(DotistDesign.danger)
        }
        if updater.state == .available || updater.state == .downloaded {
            Text(model.text("发现新版本 {version}").replacingOccurrences(of: "{version}", with: updater.version))
            if updater.state == .downloaded && model.settings.autoInstallUpdates { Text(model.text("更新已下载，退出 Dotist 时安装。")) }
            if !updater.notes.isEmpty { Text(String(updater.notes.prefix(500))) }
            HStack(spacing: 16) {
                Button(model.text("立即更新"), action: updater.install)
                Button(model.text("跳过此版本"), action: updater.skip)
            }
        }
    }
    private var glassPreset: String {
        switch (model.settings.opacity, model.settings.frost) {
        case (60, 40): return "standard"
        case (38, 22): return "clear"
        case (8, 4): return "ultra"
        default: return ""
        }
    }
    private var transparency: Double { 100 * pow(min(1, max(0, (95 - Double(model.settings.opacity)) / 91)), 1 / 1.5) }
    private func rowID(_ title: String) -> String { SettingsSearchEntry.rowID(active, title) }
    private func settingsGroup<Content: View>(_ title: String, footer: String = "", @ViewBuilder content: @escaping () -> Content) -> some View {
        SettingsGroup(model.text(title), footer: footer.isEmpty ? "" : model.text(footer), language: model.language, emphasized: emphasized == rowID(title), content: content)
    }
    private func settingRow<Content: View>(_ label: String, @ViewBuilder control: @escaping () -> Content) -> some View {
        SettingsFormRow(title: model.text(label), language: model.language, emphasized: emphasized == rowID(label), control: control)
            .id(rowID(label)).accessibilityIdentifier("settings-row-" + rowID(label))
    }
    private func numericValue(_ value: String) -> some View {
        Text(value).monospacedDigit().frame(width: 56, alignment: .trailing).foregroundStyle(DotistDesign.muted)
    }
    private func settingMenu(_ label: String, value: String, options: [(String, String)], choose: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.0) { id, title in
                Button { choose(id) } label: {
                    if id == value { Label(title, systemImage: "checkmark") }
                    else { Text(title) }
                }
            }
        } label: {
            Text(options.first(where: { $0.0 == value })?.1 ?? "").lineLimit(1).frame(width: 190, alignment: .leading)
        }.menuStyle(.automatic).frame(minHeight: 28).modifier(DotistFocusRing())
            .accessibilityLabel(Text(model.text(label)))
            .accessibilityValue(Text(options.first(where: { $0.0 == value })?.1 ?? ""))
    }
    private func boolRow(_ label: String, value: Bool, change: @escaping (inout DotistSettingsPatch, Bool) -> Void) -> some View {
        settingRow(label) {
            Toggle(model.text(label), isOn: Binding(get: { value }, set: { selected in update { change(&$0, selected) } }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(DotistDesign.accent).modifier(DotistFocusRing())
        }
    }
    private func numberRow(_ label: String, value: Double, range: ClosedRange<Double>, unit: String = "秒", change: @escaping (inout DotistSettingsPatch, Double) -> Void) -> some View {
        settingRow(label) {
            Slider(value: Binding(get: { value }, set: { selected in update { change(&$0, selected) } }), in: range)
                .frame(width: 110).modifier(DotistFocusRing())
            numericValue("\(Int(value))\(unit == "秒" ? model.text(" 秒") : unit)")
        }
    }
    private func clickRow(_ label: String, value: String, change: @escaping (inout DotistSettingsPatch, String) -> Void) -> some View {
        settingRow(label) {
            settingMenu(label, value: value, options: [("toggle", model.text("显示 / 收起窗口")), ("bubble", model.text("展开 / 收起悬浮球")), ("quick", model.text("快速添加")), ("settings", model.text("打开设置")), ("show", model.text("显示窗口")), ("menu", model.text("打开菜单")), ("none", model.text("无操作"))]) { selected in update { change(&$0, selected) } }
        }
    }
    private func shortcutRow(_ label: String, id: UInt32, value: String) -> some View {
        settingRow(label) {
            ShortcutRecorder(value: value, label: model.text(label), empty: model.text("未设置"), recordingText: model.text("按下新的快捷键…"), begin: beginShortcutCapture, finish: { endShortcutCapture(id, $0) }).frame(width: 150, height: 28)
            if !value.isEmpty {
                Button { beginShortcutCapture(); endShortcutCapture(id, "") } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("清除")))
            }
        }
    }
    private func infoRow(_ label: String, _ value: String) -> some View {
        settingRow(label) { Text(value).font(font(12)).foregroundStyle(DotistDesign.muted).lineLimit(2).textSelection(.enabled) }
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
    private func setFilter(_ id: String, enabled: Bool) {
        let values = enabled ? model.settings.filters + [id] : model.settings.filters.filter { $0 != id }
        update { $0.filters = values; if !values.contains(model.settings.defaultFilter) { $0.defaultFilter = values.first } }
    }
}
