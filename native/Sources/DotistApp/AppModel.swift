import AppKit
import DotistCore
import Foundation
import GRDB
import ServiceManagement

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
    @Published var focusNavigation = 0
    @Published var gotoGroup: String?
    @Published var undo: UndoEntry?
    @Published var scope = "all"
    @Published var scopeNavigation = 0
    @Published private(set) var launchAtLogin: Bool
    let databasePath: String
    let core: TaskStore
    let mcp: MCPService
    private let queue = DispatchQueue(label: "dev.dotist.native.store", qos: .userInitiated)
    private var observation: (any DatabaseCancellable)?
    private var pendingSnapshot: TaskSnapshot?
    private var groupsByID: [String: DotistGroup] = [:]
    private var hierarchy = TaskHierarchy([])
    private var childrenByParent: [String: [DotistTask]] = [:]
    private var tagsByID: [String: DotistTaskTags] = [:]
    private var roots: [DotistTask] = []
    private var remaining = 0
    private var next: DotistTask?
    private var sortedTags: [DotistTagCount] = []
    private var pendingChanges = 0
    private var dictionary: [String: [String: String]] = [:]

    init(store: TaskStore? = nil) throws {
        core = try store ?? TaskStore()
        mcp = MCPService(store: core)
        let snapshot = try core.snapshot()
        tasks = snapshot.tasks
        groups = snapshot.groups
        settings = try core.settings()
        tagDescription = snapshot.tags
        databasePath = try core.databasePath()
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
        rebuildIndexes()
        observation = core.observe(onError: { [weak self] error in
            Task { @MainActor in self?.error = error.localizedDescription }
        }, onChange: { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        })
    }

    deinit { observation?.cancel() }

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
    func group(for task: DotistTask) -> DotistGroup? { groupsByID[task.category] }
    func activeGroupNavigation(_ id: String) { gotoGroup = id; scopeNavigation += 1 }
    func children(of task: DotistTask) -> [DotistTask] { childrenByParent[task.id] ?? [] }
    func depth(of task: DotistTask) -> Int { depth(of: task.id) }
    func depth(of id: String) -> Int { hierarchy.depth(of: id) }
    func descendants(of task: DotistTask) -> [DotistTask] { descendants(of: task.id) }
    func descendants(of id: String) -> [DotistTask] { hierarchy.descendants(of: id) }
    func subtreeHeight(of task: DotistTask) -> Int { hierarchy.subtreeHeight(of: task.id) }
    func progress(of task: DotistTask) -> (done: Int, total: Int) {
        let children = children(of: task)
        return (children.filter(\.completed).count, children.count)
    }
    var displayTasks: [DotistTask] { activeTag == nil ? tasks : taggedTasks }
    var tagCounts: [DotistTagCount] { sortedTags }
    func visibleChildren(of task: DotistTask) -> [DotistTask] { children(of: task) }
    func tags(for task: DotistTask) -> DotistTaskTags? { tagsByID[task.id] }
    var topLevelTasks: [DotistTask] { roots }
    var remainingCount: Int { remaining }
    var nextTask: DotistTask? { next }
    var bubbleTitle: String {
        nextTask?.title ?? text(topLevelTasks.isEmpty ? "把要做的事，放在这里。" : "今天的事都做完了")
    }
    func ordered(_ values: [DotistTask]) -> [DotistTask] {
        values.sorted { $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position }
    }

    func refresh() {
        let core = core
        queue.async { [weak self] in
            do {
                let snapshot = try core.snapshot()
                DispatchQueue.main.async { self?.apply(snapshot) }
            } catch {
                DispatchQueue.main.async { self?.error = error.localizedDescription }
            }
        }
    }

    func selectTag(_ tag: String?) {
        let selected = tag.flatMap { value in tagCounts.contains(where: { $0.tag == value && $0.open > 0 }) ? value : nil }
        activeTag = selected
        guard let tag = selected else { taggedTasks = []; return }
        taggedTasks = TaskTags.filter(tasks, tag: tag, description: tagDescription)
    }

    private func apply(_ snapshot: TaskSnapshot) {
        guard dragId == nil else { pendingSnapshot = snapshot; return }
        guard tasks != snapshot.tasks || groups != snapshot.groups else { return }
        tasks = snapshot.tasks
        groups = snapshot.groups
        tagDescription = snapshot.tags
        rebuildIndexes()
        if let tag = activeTag {
            if !tagCounts.contains(where: { $0.tag == tag && $0.open > 0 }) { activeTag = nil; taggedTasks = [] }
            else { taggedTasks = TaskTags.filter(tasks, tag: tag, description: tagDescription) }
        }
    }

    private func rebuildIndexes() {
        hierarchy = TaskHierarchy(tasks)
        groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        childrenByParent = Dictionary(grouping: tasks.filter { $0.parentId != nil }, by: { $0.parentId! }).mapValues(ordered)
        tagsByID = Dictionary(uniqueKeysWithValues: tagDescription.tasks.map { ($0.id, $0) })
        roots = tasks.filter { $0.parentId == nil }
        remaining = roots.filter { !$0.completed }.count
        let grouped = Dictionary(grouping: roots.filter { !$0.completed }, by: \.category).mapValues(ordered)
        next = groups.lazy.compactMap { grouped[$0.id]?.first }.first
        sortedTags = tagDescription.counts.sorted { $0.open == $1.open ? $0.tag.localizedCompare($1.tag) == .orderedAscending : $0.open > $1.open }
    }

    func beginDrag(_ id: String, scope: String) {
        dragId = id
        dragScope = scope
    }
    func endDrag() {
        dragId = nil
        dragScope = nil
        if let snapshot = pendingSnapshot { pendingSnapshot = nil; apply(snapshot) }
    }

    func change(completed: (() -> Void)? = nil, failed: (() -> Void)? = nil, _ operation: @escaping (TaskStore) throws -> Void) {
        pendingChanges += 1
        busy = true
        let core = core
        queue.async { [weak self] in
            do {
                try operation(core)
                DispatchQueue.main.async {
                    self?.pendingChanges -= 1
                    self?.busy = (self?.pendingChanges ?? 0) > 0
                    self?.error = nil
                    completed?()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.pendingChanges -= 1
                    self?.busy = (self?.pendingChanges ?? 0) > 0
                    self?.error = self?.text(error.localizedDescription) ?? error.localizedDescription
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

    /// The active drag remains frozen until the UI ends its session. The store
    /// validates the anchor and commits the complete move in one transaction.
    func commitReorder(taskID: String, to target: TaskReorderEngine.Target, completed: (() -> Void)? = nil, failed: (() -> Void)? = nil) {
        var committedSnapshot: TaskSnapshot?
        change(completed: { [weak self] in
            // Publish the committed snapshot before the UI releases its frozen
            // drag. Database observation delivery may otherwise arrive later.
            if let committedSnapshot {
                self?.apply(committedSnapshot)
                self?.expanded.formUnion(TaskHierarchy(committedSnapshot.tasks).ancestors(of: taskID).map(\.id))
            }
            completed?()
        }, failed: failed) { store in
            try store.commitReorder(taskID, groupID: target.groupID, parentID: target.parentID, beforeID: target.beforeID)
            committedSnapshot = try store.snapshot()
        }
    }

    func indent(ids: [String], completed: (() -> Void)? = nil, failed: (() -> Void)? = nil) {
        changeHierarchy(completed: completed, failed: failed) { try $0.indent(ids: ids) }
    }
    func outdent(ids: [String], completed: (() -> Void)? = nil, failed: (() -> Void)? = nil) {
        changeHierarchy(completed: completed, failed: failed) { try $0.outdent(ids: ids) }
    }
    func indent(_ task: DotistTask, completed: (() -> Void)? = nil, failed: (() -> Void)? = nil) {
        indent(ids: [task.id], completed: completed, failed: failed)
    }
    func outdent(_ task: DotistTask, completed: (() -> Void)? = nil, failed: (() -> Void)? = nil) {
        outdent(ids: [task.id], completed: completed, failed: failed)
    }

    private func changeHierarchy(completed: (() -> Void)?, failed: (() -> Void)?, _ operation: @escaping (TaskStore) throws -> [DotistTask]) {
        var snapshot: TaskSnapshot?
        var parents: Set<String> = []
        change(completed: { [weak self] in
            if let snapshot { self?.apply(snapshot) }
            self?.expanded.formUnion(parents)
            completed?()
        }, failed: failed) { store in
            let moved = try operation(store)
            let committed = try store.snapshot()
            snapshot = committed
            let hierarchy = TaskHierarchy(committed.tasks)
            for task in moved { parents.formUnion(hierarchy.ancestors(of: task.id).map(\.id)) }
        }
    }

    func updateSettings(_ patch: DotistSettingsPatch, completed: ((Bool) -> Void)? = nil) {
        let core = core
        queue.async { [weak self] in
            do {
                let settings = try core.updateSettings(patch)
                DispatchQueue.main.async {
                    self?.settings = settings
                    if settings.mcpEnabled { self?.mcp.start() } else { self?.mcp.stop() }
                    completed?(true)
                }
            } catch {
                DispatchQueue.main.async { self?.error = error.localizedDescription; completed?(false) }
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch { self.error = error.localizedDescription }
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
