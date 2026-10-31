import AppKit
import Combine
import DotistCore
import Foundation

@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let perform: (String) -> Void
    private var item: NSStatusItem?
    private var subscription: AnyCancellable?
    private var rotateTimer: Timer?
    private var rotateInterval: UInt16?
    private var rotation = 0

    init(model: AppModel, perform: @escaping (String) -> Void) {
        self.model = model
        self.perform = perform
        super.init()
        subscription = model.$tasks.combineLatest(model.$groups, model.$settings).sink { [weak self] _, _, _ in self?.refresh() }
    }
    deinit { rotateTimer?.invalidate() }

    private func refresh() {
        guard model.settings.showMenubar else {
            if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
            rotateTimer?.invalidate(); rotateTimer = nil
            return
        }
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let image = Bundle.main.url(forResource: "menubar", withExtension: "png").flatMap(NSImage.init(contentsOf:)) ?? NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Dotist")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            item.button?.image = image
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            self.item = item
        }
        let titles = statusTitles()
        item?.button?.title = titles.isEmpty ? "" : " " + titles[rotation % titles.count]
        if model.settings.trayMode == "rotate" && (rotateTimer == nil || rotateInterval != model.settings.trayRotateSecs) {
            rotateTimer?.invalidate()
            rotateInterval = model.settings.trayRotateSecs
            rotateTimer = Timer.scheduledTimer(withTimeInterval: Double(model.settings.trayRotateSecs), repeats: true) { [weak self] _ in
                Task { @MainActor in self?.rotate() }
            }
        } else if model.settings.trayMode != "rotate" {
            rotateTimer?.invalidate(); rotateTimer = nil; rotateInterval = nil
        }
    }

    private func rotate() { rotation += 1; refresh() }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let action = NSApp.currentEvent?.type == .rightMouseUp ? model.settings.trayRightClick : model.settings.trayLeftClick
        if action != "menu" { perform(action); return }
        guard let item else { return }
        item.menu = buildMenu()
        sender.performClick(nil)
        item.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: String, translate: Bool = true, key: String = "", modifiers: NSEvent.ModifierFlags = .command, indented: Bool = false) {
            let entry = NSMenuItem(title: translate ? model.text(title) : title, action: #selector(menuAction(_:)), keyEquivalent: key)
            entry.target = self; entry.representedObject = action
            entry.keyEquivalentModifierMask = modifiers
            if indented { entry.indentationLevel = 2 }
            menu.addItem(entry)
        }
        add("显示窗口", "show")
        add("收起为悬浮球", "collapse")
        add("任务视图", "views")
        add("快速添加", "quick")
        menu.addItem(.separator())
        let groupHeader = NSMenuItem(title: model.text("分组"), action: nil, keyEquivalent: ""); groupHeader.isEnabled = false; menu.addItem(groupHeader)
        add("全部分组", "group:all", key: "0", indented: true)
        for (index, group) in model.groups.enumerated() {
            add(group.name, "group:" + group.id, translate: false, key: index < 9 ? "\(index + 1)" : "", indented: true)
        }
        menu.addItem(.separator())
        let filterHeader = NSMenuItem(title: model.text("日期透视"), action: nil, keyEquivalent: ""); filterHeader.isEnabled = false; menu.addItem(filterHeader)
        for (index, filter) in model.settings.filters.enumerated() {
            add(filterLabel(filter), "filter:" + filter, key: index < 9 ? "\(index + 1)" : "", modifiers: [.command, .option], indented: true)
        }
        menu.addItem(.separator())
        add("设置…", "settings")
        add("退出 Dotist", "quit")
        return menu
    }
    @objc private func menuAction(_ sender: NSMenuItem) { if let action = sender.representedObject as? String { perform(action) } }

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
    private func statusTitles() -> [String] {
        let prefs = model.settings
        let selectedGroup = prefs.trayGroup == "all" || model.groups.contains(where: { $0.id == prefs.trayGroup }) ? prefs.trayGroup : "all"
        let today = Date().dotistDay
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: start)
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: start)!
        let values = model.tasks.filter { task in
            guard selectedGroup == "all" || selectedGroup == task.category else { return false }
            let due = task.dueDate
            switch prefs.trayFilter {
            case "all": return !task.completed && task.parentId == nil
            case "today": return !task.completed && due.map { $0 <= today } == true
            case "overdue": return !task.completed && due.map { $0 < today } == true
            case "undated": return !task.completed && due == nil && task.parentId == nil
            case "done": return task.completed
            case "tomorrow": return !task.completed && due == calendar.date(byAdding: .day, value: 1, to: start)?.dotistDay
            case "week": return !task.completed && due.map { $0 >= monday.dotistDay && $0 <= calendar.date(byAdding: .day, value: 6, to: monday)!.dotistDay } == true
            case "nextweek": return !task.completed && due.map { $0 >= calendar.date(byAdding: .day, value: 7, to: monday)!.dotistDay && $0 <= calendar.date(byAdding: .day, value: 13, to: monday)!.dotistDay } == true
            case "next7": return !task.completed && due.map { $0 >= today && $0 <= calendar.date(byAdding: .day, value: 6, to: start)!.dotistDay } == true
            default: return false
            }
        }
        let list = values.sorted { a, b in
            if prefs.trayFilter == "done" { return a.updatedAt > b.updatedAt }
            if a.dueDate != b.dueDate { return (a.dueDate ?? "9999-99-99") < (b.dueDate ?? "9999-99-99") }
            let ai = model.groups.firstIndex { $0.id == a.category } ?? 0
            let bi = model.groups.firstIndex { $0.id == b.category } ?? 0
            return ai == bi ? a.position < b.position : ai < bi
        }
        func title(_ task: DotistTask, includeDate: Bool) -> String {
            let value = includeDate && task.dueDate != nil ? "\(model.dueLabel(task.dueDate!)) \(task.title)" : task.title
            return value.count > 24 ? String(value.prefix(23)) + "…" : value
        }
        switch prefs.trayMode {
        case "count": return ["\(values.count)"]
        case "next": return [list.first.map { title($0, includeDate: false) } ?? model.text("没有待办")]
        case "next_date": return [list.first.map { title($0, includeDate: true) } ?? model.text("没有待办")]
        case "rotate": return [model.text("还有 {n} 件").replacingOccurrences(of: "{n}", with: "\(values.count)")] + list.prefix(4).map { title($0, includeDate: true) }
        default: return []
        }
    }
}
