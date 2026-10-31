import AppKit
import DotistCore
import Foundation

@MainActor
final class AppModel: ObservableObject {
    struct UndoEntry { let id: String; let title: String; let group: Bool }
    @Published private(set) var tasks: [DotistTask]
    @Published private(set) var groups: [DotistGroup]
    @Published private(set) var settings: DotistSettings
    @Published private(set) var tagDescription: DotistTagDescription
    @Published private(set) var activeTag: String?
    @Published private var taggedTasks: [DotistTask] = []
    @Published var error: String?
    @Published var busy = false
    @Published var expanded: Set<String> = []
    @Published var folded: Set<String> = []
    @Published private(set) var dragId: String?
    @Published private(set) var dragScope: String?
    @Published var focusId: String?
    @Published var gotoGroup: String?
    @Published var undo: UndoEntry?
    @Published var scope = "all"
    @Published var scopeNavigation = 0
    @Published private(set) var launchAtLogin: Bool
    let databasePath: String
    private let loginAppName: String
    private let executable: String
    private let core: RustTaskStore
    private let queue = DispatchQueue(label: "dev.dotist.native.store", qos: .userInitiated)
    private var timer: Timer?
    private var pendingChanges = 0
    private var dragTimer: Timer?
    private var dragGeneration = 0
    private var dictionary: [String: [String: String]] = [:]

