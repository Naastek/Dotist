import AppKit
import DotistCore
import SwiftUI

struct SettingsWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: NativeUpdater
    let beginShortcutCapture: () -> Void
    let endShortcutCapture: (UInt32, String?) -> Void
    let resetWindowSize: () -> Void
    @State private var active = "appearance"
    private let sections: [(String, String, String)] = [
        ("appearance", "外观", "paintpalette"), ("general", "通用", "slider.horizontal.3"),
        ("filters", "筛选器", "list.bullet"), ("menubar", "菜单栏", "eye"),
        ("shortcuts", "快捷键", "keyboard"), ("mcp", "MCP", "cable.connector"), ("about", "数据与关于", "info.circle"),
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
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections, id: \.0) { id, title, icon in
                        Button {
                            active = id
                            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.22)) { proxy.scrollTo(id, anchor: .top) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: icon).frame(width: 16).foregroundColor(active == id ? DotistDesign.accent : DotistDesign.muted)
                                Text(model.text(title)).font(font(13, active == id ? .medium : .regular))
                                Spacer()
                            }.padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
                        }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(active == id ? DotistDesign.ink : DotistDesign.muted)
                    }
                    Spacer()
                }.padding(.horizontal, 10).padding(.top, 44).frame(width: 184).overlay(Rectangle().fill(DotistDesign.rule).frame(width: 1), alignment: .trailing)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        section("appearance", "外观") {
                            settingRow("主题") {
                                DotistGlassTabs(selection: Binding(get: { model.settings.theme }, set: { value in update { $0.theme = value } }), options: [("system", model.text("跟随系统")), ("light", model.text("浅色")), ("dark", model.text("深色"))], language: model.language)
                                    .accessibilityLabel(Text(model.text("主题")))
                            }

                            settingRow("玻璃预设") {
                                DotistGlassTabs(selection: Binding(get: { glassPreset }, set: { value in
                                    let preset = value == "clear" ? (UInt8(38), UInt8(22)) : value == "ultra" ? (UInt8(8), UInt8(4)) : (UInt8(60), UInt8(40))
                                    update { $0.opacity = preset.0; $0.frost = preset.1 }
                                }), options: [("standard", model.text("标准")), ("clear", model.text("透明玻璃")), ("ultra", model.text("极致通透"))], language: model.language)
                                    .accessibilityLabel(Text(model.text("玻璃预设")))
                            }
                            settingRow("透明程度") {
                                Slider(value: Binding(get: { transparency }, set: { value in update { $0.opacity = UInt8((95 - 91 * pow(value / 100, 1.5)).rounded()) } }), in: 0...100).frame(width: 110).modifier(DotistFocusRing())
                                Text("\(Int(transparency.rounded()))%").frame(width: 34, alignment: .trailing).foregroundColor(DotistDesign.muted)
                            }
                            settingRow("磨砂程度") {
                                Slider(value: Binding(get: { Double(model.settings.frost) }, set: { value in update { $0.frost = UInt8(value.rounded()) } }), in: 0...100).frame(width: 110).modifier(DotistFocusRing())
                                Text("\(model.settings.frost)%").frame(width: 34, alignment: .trailing).foregroundColor(DotistDesign.muted)
                            }
                            settingRow("分组颜色") {
                                // Legacy "dot" values retain their stored identity and render as colored names.
                                DotistGlassTabs(selection: Binding(get: { model.settings.groupColors == "none" ? "none" : "text" }, set: { value in update { $0.groupColors = value } }), options: [("text", model.text("彩色名称")), ("none", model.text("不显示颜色"))], language: model.language)
                                    .accessibilityLabel(Text(model.text("分组颜色")))
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
                            settingRow("窗口大小") { Button(model.text("恢复默认"), action: resetWindowSize).buttonStyle(DotistActionStyle()).modifier(DotistFocusRing()) }
                            boolRow("固定窗口", value: model.settings.locked) { $0.locked = $1 }
                            boolRow("自动收起", value: model.settings.autoCollapse) { $0.autoCollapse = $1 }
                            if model.settings.autoCollapse { numberRow("收起等待时间", value: Double(model.settings.autoCollapseSecs), range: 5...120) { $0.autoCollapseSecs = UInt16($1.rounded()) } }
                            boolRow("窗口置顶", value: model.settings.alwaysOnTop) { $0.alwaysOnTop = $1 }
                        }
                        section("filters", "筛选器") {
                            settingRow("启动时打开") {
                                settingMenu("启动时打开", value: model.settings.defaultFilter, options: model.settings.filters.map { ($0, model.text(filterLabel($0))) }) { value in update { $0.defaultFilter = value } }
                            }
                            ForEach(Array(model.settings.filters.enumerated()), id: \.element) { index, id in
                                settingRow(filterLabel(id)) {
                                    Button { moveFilter(index, -1) } label: { Image(systemName: "chevron.up").frame(width: 12) }
                                        .buttonStyle(DotistActionStyle()).modifier(DotistFocusRing()).disabled(index == 0)
                                        .accessibilityLabel(Text(model.text("上移") + " " + model.text(filterLabel(id))))
                                    Button { moveFilter(index, 1) } label: { Image(systemName: "chevron.down").frame(width: 12) }
                                        .buttonStyle(DotistActionStyle()).modifier(DotistFocusRing()).disabled(index == model.settings.filters.count - 1)
                                        .accessibilityLabel(Text(model.text("下移") + " " + model.text(filterLabel(id))))
                                    Button { setFilter(id, enabled: false) } label: { Image(systemName: "xmark").frame(width: 12) }
                                        .buttonStyle(DotistActionStyle()).modifier(DotistFocusRing()).disabled(model.settings.filters.count == 1)
                                        .accessibilityLabel(Text(model.text("清除") + " " + model.text(filterLabel(id))))
                                }
                            }
                            ForEach(["today", "all", "tomorrow", "week", "nextweek", "next7", "overdue", "undated", "done"].filter { !model.settings.filters.contains($0) }, id: \.self) { id in
                                Button("+ " + model.text(filterLabel(id))) { setFilter(id, enabled: true) }.buttonStyle(DotistActionStyle()).modifier(DotistFocusRing()).foregroundColor(DotistDesign.muted).frame(height: 32)
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
                            Text(model.text("Dotist 自带本地 MCP 服务器（stdio），与窗口共用同一个数据库。它不会自动连接任何客户端，由你在客户端里添加；添加后该客户端就能读取和修改你的任务。"))
                                .foregroundColor(DotistDesign.muted)
                            let mcp = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("dotist-mcp").path ?? ""
                            settingRow("可执行文件") {
                                Button(model.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mcp)]) }.buttonStyle(DotistActionStyle()).modifier(DotistFocusRing())
                            }
                            settingRow("MCP 路径") {
                                Text(mcp).font(font(12)).foregroundColor(DotistDesign.muted).lineLimit(2).textSelectionIfAvailable()
                                Button(model.text("复制")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(mcp, forType: .string) }.buttonStyle(DotistActionStyle()).modifier(DotistFocusRing())
                            }
                            settingRow("Claude Code") {
                                Button(model.text("复制")) {
                                    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                                    let qaData = Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa" ? ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"] : nil
                                    let environment = qaData.map { " -e " + quote("DOTIST_DATA_DIR=" + $0) } ?? ""
                                    let command = "claude mcp add dotist" + environment + " -- " + quote(mcp)
                                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
                                }.buttonStyle(DotistActionStyle()).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("复制 Claude Code 添加命令")))
                            }
                            settingRow("其他客户端配置（JSON）") {
                                Button(model.text("复制")) {
                                    var entry: [String: Any] = ["command": mcp]
                                    if Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa", let data = ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"] { entry["env"] = ["DOTIST_DATA_DIR": data] }
                                    let config: [String: Any] = ["mcpServers": ["dotist": entry]]
                                    if let bytes = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), let text = String(data: bytes, encoding: .utf8) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(text, forType: .string)
                                    }
                                }.buttonStyle(DotistActionStyle()).modifier(DotistFocusRing())
                            }
                            Text(model.text("工具：{tools}。").replacingOccurrences(of: "{tools}", with: "list_tasks, add_task, update_task, complete_task, delete_task, restore_task, move_task, set_due_date, set_start_date, set_task_status, set_task_parent, list_groups, add_group, update_group, delete_group, restore_group"))
                                .font(font(12)).foregroundColor(DotistDesign.muted).padding(.top, 8)
                        }
                        section("about", "数据与关于") {
                            infoRow("数据库路径", model.databasePath)
                            Button(model.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.databasePath)]) }.buttonStyle(DotistActionStyle()).modifier(DotistFocusRing())
                            infoRow("版本", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                            settingRow("更新") { Button(model.text("检查更新"), action: updater.check).buttonStyle(DotistActionStyle()).modifier(DotistFocusRing()).disabled(updater.busy) }
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
                                    Button(model.text("立即更新"), action: updater.install).buttonStyle(DotistActionStyle(primary: true)).modifier(DotistFocusRing())
                                    Button(model.text("跳过此版本"), action: updater.skip).buttonStyle(DotistActionStyle()).modifier(DotistFocusRing())
                                }
                            }
                        }
                    }.padding(.top, 44).padding(.horizontal, 28).padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }.font(font(13)).foregroundColor(DotistDesign.ink).controlSize(.regular).modifier(DotistControlTint()).background(WindowDragArea()).background(WindowMaterial(opacity: 68, frost: 0))
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
    private func section<Content: View>(_ id: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.text(title)).font(font(17, .semibold, serif: true)).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 0, content: content).padding(.leading, 22)
        }.frame(maxWidth: 460, alignment: .leading).id(id)
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
        }.menuStyle(BorderlessButtonMenuStyle())
            .padding(.horizontal, 12).padding(.vertical, 5).background(DotistControlGlass())
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
                Button { beginShortcutCapture(); endShortcutCapture(id, "") } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }.buttonStyle(DotistActionStyle()).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("清除")))
            }
        }
    }
    private func infoRow(_ label: String, _ value: String) -> some View {
        settingRow(label) {
            Text(value).font(font(12)).foregroundColor(DotistDesign.muted).lineLimit(2).textSelectionIfAvailable()
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
    private func moveFilter(_ index: Int, _ delta: Int) {
        let destination = index + delta
        guard model.settings.filters.indices.contains(destination) else { return }
        var values = model.settings.filters
        values.swapAt(index, destination)
        update { $0.filters = values }
    }
    private func setFilter(_ id: String, enabled: Bool) {
        let values = enabled ? model.settings.filters + [id] : model.settings.filters.filter { $0 != id }
        update {
            $0.filters = values
            if !values.contains(model.settings.defaultFilter) { $0.defaultFilter = values.first }
        }
    }
}

private extension View {
    @ViewBuilder func textSelectionIfAvailable() -> some View {
        if #available(macOS 12.0, *) { textSelection(.enabled) } else { self }
    }
}
