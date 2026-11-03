import AppKit
import Combine
import DotistCore
import Foundation
import GRDB
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    struct UndoEntry { let id: String; let title: String; let group: Bool }
    @Published private(set) var tasks: [DotistTask] { didSet { filterCache.removeAll(keepingCapacity: true) } }
    /// Rendering asks for the same per-group filters on every frame of a drag.
    private var filterCache: [String: TaskFilterResult] = [:]
    @Published private(set) var groups: [DotistGroup]
    @Published private(set) var settings: DotistSettings {
        didSet { DotistDesign.fontPreferences = settings.fontPreferences }
    }
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
    @Published var canUndoAction = false
    @Published var canRedoAction = false
    var undoHistory: [TaskMutationPatch] = []
    var redoHistory: [TaskMutationPatch] = []
    var historyActionInFlight = false
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
    private var dateFilterObservers = Set<AnyCancellable>()

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
        DotistDesign.fontPreferences = settings.fontPreferences
        rebuildIndexes()
        // A stationary panel must recompute relative filters at midnight and
        // when the system changes its time zone or calendar preferences.
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.objectWillChange.send() }
            }.store(in: &dateFilterObservers)
        }
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
        if lower.hasPrefix("fr") { return "fr" }
        return lower.hasPrefix("de") ? "de" : "en"
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
    func group(for task: DotistTask) -> DotistGroup? { task.category == DotistGroup.inboxID ? nil : groupsByID[task.category] }
    var visibleGroups: [DotistGroup] {
        groups.filter { $0.id != DotistGroup.inboxID }.sorted {
            $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position
        }
    }
    /// Root rows for the unheaded section in All; descendants are rendered with their parent.
    var ungroupedTasks: [DotistTask] { ordered(displayTasks.filter { $0.category == DotistGroup.inboxID && $0.parentId == nil }) }
    func groupDisplayName(_ id: String?) -> String {
        guard let id, id != DotistGroup.inboxID else { return text("无分组") }
        return groupsByID[id]?.name ?? text("无分组")
    }
    /// The composer uses All for its implicit inbox; other surfaces keep No Group.
    func composerGroupDisplayName(_ id: String?) -> String {
        guard let id, id != DotistGroup.inboxID else { return text("全部") }
        return groupDisplayName(id)
    }
    func themeColor(forGroup id: String?) -> DotistGroupColor {
        let fallback = DotistGroupColor(rawValue: settings.allColor)
        guard let id, let group = groupsByID[id] else { return fallback }
        let color = DotistGroupColor(rawValue: group.color)
        return color == .none ? fallback : color
    }
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
    var orderedTagCounts: [DotistTagCount] { TaskTags.orderedCounts(sortedTags, order: settings.tagOrder) }
    func visibleChildren(of task: DotistTask) -> [DotistTask] { children(of: task) }
    func tags(for task: DotistTask) -> DotistTaskTags? { tagsByID[task.id] }
    var topLevelTasks: [DotistTask] { roots }
    var remainingCount: Int { remaining }
    var nextTask: DotistTask? { next }
    var bubbleTitle: String {
        guard let nextTask else { return text(topLevelTasks.isEmpty ? "把要做的事，放在这里。" : "今天的事都做完了") }
        return BubbleContent.clean(nextTask.title) ?? text("未命名任务")
    }
    func ordered(_ values: [DotistTask]) -> [DotistTask] {
        values.sorted { $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position }
    }

    func filteredTasks(scope: String, groupID: String? = nil, tag: String? = nil,
                       customRange: TaskDateRange? = nil, completed: Bool = false,
                       now: Date = Date(), calendar: Calendar = .current) -> TaskFilterResult {
        // Only the default clock and calendar are cacheable; the key carries the day.
        let key = "\(scope)|\(groupID ?? "-")|\(tag ?? "-")|\(customRange.map { "\($0.start)-\($0.end)" } ?? "-")|\(completed)|\(Int(now.timeIntervalSinceReferenceDate / 60))|\(calendar.identifier)|\(calendar.firstWeekday)"
        if let hit = filterCache[key] { return hit }
        let result = TaskFiltering(tasks, now: now, calendar: calendar).filter(scope: scope, groupID: groupID, tag: tag,
                                                               customRange: customRange, completed: completed)
        if filterCache.count > 64 { filterCache.removeAll(keepingCapacity: true) }
        filterCache[key] = result
        return result
    }

    func todayTaskSections(groupID: String? = nil, tag: String? = nil,
                           now: Date = Date(), calendar: Calendar = .current) -> TaskTodaySections {
        TaskFiltering(tasks, now: now, calendar: calendar).todaySections(groupID: groupID, tag: tag)
    }

    func dateFilterRange(scope: String, now: Date = Date(), calendar: Calendar = .current) -> TaskDateRange {
        TaskFiltering([], now: now, calendar: calendar).range(scope: scope)
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
        next = grouped[DotistGroup.inboxID]?.first ?? visibleGroups.lazy.compactMap { grouped[$0.id]?.first }.first
        sortedTags = tagDescription.counts.sorted { $0.open == $1.open ? $0.tag.localizedCompare($1.tag) == .orderedAscending : $0.open > $1.open }
    }

    func beginDrag(_ id: String, scope: String) {
        dragId = id
        dragScope = scope
        updateHistoryAvailability()
    }
    func endDrag() {
        dragId = nil
        dragScope = nil
        if let snapshot = pendingSnapshot { pendingSnapshot = nil; apply(snapshot) }
        updateHistoryAvailability()
    }

    func change(recordHistory: Bool = true, completed: (() -> Void)? = nil, failed: (() -> Void)? = nil, _ operation: @escaping (TaskStore) throws -> Void) {
        pendingChanges += 1
        busy = true
        updateHistoryAvailability()
        let core = core
        queue.async { [weak self] in
            do {
                let patch: TaskMutationPatch?
                if recordHistory { patch = try core.captureChanges(operation) }
                else { try operation(core); patch = nil }
                let snapshot = try? core.snapshot()
                let settings = try? core.settings()
                DispatchQueue.main.async {
                    self?.pendingChanges -= 1
                    self?.busy = (self?.pendingChanges ?? 0) > 0
                    self?.error = nil
                    if let patch { self?.recordHistory(patch) }
                    if let settings { self?.settings = settings }
                    if let snapshot { self?.apply(snapshot) }
                    completed?()
                    self?.updateHistoryAvailability()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.pendingChanges -= 1
                    self?.busy = (self?.pendingChanges ?? 0) > 0
                    self?.error = self?.text(error.localizedDescription) ?? error.localizedDescription
                    failed?()
                    self?.updateHistoryAvailability()
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
    func moveGroup(_ id: String, toIndex: Int) { change { try $0.moveGroup(id, toIndex: toIndex) } }
    func setGroupColor(_ id: String, _ color: DotistGroupColor) { change { try $0.setGroupColor(id, color) } }
    func moveTag(_ tag: String, toIndex: Int) { change(recordHistory: false) { try $0.moveTag(tag, toIndex: toIndex) } }
    func deleteTag(_ tag: String) { change { try $0.retag(tag, replacement: nil) } }
    func renameTag(_ tag: String, to name: String) {
        let wasSelected = activeTag == tag
        let normalized = String(name.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "#" }).filter { !$0.isWhitespace }.prefix(24))
        guard !normalized.isEmpty else { return }
        change(completed: { [weak self] in
            if wasSelected { self?.selectTag(normalized) }
        }) { try $0.retag(tag, replacement: name) }
    }
    func restore() {
        guard let item = undo else { return }
        // The deletion banner and ⌘Z consume the same entry when possible.
        // Restoring from the banner must not add an inverse deletion entry.
        if canUndoAction, let patch = undoHistory.last,
           item.group ? patch.after.groups.contains(where: { $0.group.id == item.id && $0.deletedAt != nil })
                      : patch.after.tasks.contains(where: { $0.id == item.id && $0.deletedAt != nil }) {
            undoLast()
            return
        }
        let deletion = item.group ? undoHistory.last(where: {
            $0.after.groups.contains { $0.group.id == item.id && $0.deletedAt != nil }
        }) : nil
        change(completed: { [weak self] in self?.undo = nil }) {
            if let deletion { try $0.apply(patch: deletion.before) }
            else if item.group { _ = try $0.restoreGroup(item.id) }
            else { _ = try $0.restoreTask(item.id) }
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
