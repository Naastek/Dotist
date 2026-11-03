import AppKit
import DotistCore
import SwiftUI

enum CommandPaletteVisibility {
    enum Action { case show, hide }
    static func action(isVisible: Bool) -> Action { isVisible ? .hide : .show }
}

/// The palette is a resizable overlay, so its height is derived from the same
/// values that lay it out: a search field, section headers, single-line rows and
/// a footer. Few results produce a short panel instead of a mostly empty one.
enum PaletteMetrics {
    static let width: CGFloat = 640
    static let searchRow: CGFloat = 52
    static let footer: CGFloat = 32
    static let row: CGFloat = 38
    static let headerTop: CGFloat = 18
    static let headerLine: CGFloat = 14
    static let headerBottom: CGFloat = 4
    static let listBottom: CGFloat = 10
    static let emptyContent: CGFloat = 128
    static let maxHeight: CGFloat = 520

    static func height(sectionCounts: [Int]) -> CGFloat {
        guard !sectionCounts.isEmpty else { return searchRow + emptyContent + footer }
        let list = sectionCounts.reduce(CGFloat.zero) { total, count in
            total + headerTop + headerLine + headerBottom + CGFloat(count) * row
        }
        return min(maxHeight, searchRow + list + listBottom + footer)
    }
}

enum PaletteItem: Identifiable {
    case task(DotistTask), group(DotistGroup), views
    var id: String {
        switch self {
        case .task(let task): return "task:" + task.id
        case .group(let group): return "group:" + group.id
        case .views: return "views"
        }
    }
}

struct CommandPaletteSections: Identifiable {
    let title: String
    let items: [PaletteItem]
    var id: String { title }
    static func build(query raw: String, tasks: [DotistTask], groups: [DotistGroup], viewsTitle: String) -> [CommandPaletteSections] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingTasks = tasks.filter { query.isEmpty ? !$0.completed : $0.title.localizedCaseInsensitiveContains(query) }
        let matchingGroups = groups.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        let sections = [
            CommandPaletteSections(title: "任务", items: Array(matchingTasks.prefix(query.isEmpty ? 6 : 30)).map(PaletteItem.task)),
            CommandPaletteSections(title: "分组", items: Array(matchingGroups.prefix(query.isEmpty ? 6 : 30)).map(PaletteItem.group)),
            CommandPaletteSections(title: "视图", items: query.isEmpty || viewsTitle.localizedCaseInsensitiveContains(query) ? [.views] : [])
        ]
        return sections.filter { !$0.items.isEmpty }
    }
}

