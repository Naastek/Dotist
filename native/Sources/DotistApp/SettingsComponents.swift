import AppKit
import DotistCore
import SwiftUI

/// The navigation and search registry share the same stable section identifiers.
enum SettingsModule: String, CaseIterable, Identifiable {
    case appearance, general, filters, menubar, toolbar, shortcuts, mcp, data, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: return "外观"
        case .general: return "通用"
        case .filters: return "筛选器"
        case .menubar: return "菜单栏"
        case .toolbar: return "工具栏"
        case .shortcuts: return "快捷键"
        case .mcp: return "MCP"
        case .data: return "数据"
        case .about: return "关于"
        }
    }
}

struct SettingsSearchEntry: Identifiable, Equatable {
    let module: SettingsModule
    let title: String
    let target: String
    let keywords: [String]
    var id: String { target }

    static func rowID(_ module: SettingsModule, _ title: String) -> String { module.rawValue + "." + title }
}

/// Foundation-only matching: every token must occur in a title, translation,
/// module name or keyword. No model, UI host or active interface language needed.
enum SettingsSearchIndex {
    static let entries: [SettingsSearchEntry] = {
        let rows: [(SettingsModule, [String])] = [
            (.appearance, ["主题", "玻璃预设", "透明程度", "磨砂程度", "失焦淡出", "淡出前等待", "淡出用时", "淡出后的不透明度", "全部(默认颜色)"]),
            (.general, ["语言", "显示在 Dock", "显示在菜单栏", "开机启动", "悬停显示详情", "窗口大小", "固定窗口", "自动收起", "收起等待时间", "窗口置顶", "分组", "标签"]),
            (.filters, ["启动时打开", "筛选器"]),
            (.menubar, ["显示内容", "日期透视", "分组", "轮播间隔", "左键点击", "右键点击"]),
            (.toolbar, ["颜色", "任务视图", "置顶窗口", "固定窗口", "收起为悬浮球", "恢复默认"]),
            (.shortcuts, ["移动焦点", "调整顺序", "缩进", "新建同级任务", "换行", "取消", "完成 / 取消完成", "显示 / 收起窗口", "打开设置", "打开任务视图", "快速添加"]),
            (.mcp, ["启用本地 MCP", "客户端", "复制"]),
            (.data, ["数据库路径"]),
            (.about, ["版本", "更新", "自动检查更新", "自动安装更新"]),
        ]
        let moduleAliases: [SettingsModule: String] = [
            .appearance: "Appearance 外觀 外観 theme color colour 颜色主题 カラー 配色 色彩 顏色主題",
            .general: "General 一般 通用",
            .filters: "Filters フィルター 篩選器",
            .menubar: "Menu bar メニューバー 選單列",
            .toolbar: "Toolbar ツールバー 工具列 常驻 悬停显示 隐藏 常駐 懸停顯示 隱藏 always hover hidden 順序 並べ替え",
            .shortcuts: "Shortcuts キーボード ショートカット 快捷鍵",
            .mcp: "MCP server client configuration 服务器 伺服器 サーバー クライアント 配置 設定",
            .data: "Data データ 資料 database Finder 数据库 資料庫 データベース",
            .about: "About このアプリについて 關於 update アップデート 更新",
        ]
        return rows.flatMap { module, titles in
            titles.map { title in
                SettingsSearchEntry(module: module, title: title, target: SettingsSearchEntry.rowID(module, title),
                                    keywords: [module.title, moduleAliases[module] ?? ""] + translations(title) + translations(module.title) + aliases(title))
            }
        }
    }()

    static func matches(_ query: String, in entries: [SettingsSearchEntry] = Self.entries) -> [SettingsSearchEntry] {
        let tokens = normalized(query).split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return [] }
        return entries.filter { entry in
            let text = normalized(([entry.title] + entry.keywords).joined(separator: " "))
            return tokens.allSatisfy { text.contains($0) }
        }
    }

    static func groupEntry(id: String, name: String) -> SettingsSearchEntry {
        SettingsSearchEntry(module: .appearance, title: name, target: "appearance.color-" + id,
                            keywords: ["颜色主题 分组颜色 group color colour カラー グループの色 顏色主題 群組顏色", name])
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static let dictionaries: [[String: [String: String]]] = ["locales", "native-locales"].compactMap { name in
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: [String: String]].self, from: data)
    }
    private static func translations(_ title: String) -> [String] {
        dictionaries.flatMap { dictionary in dictionary.values.compactMap { $0[title] } }
    }
    private static func aliases(_ title: String) -> [String] {
        switch title {
        case "全部(默认颜色)": return ["默认颜色 預設顏色 デフォルトカラー All default color colour 全部 颜色主题 顏色主題 カラーテーマ"]
        case "颜色": return ["Color Colour カラー 顏色"]
        case "语言": return ["language locale 言語 語言 English 日本語 简体中文 繁體中文 跟随系统 跟隨系統"]
        case "主题": return ["system light dark 浅色 深色 ライト ダーク 淺色 跟随系统"]
        case "筛选器": return ["today tomorrow week next overdue undated done 今天 明天 本周 已逾期 无日期 已完成 今日 明日 今週 期限切れ 日付なし 完了 今天 明天 本週 已逾期 無日期 已完成"]
        default: return []
        }
    }
}