    init() throws {
        core = try RustTaskStore()
        tasks = try core.listTasks()
        groups = try core.listGroups()
        settings = try core.settings()
        tagDescription = try core.describeTags()
        databasePath = try core.databasePath()
        loginAppName = Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa" ? "Dotist Native QA" : "Dotist"
        executable = Bundle.main.executableURL?.path ?? ""
        launchAtLogin = try core.launchAtLogin(appName: loginAppName, executable: executable)
        scope = settings.defaultFilter
        if let url = Bundle.main.url(forResource: "locales", withExtension: "json") ?? Bundle.module.url(forResource: "locales", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            dictionary = (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
        }
        if let url = Bundle.main.url(forResource: "native-locales", withExtension: "json") ?? Bundle.module.url(forResource: "native-locales", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let extra = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            for (language, values) in extra { dictionary[language, default: [:]].merge(values) { _, new in new } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate(); dragTimer?.invalidate() }

    var language: String {
        let setting = settings.language
        let code = setting == "system" ? (Locale.preferredLanguages.first ?? "en") : setting
        let lower = code.lowercased()
        if lower.hasPrefix("zh") {
            return lower.contains("hant") || lower.contains("-tw") || lower.contains("-hk") || lower.contains("-mo") ? "zh-TW" : "zh-CN"
        }
        return lower.hasPrefix("ja") ? "ja" : "en"
    }

    func text(_ source: String) -> String { dictionary[language]?[source] ?? source }
    func dueLabel(_ value: String) -> String {
        guard let date = Date.dotistDay(value) else { return value }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
        if days == -1 { return text("昨天") }
        if days == 0 { return text("今天") }
        if days == 1 { return text("明天") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        formatter.setLocalizedDateFormatFromTemplate(days > 1 && days <= 6 ? "EEE" : sameYear ? "MMMd" : "yyyyMMMd")
        return formatter.string(from: date)
    }
    func group(for task: DotistTask) -> DotistGroup? { groups.first { $0.id == task.category } }
    func children(of task: DotistTask) -> [DotistTask] { ordered(tasks.filter { $0.parentId == task.id }) }
    var displayTasks: [DotistTask] { activeTag == nil ? tasks : taggedTasks }
    var tagCounts: [DotistTagCount] { tagDescription.counts.sorted { $0.open == $1.open ? $0.tag.localizedCompare($1.tag) == .orderedAscending : $0.open > $1.open } }
    func visibleChildren(of task: DotistTask) -> [DotistTask] { ordered(displayTasks.filter { $0.parentId == task.id }) }
    func tags(for task: DotistTask) -> DotistTaskTags? { tagDescription.tasks.first { $0.id == task.id } }
    var topLevelTasks: [DotistTask] { tasks.filter { $0.parentId == nil } }
    var remainingCount: Int { topLevelTasks.filter { !$0.completed }.count }
    var nextTask: DotistTask? {
        for group in groups {
            if let task = ordered(topLevelTasks.filter { $0.category == group.id && !$0.completed }).first { return task }
        }
        return nil
    }
    var bubbleTitle: String {
        nextTask?.title ?? text(topLevelTasks.isEmpty ? "把要做的事，放在这里。" : "今天的事都做完了")
    }
    var bubbleDetail: String {
        nextTask == nil ? "" : text("还有 {n} 件").replacingOccurrences(of: "{n}", with: "\(remainingCount)")
    }
    func ordered(_ values: [DotistTask]) -> [DotistTask] {
        values.sorted { $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position }
    }

    func refresh() {
        guard dragId == nil else { return }
        let core = core
        let tag = activeTag
        queue.async { [weak self] in
            do {
                let tasks = try core.listTasks()
                let groups = try core.listGroups()
                let tags = try core.describeTags()
                let filtered = try tag.map { try core.filterByTag($0) } ?? []
                DispatchQueue.main.async {
                    guard let self, self.dragId == nil else { return }
                    if self.tasks != tasks { self.tasks = tasks }
                    if self.groups != groups { self.groups = groups }
                    if self.tagDescription != tags { self.tagDescription = tags }
                    if self.activeTag == tag {
                        if let tag, !tags.counts.contains(where: { $0.tag == tag && $0.open > 0 }) { self.activeTag = nil; self.taggedTasks = [] }
                        else if self.taggedTasks != filtered { self.taggedTasks = filtered }
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.error = error.localizedDescription }
            }
        }
    }

    func selectTag(_ tag: String?) {
        let selected = tag.flatMap { value in tagCounts.contains(where: { $0.tag == value && $0.open > 0 }) ? value : nil }
        activeTag = selected
        guard let tag = selected else { taggedTasks = []; return }
        let core = core
        queue.async { [weak self] in
            do {
                let filtered = try core.filterByTag(tag)
                DispatchQueue.main.async { if self?.activeTag == tag { self?.taggedTasks = filtered } }
            } catch { DispatchQueue.main.async { self?.error = error.localizedDescription } }
        }
    }

    func beginDrag(_ id: String, scope: String) {
        dragGeneration += 1
        let generation = dragGeneration
        dragId = id
        dragScope = scope
        dragTimer?.invalidate()
        dragTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self, self.dragGeneration == generation, self.dragId != nil else { return }
                self.endDrag()
                self.refresh()
            }
        }
    }
    func endDrag() {
        dragTimer?.invalidate()
        dragTimer = nil
        dragId = nil
        dragScope = nil
    }

    func change(completed: (() -> Void)? = nil, failed: (() -> Void)? = nil, _ operation: @escaping (RustTaskStore) throws -> Void) {
        pendingChanges += 1
        busy = true
        let core = core
        let tag = activeTag
        queue.async { [weak self] in
            do {
                try operation(core)
                let tasks = try core.listTasks()
                let groups = try core.listGroups()
                let tags = try core.describeTags()
                let filtered = try tag.map { try core.filterByTag($0) } ?? []
                DispatchQueue.main.async {
                    self?.tasks = tasks
                    self?.groups = groups
                    self?.tagDescription = tags
                    if self?.activeTag == tag {
                        if let tag, !tags.counts.contains(where: { $0.tag == tag && $0.open > 0 }) { self?.activeTag = nil; self?.taggedTasks = [] }
                        else { self?.taggedTasks = filtered }
                    }
                    self?.pendingChanges -= 1
                    self?.busy = (self?.pendingChanges ?? 0) > 0
                    self?.error = nil
                    completed?()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.pendingChanges -= 1
                    self?.busy = (self?.pendingChanges ?? 0) > 0
                    self?.error = error.localizedDescription
                    failed?()
                }
            }
        }
    }

    func complete(_ task: DotistTask) { change { _ = try $0.patchTask(id: task.id, completed: !task.completed) } }
    func delete(_ task: DotistTask) {
        change(completed: { [weak self] in self?.undo = UndoEntry(id: task.id, title: task.title, group: false) }) { try $0.deleteTask(task.id) }
    }
    func deleteGroup(_ group: DotistGroup) {
        change(completed: { [weak self] in self?.undo = UndoEntry(id: group.id, title: group.name, group: true) }) { try $0.deleteGroup(group.id) }
    }
    func restore() {
        guard let item = undo else { return }
        change(completed: { [weak self] in self?.undo = nil }) {
            if item.group { _ = try $0.restoreGroup(item.id) } else { _ = try $0.restoreTask(item.id) }
        }
    }
    func reorder(_ id: String, relativeTo target: String, after: Bool, allTasks: Bool) {
        guard id != target else { return }
        change { try $0.reorder(id, relativeTo: target, after: after, allTasks: allTasks) }
    }

    func updateSettings(_ patch: DotistSettingsPatch, completed: ((Bool) -> Void)? = nil) {
        let core = core
        queue.async { [weak self] in
            do {
                let settings = try core.updateSettings(patch)
                DispatchQueue.main.async { self?.settings = settings; completed?(true) }
            } catch {
                DispatchQueue.main.async { self?.error = error.localizedDescription; completed?(false) }
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let core = core
        let name = loginAppName
        let executable = executable
        queue.async { [weak self] in
            do {
                let enabled = try core.setLaunchAtLogin(appName: name, executable: executable, enabled: enabled)
                DispatchQueue.main.async { self?.launchAtLogin = enabled }
            } catch {
                DispatchQueue.main.async { self?.error = error.localizedDescription }
            }
        }
    }
}

extension Date {
    var dotistDay: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }

    static func dotistDay(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