struct CommandPalette: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    let reveal: (DotistTask) -> Void
    let revealGroup: (DotistGroup) -> Void
    let showViews: () -> Void
    var resize: (CGFloat) -> Void = { _ in }
    @State private var query = ""
    @State private var selectedID: String?
    @State private var scrollRequest: String?
    @State private var pointerAtKeyMove: NSPoint?
    @FocusState private var focused: Bool

    private var sections: [CommandPaletteSections] {
        CommandPaletteSections.build(query: query, tasks: model.ordered(model.tasks), groups: model.groups, viewsTitle: model.text("任务视图"))
    }
    private var results: [PaletteItem] { sections.flatMap(\.items) }
    private var metricsHeight: CGFloat { PaletteMetrics.height(sectionCounts: sections.map(\.items.count)) }

    var body: some View {
        VStack(spacing: 0) {
            SearchRow(text: $query, placeholder: model.text("搜索任务、分组或视图"), language: model.language, size: 16, iconSize: 14, focusOnAppear: true, commit: openSelected, navigate: { direction in move(direction); return true }, cancel: close)
                .accessibilityIdentifier("command-search")
                .frame(height: PaletteMetrics.searchRow)
                .overlay(alignment: .bottom) { Rectangle().fill(DotistDesign.rule).frame(height: 0.5) }
                .padding(.horizontal, 20)
            if results.isEmpty {
                Text(model.text("没有找到匹配的内容")).font(DotistDesign.font(13, language: model.language)).foregroundColor(DotistDesign.faint)
                    .frame(maxWidth: .infinity, minHeight: PaletteMetrics.emptyContent, maxHeight: .infinity)
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(model.text(section.title)).font(DotistDesign.font(12, weight: .medium, language: model.language)).foregroundColor(DotistDesign.muted)
                                .frame(height: PaletteMetrics.headerLine, alignment: .bottomLeading)
                                .padding(.leading, 20).padding(.top, PaletteMetrics.headerTop).padding(.bottom, PaletteMetrics.headerBottom)
                            ForEach(section.items) { result in
                                Button { selectedID = result.id; openSelected() } label: {
                                    row(result).padding(.horizontal, 20).frame(height: PaletteMetrics.row).contentShape(Rectangle())
                                        .overlay(alignment: .bottom) {
                                            if selectedID == result.id { Rectangle().fill(DotistDesign.accent).frame(height: 2).padding(.horizontal, 20) }
                                        }
                                }.buttonStyle(.plain)
                                    .onHover { hovering in
                                        if hovering && NSEvent.mouseLocation != pointerAtKeyMove { selectedID = result.id }
                                    }.id(result.id)
                            }
                        }
                    }
                    Color.clear.frame(height: PaletteMetrics.listBottom)
                }.onChange(of: scrollRequest) { id in if let id { proxy.scrollTo(id) } }
            }
            }
            Text(model.text("↑↓ 选择　↵ 打开　esc 关闭"))
                .font(DotistDesign.font(11, language: model.language)).foregroundColor(DotistDesign.muted)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).frame(height: PaletteMetrics.footer)
                .overlay(alignment: .top) { Rectangle().fill(DotistDesign.rule).frame(height: 0.5) }
        }
        .accessibilityIdentifier("search-drag-handle")
        .foregroundColor(DotistDesign.ink)
        .background(WindowMaterial(opacity: 98, frost: model.settings.frost))
        .containerShape(.rect(cornerRadius: DotistDesign.windowCornerRadius))
        .clipShape(.rect(cornerRadius: DotistDesign.windowCornerRadius))
        .modifier(DotistTheme(theme: model.settings.theme))
        .onAppear {
            selectedID = results.first?.id
            resize(metricsHeight)
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: query) { _ in selectedID = results.first?.id }
        .onChange(of: metricsHeight) { height in resize(height) }
        .onChange(of: model.tasks) { _ in if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id } }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onExitCommand(perform: close)
    }
    private func row(_ result: PaletteItem) -> some View {
        let title: String
        let metadata: String
        switch result {
        case .task(let task):
            title = task.title
            metadata = [model.group(for: task)?.name, task.dueDate.map(model.dueLabel)].compactMap { $0 }.joined(separator: " · ")
        case .group(let group):
            title = group.name
            let open = model.tasks.filter { $0.category == group.id && !$0.completed }.count
            metadata = open == 0 ? "" : "\(open) \(model.text("项"))"
        case .views: title = model.text("任务视图"); metadata = [model.text("日历"), model.text("看板"), model.text("甘特")].joined(separator: " · ")
        }
        return HStack(spacing: 12) {
            Text(title).font(DotistDesign.font(14, weight: selectedID == result.id ? .semibold : .regular, language: model.language))
                .foregroundColor(DotistDesign.ink).lineLimit(1)
            Spacer(minLength: 12)
            Text(metadata).font(DotistDesign.font(12, language: model.language)).foregroundColor(DotistDesign.muted).lineLimit(1)
        }
    }
    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex(where: { $0.id == selectedID }) ?? -1
        selectedID = results[min(max(current + delta, 0), results.count - 1)].id
        scrollRequest = selectedID
        pointerAtKeyMove = NSEvent.mouseLocation
    }
    private func openSelected() {
        guard let selected = results.first(where: { $0.id == selectedID }) else { return }
        close()
        switch selected {
        case .task(let task): reveal(task)
        case .group(let group): revealGroup(group)
        case .views: showViews()
        }
    }
}
