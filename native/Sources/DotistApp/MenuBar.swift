import AppKit
import Combine
import DotistCore
import Foundation

@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let perform: (String) -> Void
    private let now: () -> Date
    private(set) var item: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var rotateTimer: Timer?
    private var rotateInterval: UInt16?
    private var rotation = 0

    init(model: AppModel, now: @escaping () -> Date = Date.init, perform: @escaping (String) -> Void) {
        self.model = model
        self.perform = perform
        self.now = now
        super.init()
        // Published properties emit in willSet; defer until the whole snapshot is applied.
        model.$tasks.combineLatest(model.$groups, model.$settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.refresh() }
            .store(in: &subscriptions)
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        }
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
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            self.item = item
        }
        let countMode = model.settings.trayMode == "count"
        let group = selectedGroup()
        let count = countMode ? MenuBarImage.todayCount(tasks: model.tasks, groupID: group == "all" ? nil : group, now: now()) : nil
        let description = count.map { model.text("今天还有 {n} 件未完成任务").replacingOccurrences(of: "{n}", with: "\($0)") } ?? "Dotist"
        item?.button?.image = MenuBarImage.make(count: count, accessibilityDescription: description)
        item?.button?.imagePosition = .imageLeading
        item?.button?.toolTip = description
        item?.button?.setAccessibilityLabel(description)
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
    private func selectedGroup() -> String {
        let group = model.settings.trayGroup
        return group == "all" || model.groups.contains(where: { $0.id == group }) ? group : "all"
    }

    private func statusTitles() -> [String] {
        let prefs = model.settings
        guard ["next", "next_date", "rotate"].contains(prefs.trayMode) else { return [] }
        let selectedGroup = selectedGroup()
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
        case "next": return [list.first.map { title($0, includeDate: false) } ?? model.text("没有待办")]
        case "next_date": return [list.first.map { title($0, includeDate: true) } ?? model.text("没有待办")]
        case "rotate": return [model.text("还有 {n} 件").replacingOccurrences(of: "{n}", with: "\(values.count)")] + list.prefix(4).map { title($0, includeDate: true) }
        default: return []
        }
    }
}

/// A single template image lets the system supply the correct menu-bar tint.
enum MenuBarImage {
    static let size = NSSize(width: 26, height: 18)

    static func todayCount(tasks: [DotistTask], groupID: String?, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let sections = TaskFiltering(tasks, now: now, calendar: calendar).todaySections(groupID: groupID)
        return sections.overdue.matches.count + sections.today.matches.count
    }

    static func make(count: Int?, accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            let circle = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 16, height: 16))
            circle.lineWidth = 1
            circle.stroke()
            NSBezierPath(ovalIn: NSRect(x: 20, y: 7.5, width: 3, height: 3)).fill()
            if let count {
                let label = count > 99 ? "99+" : "\(count)"
                let font = NSFont.monospacedDigitSystemFont(ofSize: count > 99 ? 6.5 : (count > 9 ? 8 : 10), weight: .medium)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
                let text = NSAttributedString(string: label, attributes: attributes)
                let textSize = text.size()
                text.draw(at: NSPoint(x: 9 - textSize.width / 2, y: 9 - textSize.height / 2))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
