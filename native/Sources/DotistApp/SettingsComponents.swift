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
    var isGroupName = false
    var id: String { target }

    static func rowID(_ module: SettingsModule, _ title: String) -> String { module.rawValue + "." + title }
}

/// Foundation-only matching: every token must occur in a title, translation,
/// module name or keyword. No model, UI host or active interface language needed.
enum SettingsSearchIndex {
    static let entries: [SettingsSearchEntry] = {
        let rows: [(SettingsModule, [String])] = [
            (.appearance, ["主题", "玻璃预设", "主表面透明度", "磨砂程度", "字体", "西文衬线", "西文无衬线", "中文衬线", "中文无衬线", "恢复默认字体", "失焦淡出", "淡出前等待", "淡出用时", "失焦后整窗透明度", "全部", "分组便签背景透明度", "便签入场预览"]),
            (.general, ["语言", "显示在 Dock", "显示在菜单栏", "开机启动", "悬停显示详情", "窗口大小", "固定窗口", "自动收起", "收起等待时间", "窗口置顶", "分组", "标签"]),
            (.filters, ["启动时打开", "筛选器"]),
            (.menubar, ["显示内容", "日期透视", "分组", "轮播间隔", "左键点击", "右键点击"]),
            (.toolbar, ["颜色", "任务视图", "置顶窗口", "固定窗口", "收起为悬浮球", "恢复默认"]),
            (.shortcuts, ["移动焦点", "调整顺序", "缩进", "新建同级任务", "换行", "取消", "完成 / 取消完成", "显示 / 收起窗口", "快速添加", "打开搜索", "打开任务视图", "打开设置"]),
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
            .shortcuts: "Shortcuts キーボード ショートカット 快捷鍵 应用快捷键 作用域 全局 仅 Dotist 不启用",
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
                            keywords: ["颜色主题 分组颜色 group color colour カラー グループの色 顏色主題 群組顏色", name], isGroupName: true)
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
        case "主表面透明度": return ["transparency opacity alpha glass 透明程度 不透明度 透過率"] + translations("透明程度")
        case "分组便签背景透明度": return ["transparency opacity alpha group tab 分组便签不透明度"] + translations("分组便签不透明度")
        case "失焦后整窗透明度": return ["transparency opacity alpha idle fade 淡出后的不透明度"] + translations("淡出后的不透明度")
        case "字体": return ["Fonts Typeface フォント 字型 字體"]
        case "西文衬线": return ["Fonts Latin serif 西文襯線 欧文セリフ Newsreader Source Serif Brygada 1918 PT Serif Playfair Display Zodiak Gambarino New York 系统 系統 システム system"]
        case "西文无衬线": return ["Fonts Latin sans serif 西文無襯線 欧文サンセリフ Atkinson Hyperlegible Next Source Sans Figtree Rubik Work Sans Public Sans Quicksand Plus Jakarta Sans Switzer Satoshi SF Pro 系统 系統 システム system"]
        case "中文衬线": return ["Fonts CJK serif 中文襯線 CJKセリフ 思源宋体 思源宋體 Noto Serif Chiron Sung HK 昭源宋体 昭源宋體 Songti 系统 系統 システム system"]
        case "中文无衬线": return ["Fonts CJK sans serif 中文無襯線 CJKサンセリフ 思源黑体 思源黑體 Noto Sans PingFang 苹方 蘋方 系统 系統 システム system"]
        case "恢复默认字体": return ["Restore default fonts フォントを初期設定に戻す 恢復預設字體"]
        case "全部": return ["默认颜色 預設顏色 デフォルトカラー All default color colour 全部 颜色主题 顏色主題 カラーテーマ"]
        case "颜色": return ["Color Colour カラー 顏色"]
        case "语言": return ["language locale 言語 語言 English Français Deutsch 简体中文 繁體中文 跟随系统 跟隨系統"]
        case "主题": return ["system light dark 浅色 深色 ライト ダーク 淺色 跟随系统"]
        case "筛选器": return ["today tomorrow week next overdue undated done 今天 明天 本周 已逾期 无日期 已完成 今日 明日 今週 期限切れ 日付なし 完了 今天 明天 本週 已逾期 無日期 已完成"]
        default: return []
        }
    }
}