/// A grouped form container. Row separators belong to the rows so conditional
/// settings keep the same spacing and baseline when they appear.
struct SettingsGroup<Content: View>: View {
    let title: String
    let footer: String
    let language: String
    let emphasized: Bool
    @ViewBuilder let content: () -> Content
    init(_ title: String, footer: String = "", language: String, emphasized: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.footer = footer; self.language = language; self.emphasized = emphasized; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(DotistDesign.font(12, weight: .semibold, language: language))
                .foregroundStyle(emphasized ? DotistDesign.accent : DotistDesign.muted).padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 0, content: content)
                .background(DotistDesign.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DotistDesign.rule, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if !footer.isEmpty {
                Text(footer).font(DotistDesign.font(12, language: language)).foregroundStyle(DotistDesign.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12)
            }
        }
    }
}

struct SettingsFormRow<Control: View>: View {
    let title: String
    let language: String
    var emphasized = false
    var serif = false
    @ViewBuilder let control: () -> Control
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(DotistDesign.font(13, weight: emphasized ? .semibold : .regular, serif: serif, language: language))
                .foregroundStyle(emphasized ? DotistDesign.accent : DotistDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack(spacing: 8, content: control)
        }.padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: 44)
            .overlay(alignment: .bottom) { Rectangle().fill(DotistDesign.rule).frame(height: 0.5).padding(.leading, 14) }
    }
}

struct SettingsColorPalette: View {
    @ObservedObject var model: AppModel
    let selected: DotistGroupColor
    let identifier: String
    let choose: (DotistGroupColor) -> Void
    private let names = ["无颜色", "红色", "橙色", "黄色", "绿色", "青色", "蓝色", "紫色", "粉色"]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(DotistGroupColor.allCases.enumerated()), id: \.element.rawValue) { index, color in
                Button { choose(color) } label: {
                    RoundedRectangle(cornerRadius: 4).fill(DotistTheme.swatch(color)).frame(width: 19, height: 19)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(color == selected ? DotistDesign.ink : DotistDesign.rule, lineWidth: color == selected ? 1.5 : 0.5))
                        .overlay {
                            if selected == color {
                                Image(systemName: "checkmark").font(DotistDesign.font(10, weight: .bold, language: model.language))
                                    .foregroundStyle(color == .none ? DotistDesign.ink : .white)
                            }
                        }.frame(width: 23, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).modifier(DotistFocusRing())
                    .help(model.text(names[index])).accessibilityLabel(model.text(names[index]))
                    .accessibilityAddTraits(selected == color ? .isSelected : [])
                    .accessibilityIdentifier(identifier + "-" + color.rawValue)
            }
        }.accessibilityElement(children: .contain)
    }
}

/// Use the same font tokens for AppKit segment labels as for SwiftUI row text.
struct SettingsSegmentedPicker: NSViewRepresentable {
    @Binding var selection: String
    let options: [(String, String)]
    let label: String
    let language: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> FocusSegmentedControl {
        let control = FocusSegmentedControl(labels: options.map(\.1), trackingMode: .selectOne,
                                            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentStyle = .rounded
        control.segmentDistribution = .fillProportionally
        control.controlSize = .small
        control.focusRingType = .none
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: proposal.height ?? 24)
    }
    func updateNSView(_ control: FocusSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.font = DotistDesign.nativeFont(12, language: language)
        control.setAccessibilityLabel(label)
        control.segmentCount = options.count
        for (index, option) in options.enumerated() { control.setLabel(option.1, forSegment: index) }
        control.selectedSegment = options.firstIndex { $0.0 == selection } ?? -1
    }
    final class Coordinator: NSObject {
        var parent: SettingsSegmentedPicker
        init(_ parent: SettingsSegmentedPicker) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            guard parent.options.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.options[sender.selectedSegment].0
        }
    }
}
