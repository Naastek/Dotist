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
    @State private var active = "appearance"
    @State private var manager: Manager?
    private enum Manager: String, Identifiable { case tags, groups; var id: String { rawValue } }
    private let sections: [(String, String, String)] = [
        ("appearance", "外观", "paintpalette"), ("general", "通用", "slider.horizontal.3"),
        ("filters", "筛选器", "list.bullet"), ("menubar", "菜单栏", "eye"),
        ("toolbar", "工具栏", "rectangle.topthird.inset.filled"),
        ("keyboard", "键盘快捷键", "keyboard"), ("shortcuts", "快捷键", "keyboard"), ("mcp", "MCP", "cable.connector"),
        ("data", "数据", "externaldrive"), ("about", "关于", "info.circle"),
    ]
    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> Font {
        DotistDesign.font(size, weight: weight, serif: serif, language: model.language)
    }
    private func update(_ change: (inout DotistSettingsPatch) -> Void) {
        var patch = DotistSettingsPatch()
        change(&patch)
        model.updateSettings(patch)
    }
    var body: some View {
        VStack(spacing: 0) {
        if let error = model.error { Text(model.text(error)).font(font(12)).foregroundColor(DotistDesign.danger).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
        Group {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections, id: \.0) { id, title, icon in
                        Button {
                            active = id
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: icon).frame(width: 16).foregroundColor(active == id ? DotistDesign.accent : DotistDesign.muted)
                                Text(model.text(title)).font(font(13, active == id ? .medium : .regular))
                                Spacer()
                            }.padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
                        }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(active == id ? DotistDesign.ink : DotistDesign.muted)
                            .accessibilityAddTraits(active == id ? .isSelected : [])
                    }
                    Spacer()
                }.padding(.horizontal, 10).padding(.top, 44).frame(width: 184).overlay(Rectangle().fill(DotistDesign.rule).frame(width: 1), alignment: .trailing)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        section("appearance", "外观") {
                            settingRow("主题") {
                                NativeSegmentedPicker(selection: Binding(get: { model.settings.theme }, set: { value in update { $0.theme = value } }),
                                                      options: [("system", model.text("跟随系统")), ("light", model.text("浅色")), ("dark", model.text("深色"))],
                                                      label: model.text("主题")).frame(width: 244, height: 24)
                            }

                            settingRow("玻璃预设") {
                                NativeSegmentedPicker(selection: Binding(get: { glassPreset }, set: { value in
                                    let preset = value == "clear" ? (UInt8(38), UInt8(22)) : value == "ultra" ? (UInt8(8), UInt8(4)) : (UInt8(60), UInt8(40))
                                    update { $0.opacity = preset.0; $0.frost = preset.1 }
                                }), options: [("standard", model.text("标准")), ("clear", model.text("透明玻璃")), ("ultra", model.text("极致通透"))],
                                    label: model.text("玻璃预设")).frame(width: 244, height: 24)
                            }
                            settingRow("透明程度") {
                                Slider(value: Binding(get: { transparency }, set: { value in update { $0.opacity = UInt8((95 - 91 * pow(value / 100, 1.5)).rounded()) } }), in: 0...100).frame(width: 110).modifier(DotistFocusRing())
                                Text("\(Int(transparency.rounded()))%").frame(width: 34, alignment: .trailing).foregroundColor(DotistDesign.muted)
                            }
                            settingRow("磨砂程度") {
                                Slider(value: Binding(get: { Double(model.settings.frost) }, set: { value in update { $0.frost = UInt8(value.rounded()) } }), in: 0...100).frame(width: 110).modifier(DotistFocusRing())
                                Text("\(model.settings.frost)%").frame(width: 34, alignment: .trailing).foregroundColor(DotistDesign.muted)
                            }
                            boolRow("失焦淡出", value: model.settings.idleFade) { $0.idleFade = $1 }
                            if model.settings.idleFade {
                                numberRow("淡出前等待", value: Double(model.settings.idleDelaySecs), range: 1...60) { $0.idleDelaySecs = UInt8($1.rounded()) }
                                numberRow("淡出用时", value: Double(model.settings.idleFadeSecs), range: 1...10) { $0.idleFadeSecs = UInt8($1.rounded()) }
                                numberRow("淡出后的不透明度", value: Double(model.settings.idleOpacity), range: 20...95, unit: "%") { $0.idleOpacity = UInt8($1.rounded()) }
                            }
                        }
                        section("general", "通用") {
                            settingRow("语言") {
                                settingMenu("语言", value: model.settings.language, options: [("system", model.text("跟随系统")), ("zh-CN", "简体中文"), ("zh-TW", "繁體中文"), ("en", "English"), ("ja", "日本語")]) { value in update { $0.language = value } }
                            }
                            boolRow("显示在 Dock", value: model.settings.showDock) { $0.showDock = $1 }
                            boolRow("显示在菜单栏", value: model.settings.showMenubar) { $0.showMenubar = $1 }
                            settingRow("开机启动") {
                                Toggle(model.text("开机启动"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                                    .labelsHidden().toggleStyle(SwitchToggleStyle()).accentColor(DotistDesign.accent).modifier(DotistFocusRing())
                            }
                            boolRow("悬停显示详情", value: model.settings.hoverExpand) { $0.hoverExpand = $1 }
                            settingRow("窗口大小") { Button(model.text("恢复默认"), action: resetWindowSize).buttonStyle(DefaultButtonStyle()).modifier(DotistFocusRing()) }
                            boolRow("固定窗口", value: model.settings.locked) { $0.locked = $1 }
                            boolRow("自动收起", value: model.settings.autoCollapse) { $0.autoCollapse = $1 }
                            if model.settings.autoCollapse { numberRow("收起等待时间", value: Double(model.settings.autoCollapseSecs), range: 5...120) { $0.autoCollapseSecs = UInt16($1.rounded()) } }
                            boolRow("窗口置顶", value: model.settings.alwaysOnTop) { $0.alwaysOnTop = $1 }
                            settingRow("分组") { Button(model.text("管理分组…")) { manager = .groups } }
                            settingRow("标签") { Button(model.text("管理标签…")) { manager = .tags } }
                        }
                        section("filters", "筛选器") {
                            settingRow("启动时打开") {
                                settingMenu("启动时打开", value: model.settings.defaultFilter, options: model.settings.filters.map { ($0, model.text(filterLabel($0))) }) { value in update { $0.defaultFilter = value } }
                            }
                            List {
                                ForEach(model.settings.filters, id: \.self) { id in
                                    HStack(spacing: 10) {
                                        Image(systemName: "line.3.horizontal").foregroundColor(DotistDesign.faint).accessibilityHidden(true)
                                        Text(model.text(filterLabel(id)))
                                        Spacer()
                                        Button { setFilter(id, enabled: false) } label: { Image(systemName: "xmark").frame(width: 20, height: 20) }
                                            .buttonStyle(.plain).modifier(DotistFocusRing()).disabled(model.settings.filters.count == 1)
                                            .accessibilityLabel(Text(model.text("清除") + " " + model.text(filterLabel(id))))
                                    }.frame(height: 32).contentShape(Rectangle())
                                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                                }.onMove { source, destination in
                                    var values = model.settings.filters
                                    values.move(fromOffsets: source, toOffset: destination)
                                    update { $0.filters = values }
                                }
                            }.listStyle(PlainListStyle()).environment(\.defaultMinListRowHeight, 32)
                                .frame(height: CGFloat(model.settings.filters.count * 32 + 8))
                                .accessibilityIdentifier("settings-filter-order")
                            ForEach(["today", "all", "tomorrow", "week", "nextweek", "next7", "overdue", "undated", "done"].filter { !model.settings.filters.contains($0) }, id: \.self) { id in
                                Button("+ " + model.text(filterLabel(id))) { setFilter(id, enabled: true) }.buttonStyle(DefaultButtonStyle()).modifier(DotistFocusRing()).foregroundColor(DotistDesign.muted).frame(height: 32)
                            }
                        }
                        section("menubar", "菜单栏") {
                            settingRow("显示内容") {
                                settingMenu("显示内容", value: model.settings.trayMode, options: [("icon", model.text("仅图标")), ("count", model.text("剩余数字")), ("next", model.text("下一个任务")), ("next_date", model.text("下一个任务与日期")), ("rotate", model.text("轮播：数字与最近的任务"))]) { value in update { $0.trayMode = value } }
                            }
                            if model.settings.trayMode != "icon" {
                                settingRow("日期透视") {
                                    settingMenu("日期透视", value: model.settings.trayFilter, options: ["today", "all", "tomorrow", "week", "nextweek", "next7", "overdue", "undated", "done"].map { ($0, model.text(filterLabel($0))) }) { value in update { $0.trayFilter = value } }
                                }
                                settingRow("分组") {
                                    settingMenu("分组", value: model.settings.trayGroup == "all" || model.groups.contains(where: { $0.id == model.settings.trayGroup }) ? model.settings.trayGroup : "all", options: [("all", model.text("全部分组"))] + model.groups.map { ($0.id, $0.name) }) { value in update { $0.trayGroup = value } }
                                }
                            }
                            if model.settings.trayMode == "rotate" {
                                settingRow("轮播间隔") {
                                    Slider(value: Binding(get: { Double(model.settings.trayRotateSecs) }, set: { value in update { $0.trayRotateSecs = UInt16(value.rounded()) } }), in: 2...30).frame(width: 110).modifier(DotistFocusRing())
                                    Text("\(model.settings.trayRotateSecs)\(model.text(" 秒"))")
                                }
                            }
                            clickRow("左键点击", value: model.settings.trayLeftClick) { $0.trayLeftClick = $1 }
                            clickRow("右键点击", value: model.settings.trayRightClick) { $0.trayRightClick = $1 }
                        }
                        section("toolbar", "工具栏") {
                            Text(model.text("在面板上按住 ⌘ 可以左右拖动图标调整顺序"))
                                .font(font(12)).foregroundColor(DotistDesign.muted).padding(.vertical, 8)
                            ForEach(Array(toolbar.order.enumerated()), id: \.element) { index, item in
                                HStack(spacing: 6) {
                                    Text(model.text(toolbarTitle(item))).frame(maxWidth: .infinity, alignment: .leading)
                                    Picker(model.text(toolbarTitle(item)), selection: Binding(
                                        get: { toolbar.visibility(of: item) },
                                        set: { toolbar.setVisibility($0, for: item) })) {
                                        Text(model.text("常驻")).tag(ToolbarVisibility.always)
                                        Text(model.text("悬停显示")).tag(ToolbarVisibility.hover)
                                        if item != .collapse { Text(model.text("隐藏")).tag(ToolbarVisibility.hidden) }
                                    }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
                                        .accessibilityLabel(Text(model.text(toolbarTitle(item))))
                                    Button { toolbar.move(item, onto: toolbar.order[index - 1]) } label: { Image(systemName: "chevron.up") }
                                        .disabled(index == 0).accessibilityLabel(Text(model.text("上移")))
                                    Button { toolbar.move(item, onto: toolbar.order[index + 1]) } label: { Image(systemName: "chevron.down") }
                                        .disabled(index == toolbar.order.count - 1).accessibilityLabel(Text(model.text("下移")))
                                }.frame(minHeight: 40)
                            }
                            Button(model.text("恢复默认")) { toolbar.reset() }.padding(.top, 8)
                        }
                        section("keyboard", "键盘快捷键") {
                            Text(model.text("面板内")).font(font(13, .medium)).padding(.top, 8)
                            infoRow("移动焦点", "↑↓")
                            infoRow("调整顺序", "⌥↑↓")
                            infoRow("缩进", "Tab")
                            infoRow("保存 / 新建", "Return")
                            infoRow("换行", "⇧Return")
                            infoRow("取消", "Esc")
                            Text(model.text("全局快捷键")).font(font(13, .medium)).padding(.top, 12)
                            infoRow("显示 / 收起窗口", shortcutValue(model.settings.toggleShortcut))
                            infoRow("打开设置", shortcutValue(model.settings.settingsShortcut))
                            infoRow("打开任务视图", shortcutValue(model.settings.viewsShortcut))
                            infoRow("快速添加", shortcutValue(model.settings.quickAddShortcut))
                        }
                        section("shortcuts", "快捷键") {
                            shortcutRow("显示 / 收起窗口", id: 1, value: model.settings.toggleShortcut)
                            shortcutRow("打开设置", id: 3, value: model.settings.settingsShortcut)
                            if ["Command+Comma", "CommandOrControl+Comma"].contains(model.settings.settingsShortcut) {
                                Text(model.text("⌘, 仅在 Dotist 位于前台时打开设置。")).font(font(12)).foregroundColor(DotistDesign.muted)
                            }
                            shortcutRow("打开任务视图", id: 4, value: model.settings.viewsShortcut)
                            shortcutRow("快速添加", id: 2, value: model.settings.quickAddShortcut)
                        }
                        section("mcp", "MCP") {
                            MCPSettings(model: model, service: model.mcp)
                        }
                        section("data", "数据") {
                            infoRow("数据库路径", model.databasePath)
                            Button(model.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.databasePath)]) }.buttonStyle(DefaultButtonStyle()).modifier(DotistFocusRing())
                        }
                        section("about", "关于") {
                            infoRow("版本", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                            settingRow("更新") { Button(model.text("检查更新"), action: updater.check).buttonStyle(DefaultButtonStyle()).modifier(DotistFocusRing()).disabled(updater.busy) }
                            boolRow("自动检查更新", value: model.settings.autoCheckUpdates) { $0.autoCheckUpdates = $1 }
                            boolRow("自动安装更新", value: model.settings.autoInstallUpdates) { $0.autoInstallUpdates = $1 }
                            Text(model.text("新版本在退出 Dotist 时安装，重新打开后生效")).font(font(12)).foregroundColor(DotistDesign.muted)
                            if !model.settings.lastUpdateError.isEmpty {
                                Text(model.text("上次自动安装失败：{message}").replacingOccurrences(of: "{message}", with: model.settings.lastUpdateError)).font(font(12)).foregroundColor(DotistDesign.danger)
                            }
                            if updater.state == .unconfigured { Text(model.text("更新尚未配置。")) }
                            if updater.state == .upToDate { Text(model.text("已是最新版本。")) }
                            if updater.state == .checking || updater.state == .downloading || updater.state == .installing {
                                Text(model.text("正在处理更新…"))
                                if let progress = updater.progress { ProgressView(value: progress).frame(width: 160) }
                            }
                            if updater.state == .error { Text(model.text("检查更新失败：{message}").replacingOccurrences(of: "{message}", with: updater.message)).foregroundColor(DotistDesign.danger) }
                            if updater.state == .available || updater.state == .downloaded {
                                Text(model.text("发现新版本 {version}").replacingOccurrences(of: "{version}", with: updater.version))
                                if updater.state == .downloaded && model.settings.autoInstallUpdates { Text(model.text("更新已下载，退出 Dotist 时安装。")) }
                                if !updater.notes.isEmpty { Text(String(updater.notes.prefix(500))) }
                                HStack(spacing: 16) {
                                    Button(model.text("立即更新"), action: updater.install).buttonStyle(DefaultButtonStyle()).modifier(DotistFocusRing())
                                    Button(model.text("跳过此版本"), action: updater.skip).buttonStyle(DefaultButtonStyle()).modifier(DotistFocusRing())
                                }
                            }
                        }
                    }.padding(.top, 44).padding(.horizontal, 28).padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .topLeading)
                }.id(active)
            }.font(font(13)).foregroundColor(DotistDesign.ink).controlSize(.regular).background(WindowDragArea()).background(DotistDesign.paper)
        }.modifier(DotistTheme(theme: model.settings.theme))
        }.sheet(item: $manager) { current in
            Group {
                switch current {
                case .groups:
                    GroupManager(model: model, close: { manager = nil }, tags: { manager = .tags })
                case .tags:
                    TagManager(model: model, close: { manager = nil }, groups: { manager = .groups }, select: { _ in })
                }
            }.frame(minWidth: 420, minHeight: 400)
        }
    }
    private func toolbarTitle(_ item: ToolbarItem) -> String {
        switch item {
        case .views: return "任务视图"
        case .pin: return "置顶窗口"
        case .lock: return "固定窗口"
        case .search: return "搜索"
        case .collapse: return "收起为悬浮球"
        }
    }
    private func shortcutValue(_ value: String) -> String {
        value.isEmpty ? model.text("未设置") : value.replacingOccurrences(of: "CommandOrControl", with: "⌘").replacingOccurrences(of: "Command", with: "⌘").replacingOccurrences(of: "Control", with: "⌃").replacingOccurrences(of: "Alt", with: "⌥").replacingOccurrences(of: "Shift", with: "⇧").replacingOccurrences(of: "+", with: " ")
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
    @ViewBuilder private func section<Content: View>(_ id: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        if active == id {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.text(title)).font(font(17, .semibold, serif: true)).padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 0, content: content).padding(.leading, 22)
            }.frame(maxWidth: 460, alignment: .leading)
        }
    }
    private func settingRow<Content: View>(_ label: String, @ViewBuilder control: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(model.text(label)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack(spacing: 8, content: control)
        }.frame(minHeight: 40)
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
            Text(options.first(where: { $0.0 == value })?.1 ?? "")
                .lineLimit(1).frame(width: 164, alignment: .leading)
        }.menuStyle(DefaultMenuStyle()).frame(minHeight: 28)
            .modifier(DotistFocusRing())
            .accessibilityLabel(Text(model.text(label)))
            .accessibilityValue(Text(options.first(where: { $0.0 == value })?.1 ?? ""))
    }
    private func boolRow(_ label: String, value: Bool, change: @escaping (inout DotistSettingsPatch, Bool) -> Void) -> some View {
        settingRow(label) {
            Toggle(model.text(label), isOn: Binding(get: { value }, set: { selected in update { change(&$0, selected) } }))
                .labelsHidden().toggleStyle(SwitchToggleStyle()).accentColor(DotistDesign.accent).modifier(DotistFocusRing())
        }
    }
    private func numberRow(_ label: String, value: Double, range: ClosedRange<Double>, unit: String = "秒", change: @escaping (inout DotistSettingsPatch, Double) -> Void) -> some View {
        settingRow(label) {
            Slider(value: Binding(get: { value }, set: { selected in update { change(&$0, selected) } }), in: range).frame(width: 110).modifier(DotistFocusRing())
            Text("\(Int(value))\(unit == "秒" ? model.text(" 秒") : unit)").frame(width: 42, alignment: .trailing).foregroundColor(DotistDesign.muted)
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
                Button { beginShortcutCapture(); endShortcutCapture(id, "") } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }.buttonStyle(DefaultButtonStyle()).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("清除")))
            }
        }
    }
    private func infoRow(_ label: String, _ value: String) -> some View {
        settingRow(label) {
            Text(value).font(font(12)).foregroundColor(DotistDesign.muted).lineLimit(2).textSelection(.enabled)
        }
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
        update {
            $0.filters = values
            if !values.contains(model.settings.defaultFilter) { $0.defaultFilter = values.first }
        }
    }
}