extension DotistFontRole {
    static let restoreDefaultsTitle = "恢复默认字体"
    static let previewText = "Aa 全部 work"
    var title: String {
        switch self {
        case .serifLatin: return "西文衬线"
        case .sansLatin: return "西文无衬线"
        case .serifCjk: return "中文衬线"
        case .sansCjk: return "中文无衬线"
        }
    }
    var isSerif: Bool { self == .serifLatin || self == .serifCjk }
    func value(in settings: DotistSettings) -> String {
        switch self {
        case .serifLatin: return settings.fontPreferences.serifLatin
        case .sansLatin: return settings.fontPreferences.sansLatin
        case .serifCjk: return settings.fontPreferences.serifCjk
        case .sansCjk: return settings.fontPreferences.sansCjk
        }
    }
    func set(_ value: String, in patch: inout DotistSettingsPatch) {
        switch self {
        case .serifLatin: patch.fontSerifLatin = value
        case .sansLatin: patch.fontSansLatin = value
        case .serifCjk: patch.fontSerifCjk = value
        case .sansCjk: patch.fontSansCjk = value
        }
    }
    func label(_ value: String) -> String {
        switch value {
        case "switzer": return "Switzer"
        case "satoshi": return "Satoshi"
        case "zodiak": return "Zodiak"
        case "gambarino": return "Gambarino"
        case "brygada-1918": return "Brygada 1918"
        case "pt-serif": return "PT Serif"
        case "playfair-display": return "Playfair Display"
        case "figtree": return "Figtree"
        case "rubik": return "Rubik"
        case "work-sans": return "Work Sans"
        case "public-sans": return "Public Sans"
        case "quicksand": return "Quicksand"
        case "plus-jakarta-sans": return "Plus Jakarta Sans"
        case "newsreader": return "Newsreader"
        case "atkinson-next": return "Atkinson Hyperlegible Next"
        case "source-serif-4": return "Source Serif 4"
        case "source-sans-3": return "Source Sans 3"
        case "noto-serif": return "思源宋体"
        case "noto-sans": return "思源黑体"
        case "chiron-sung-hk": return "昭源宋体"
        default: return "系统"
        }
    }
}

struct SettingsFontOption {
    let id: String
    let title: String
    let available: Bool
    let explanation: String?
}

enum SettingsFontAvailability {
    static func message(language: String) -> String {
        if language.hasPrefix("zh-TW") || language.hasPrefix("zh-HK") || language.hasPrefix("zh-Hant") { return "未安裝，需先在本機安裝" }
        if language.hasPrefix("zh") { return "未安装，需先在本机安装" }
        if language.hasPrefix("ja") { return "未インストール（ローカルに必要）" }
        if language.hasPrefix("fr") { return "Non installée sur cet appareil" }
        if language.hasPrefix("de") { return "Lokal nicht installiert" }
        return "Not installed locally"
    }
    static func status(language: String) -> String {
        if language.hasPrefix("zh-TW") || language.hasPrefix("zh-HK") || language.hasPrefix("zh-Hant") { return "未安裝" }
        if language.hasPrefix("zh") { return "未安装" }
        if language.hasPrefix("ja") { return "未インストール" }
        if language.hasPrefix("fr") { return "Non installée" }
        if language.hasPrefix("de") { return "Nicht installiert" }
        return "Not installed"
    }
    static func options(role: DotistFontRole, language: String, translate: (String) -> String = { $0 }, check: (String) -> Bool = { DotistDesign.familyFont($0, size: 13, weight: .regular) != nil }) -> [SettingsFontOption] {
        role.choices.map { id in
            let available = DotistDesign.localFontAvailable(id, check: check)
            return SettingsFontOption(id: id, title: translate(role.label(id)) + (available ? "" : " — " + status(language: language)), available: available, explanation: available ? nil : message(language: language))
        }
    }
}

