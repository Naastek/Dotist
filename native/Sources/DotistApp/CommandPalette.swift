import AppKit
import DotistCore
import SwiftUI

enum CommandPaletteVisibility {
    enum Action { case show, hide }
    static func action(isVisible: Bool) -> Action { isVisible ? .hide : .show }
}

struct CommandPalette: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    let reveal: (DotistTask) -> Void
    let revealGroup: (DotistGroup) -> Void
    let showViews: () -> Void
    @State private var query = ""
    @State private var selectedID: String?
    @State private var scrollRequest: String?
    @State private var pointerAtKeyMove: NSPoint?
    @FocusState private var focused: Bool

    private enum Result: Identifiable {
        case task(DotistTask), group(DotistGroup), views
        var id: String {
            switch self {
            case .task(let task): return "task:" + task.id
            case .group(let group): return "group:" + group.id
            case .views: return "views"
            }
        }
    }

    private var results: [Result] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tasks = model.ordered(model.tasks.filter { query.isEmpty ? !$0.completed : $0.title.localizedCaseInsensitiveContains(query) })
        let groups = model.groups.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        return Array(tasks.prefix(query.isEmpty ? 8 : 40)).map(Result.task) + groups.map(Result.group)
            + (query.isEmpty || model.text("任务视图").localizedCaseInsensitiveContains(query) ? [.views] : [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(DotistDesign.font(14, language: model.language)).foregroundColor(DotistDesign.faint)
                TextField(model.text("搜索任务、分组或视图"), text: $query)
                    .textFieldStyle(.plain).font(DotistDesign.font(16, language: model.language)).accessibilityLabel(model.text("搜索任务、分组或视图")).focused($focused).onSubmit(openSelected)
            }.padding(.horizontal, 12).frame(height: 44)
                .overlay(alignment: .bottom) { Rectangle().fill(DotistDesign.rule).frame(height: 0.5) }
                .padding(.horizontal, 12).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if results.isEmpty {
                            Text(model.text("没有找到匹配的内容")).font(DotistDesign.font(13, language: model.language)).foregroundColor(DotistDesign.muted).padding(28)
                        }
                        ForEach(results) { result in
                            Button { selectedID = result.id; openSelected() } label: {
                                row(result).padding(.horizontal, 18).frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .onHover { hovering in
                                    if hovering && NSEvent.mouseLocation != pointerAtKeyMove { selectedID = result.id }
                                }
                                .id(result.id)
                        }
                    }.padding(.vertical, 8)
                }.onChange(of: scrollRequest) { id in if let id { proxy.scrollTo(id) } }
            }
        }
        .accessibilityIdentifier("search-drag-handle")
        .foregroundColor(DotistDesign.ink)
        .background(WindowMaterial(opacity: 88, frost: model.settings.frost))
        .containerShape(.rect(cornerRadius: DotistDesign.windowCornerRadius))
        .clipShape(.rect(cornerRadius: DotistDesign.windowCornerRadius))
        .modifier(DotistTheme(theme: model.settings.theme))
        .onAppear {
            selectedID = results.first?.id
            // The AppKit panel becomes key after its hosting view is installed.
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: query) { _ in selectedID = results.first?.id }
        .onChange(of: model.tasks) { _ in
            if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
        }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onExitCommand(perform: close)
    }

    private func row(_ result: Result) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                switch result {
                case .task(let task):
                    Text(task.title).font(DotistDesign.font(13, weight: selectedID == result.id ? .medium : .regular, language: model.language)).lineLimit(1)
                    Text([model.group(for: task)?.name, task.dueDate.map(model.dueLabel)].compactMap { $0 }.joined(separator: " · "))
                        .font(DotistDesign.font(11, language: model.language)).foregroundColor(DotistDesign.muted)
                case .group(let group):
                    Text(group.name).font(DotistDesign.font(13, weight: selectedID == result.id ? .medium : .regular, language: model.language))
                    Text(model.text("分组")).font(DotistDesign.font(11, language: model.language)).foregroundColor(DotistDesign.muted)
                case .views:
                    Text(model.text("任务视图")).font(DotistDesign.font(13, weight: selectedID == result.id ? .medium : .regular, language: model.language))
                    Text(model.text("日历") + " · " + model.text("看板") + " · " + model.text("甘特")).font(DotistDesign.font(11, language: model.language)).foregroundColor(DotistDesign.muted)
                }
            }
            Spacer(minLength: 12)
        }.foregroundColor(selectedID == result.id ? DotistDesign.ink : DotistDesign.muted)
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