/// A grouped form container. Row separators belong to the rows so conditional
/// settings keep the same spacing and baseline when they appear.
struct SettingsGroup<Content: View>: View {
    @ObservedObject private var typography = DotistTypography.shared
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
    var stacked = false
    @ViewBuilder let control: () -> Control
    private var label: some View {
        OpticalText(title: title, size: 13, weight: emphasized ? .semibold : .regular, serif: serif, language: language)
            .foregroundStyle(emphasized ? DotistDesign.accent : DotistDesign.ink)
    }
    private var controls: some View {
        HStack(alignment: .opticalCenter, spacing: 8, content: control)
    }
    private var vertical: some View {
        VStack(alignment: .leading, spacing: 8) {
            label.fixedSize(horizontal: false, vertical: true)
            controls.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
    var body: some View {
        Group {
            if stacked { vertical }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .opticalCenter, spacing: 12) {
                        label.fixedSize()
                        Spacer(minLength: 8)
                        controls
                    }
                    vertical
                }
            }
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
        HStack(spacing: 0) {
            ForEach(Array(DotistGroupColor.allCases.enumerated()), id: \.element.rawValue) { index, color in
                Button { choose(color) } label: {
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
                        .overlay { if selected == color { Circle().strokeBorder(DotistDesign.accent, lineWidth: 2) } }
                        .contentShape(Circle())
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
    @ObservedObject private var typography = DotistTypography.shared
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
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
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


/// A native popup with a shared actual control width. SwiftUI's menu Picker
/// centers an intrinsic-width AppKit bezel inside its fixed outer frame.
struct SettingsFontPicker: NSViewRepresentable {
    static let previewWidth: CGFloat = 110
    static let columnWidth: CGFloat = 244
    @Binding var selection: String
    let options: [SettingsFontOption]
    let label: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.cell = SettingsFontPickerCell(textCell: "", pullsDown: false)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 13)
        popup.alignment = .left
        popup.lineBreakMode = .byTruncatingTail
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.changed(_:))
        return popup
    }
    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(\.title)
        if popup.itemTitles != titles { popup.removeAllItems(); popup.addItems(withTitles: titles) }
        popup.menu?.autoenablesItems = false
        popup.selectItem(at: options.firstIndex { $0.id == selection } ?? 0)
        for (index, option) in options.enumerated() {
            popup.item(at: index)?.isEnabled = option.available
            popup.item(at: index)?.toolTip = option.explanation
        }
        popup.toolTip = options.first(where: { $0.id == selection && !$0.available })?.explanation
        popup.setAccessibilityLabel(label)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? Self.columnWidth, height: 28)
    }
    final class Coordinator: NSObject {
        var parent: SettingsFontPicker
        init(_ parent: SettingsFontPicker) { self.parent = parent }
        @objc func changed(_ popup: NSPopUpButton) {
            guard parent.options.indices.contains(popup.indexOfSelectedItem), parent.options[popup.indexOfSelectedItem].available else { return }
            parent.selection = parent.options[popup.indexOfSelectedItem].id
        }
    }
}


/// The popup still owns its bezel, menu, focus, selection and AX value. Its
/// title cell centers the final native glyph run, including descenders, within
/// the common row axis rather than centering the font's line rectangle.
private final class SettingsFontPickerCell: NSPopUpButtonCell {
    private var rasterKey = ""
    private var raster: GroupHeaderInkView.InkRaster?
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let scale = controlView.window?.backingScaleFactor ?? 1
        let key = "\(title)|\(controlView.effectiveAppearance.name)|\(scale)"
        if key != rasterKey {
            rasterKey = key
            controlView.effectiveAppearance.performAsCurrentDrawingAppearance {
                raster = GroupHeaderInkView.inkImage(size: title.size(), scale: scale,
                    colorSpace: controlView.window?.colorSpace ?? .sRGB) { title.draw(at: $0) }
            }
        }
        guard let raster else { return super.drawTitle(title, withFrame: frame, in: controlView) }
        let inkCenter = controlView.isFlipped ? raster.size.height - raster.alignmentRect.midY : raster.alignmentRect.midY
        let rect = CGRect(x: frame.minX - raster.alignmentRect.minX,
                          y: ((controlView.bounds.midY - inkCenter) * scale).rounded() / scale,
                          width: raster.size.width, height: raster.size.height)
        NSImage(cgImage: raster.image, size: raster.size).draw(in: rect, from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return rect
    }
}
