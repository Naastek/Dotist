import Foundation
import GRDB

public struct TaskStoreError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct TaskSnapshot: Equatable, Sendable {
    public let tasks: [DotistTask]
    public let groups: [DotistGroup]
    public let tags: DotistTagDescription
    public init(tasks: [DotistTask], groups: [DotistGroup]) {
        self.tasks = tasks
        self.groups = groups
        tags = TaskTags.describe(tasks)
    }
}

/// The UI and MCP share this queue, including its transactions and change observations.
public final class TaskStore: @unchecked Sendable {
    public let database: DatabaseQueue
    private let path: String
    private let preferences: SettingsStore

    public static var dataDirectory: URL {
        ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.dotist.app")
    }

    public init(databasePath: String? = nil) throws {
        path = databasePath ?? Self.dataDirectory.appendingPathComponent("tasks.sqlite").path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(3)
        database = try DatabaseQueue(path: path, configuration: configuration)
        let version = try database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        // v5 is the existing native data baseline. No old-client migration ladder or schema rewrite.
        guard version == 0 || version == 5 else {
            throw TaskStoreError("数据库不属于当前原生版本支持的数据格式，请使用备份或升级 Dotist")
        }
        if version == 0 {
            try database.write { db in
                try db.execute(sql: """
                    CREATE TABLE tasks (
                        id TEXT PRIMARY KEY, title TEXT NOT NULL, category TEXT NOT NULL,
                        completed INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL,
                        created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT,
                        revision INTEGER NOT NULL, remote_revision TEXT, parent_id TEXT, due_date TEXT,
                        status TEXT NOT NULL DEFAULT 'todo' CHECK(status IN ('todo','doing','done')),
                        start_date TEXT
                    );
                    CREATE INDEX task_order ON tasks(category,position,id);
                    CREATE INDEX task_parent ON tasks(parent_id);
                    CREATE INDEX task_due ON tasks(due_date);
                    CREATE INDEX task_status ON tasks(status,position,id);
                    CREATE TABLE task_groups (
                        id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL, position INTEGER NOT NULL,
                        created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
                    );
                    CREATE TABLE sync_outbox (
                        operation_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, kind TEXT NOT NULL,
                        base_revision INTEGER, payload TEXT NOT NULL, created_at TEXT NOT NULL
                    );
                    PRAGMA user_version=5;
                    """)
                for (position, pair) in [("work", "工作"), ("life", "生活"), ("study", "学习")].enumerated() {
                    try db.execute(sql: "INSERT INTO task_groups VALUES (?,?,?,?,?,?,NULL)",
                                   arguments: [pair.0, pair.1, pair.0, position, Self.timestamp(), Self.timestamp()])
                }
            }
        }
        // Add the system Inbox by identity; existing groups and task history stay intact.
        try database.write { db in
            let now = Self.timestamp()
            try db.execute(sql: """
                INSERT OR IGNORE INTO task_groups (id,name,color,position,created_at,updated_at)
                VALUES (?, 'Inbox', 'work', (SELECT COALESCE(MIN(position),0)-1 FROM task_groups), ?, ?)
                """, arguments: [DotistGroup.inboxID, now, now])
        }
        preferences = try SettingsStore(path: directory.appendingPathComponent("settings.json"))
    }

    public func databasePath() throws -> String { path }
    public func settings() throws -> DotistSettings { preferences.current() }
    public func updateSettings(_ patch: DotistSettingsPatch) throws -> DotistSettings { try preferences.update(patch) }

    public func observe(
        onError: @escaping (Error) -> Void,
        onChange: @escaping (TaskSnapshot) -> Void
    ) -> any DatabaseCancellable {
        ValueObservation.tracking { db in
            try TaskSnapshot(tasks: Self.tasks(db), groups: Self.groups(db))
        }.removeDuplicates().start(in: database, scheduling: .async(onQueue: .main), onError: onError, onChange: onChange)
    }

    public func snapshot() throws -> TaskSnapshot {
        try database.read { try TaskSnapshot(tasks: Self.tasks($0), groups: Self.groups($0)) }
    }
    public func listTasks() throws -> [DotistTask] { try database.read(Self.tasks) }
    public func listGroups() throws -> [DotistGroup] { try database.read(Self.groups) }

    public struct NewTask: Sendable {
        public let title: String
        public let category: String
        public let parentId: String?
        public let dueDate: String?
        public init(title: String, category: String, parentId: String? = nil, dueDate: String? = nil) {
            self.title = title; self.category = category; self.parentId = parentId; self.dueDate = dueDate
        }
    }

    @discardableResult public func addTask(title: String, category: String, parentId: String? = nil, dueDate: String? = nil) throws -> DotistTask {
        try addTasks([NewTask(title: title, category: category, parentId: parentId, dueDate: dueDate)])[0]
    }

    /// A batch is one transaction: an invalid title, parent or date leaves no partial tasks.
    public func addTasks(_ values: [NewTask]) throws -> [DotistTask] {
        try database.write { db in
            try values.map { value in
                let title = try Self.validated(value.title, limit: 500, empty: "任务内容不能为空", long: "任务内容不能超过 500 个字")
                try Self.validateDate(value.dueDate)
                let group = try Self.resolveGroup(db, value.category)
                let parent = try value.parentId.map { try Self.task(db, $0) }
                if let parent, TaskHierarchy(try Self.tasks(db)).depth(of: parent.id) >= DotistTask.maxDepth {
                    throw TaskStoreError("最多支持 5 层任务")
                }
                let category = parent?.category ?? group
                let position = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(position),-1)+1 FROM tasks WHERE category=? AND parent_id IS ? AND deleted_at IS NULL",
                                                 arguments: [category, value.parentId]) ?? 0
                let id = UUID().uuidString.lowercased()
                let now = Self.timestamp()
                try db.execute(sql: """
                    INSERT INTO tasks (id,title,category,completed,position,created_at,updated_at,revision,parent_id,due_date,status)
                    VALUES (?,?,?,0,?,?,?,1,?,?,'todo')
                    """, arguments: [id, title, category, position, now, now, value.parentId, value.dueDate])
                let task = try Self.task(db, id)
                try Self.record(db, task, kind: "create", base: nil)
                return task
            }
        }
    }

    @discardableResult public func patchTask(id: String, title: String? = nil, category: String? = nil, completed: Bool? = nil, status: TaskStatus? = nil) throws -> DotistTask {
        if let completed, let status, completed != (status == .done) { throw TaskStoreError("完成标记与状态不一致") }
        return try database.write { db in
            let old = try Self.task(db, id)
            let title = try Self.validated(title ?? old.title, limit: 500, empty: "任务内容不能为空", long: "任务内容不能超过 500 个字")
            let category = try category.map { try Self.resolveGroup(db, $0) } ?? old.category
            guard old.parentId == nil || old.category == category else { throw TaskStoreError("子任务的分类跟随父任务") }
            let status = status ?? completed.map { $0 ? .done : .todo } ?? old.status
            let position = old.category == category ? old.position : try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(position),-1)+1 FROM tasks WHERE category=? AND parent_id IS NULL AND deleted_at IS NULL", arguments: [category]) ?? 0
            let now = Self.timestamp()
            try db.execute(sql: "UPDATE tasks SET title=?,category=?,status=?,completed=?,position=?,updated_at=?,revision=revision+1 WHERE id=?",
                           arguments: [title, category, status.rawValue, status == .done, position, now, id])
            let updated = try Self.task(db, id)
            try Self.record(db, updated, kind: "update", base: old.revision)
            let completeChildren = status == .done && !old.completed
            if completeChildren || category != old.category {
                for child in TaskHierarchy(try Self.tasks(db)).descendants(of: id) {
                    // The Today view uses updatedAt as completion history; keep unchanged completed children intact.
                    if child.completed && category == old.category { continue }
                    try db.execute(sql: "UPDATE tasks SET category=?,status=?,completed=?,updated_at=?,revision=revision+1 WHERE id=?",
                                   arguments: [category, completeChildren ? "done" : child.status.rawValue, child.completed || completeChildren, now, child.id])
                    try Self.record(db, Self.task(db, child.id), kind: "update", base: child.revision)
                }
            }
            return updated
        }
    }

    @discardableResult public func setDueDate(_ id: String, date: String?) throws -> DotistTask {
        try database.write { db in let task = try Self.task(db, id); return try Self.dates(db, task, start: task.startDate, due: date) }
    }
    @discardableResult public func setStartDate(_ id: String, date: String?) throws -> DotistTask {
        try database.write { db in let task = try Self.task(db, id); return try Self.dates(db, task, start: date, due: task.dueDate) }
    }
    @discardableResult public func setDateRange(_ id: String, start: String?, due: String?) throws -> DotistTask {
        try database.write { try Self.dates($0, Self.task($0, id), start: start, due: due) }
    }

    public func deleteTask(_ id: String) throws {
        try database.write { db in
            let now = Self.timestamp()
            let root = try Self.task(db, id)
            for task in [root] + TaskHierarchy(try Self.tasks(db)).descendants(of: id) {
                try db.execute(sql: "UPDATE tasks SET deleted_at=?,updated_at=?,revision=revision+1 WHERE id=?", arguments: [now, now, task.id])
                try Self.record(db, Self.task(db, task.id, deleted: true), kind: "delete", base: task.revision)
            }
        }
    }

    @discardableResult public func restoreTask(_ id: String) throws -> DotistTask {
        try database.write { db in
            let old = try Self.task(db, id, deleted: true)
            guard let stamp = old.deletedAt else { throw TaskStoreError("任务没有被删除") }
            let parent = try old.parentId.map { try Self.task(db, $0) }
            let category = parent?.category ?? old.category
            guard try String.fetchOne(db, sql: "SELECT id FROM task_groups WHERE id=? AND deleted_at IS NULL", arguments: [category]) != nil else {
                throw TaskStoreError("所属分组已删除，请先恢复分组")
            }
            let deleted = try DotistTask.fetchAll(db, sql: "SELECT * FROM tasks WHERE deleted_at=?", arguments: [stamp])
            let family = [old] + TaskHierarchy(deleted).descendants(of: id)
            try Self.validateParent(TaskHierarchy(try Self.tasks(db) + family), id: id, parent: parent)
            for task in family {
                try db.execute(sql: "UPDATE tasks SET deleted_at=NULL,category=?,updated_at=?,revision=revision+1 WHERE id=?", arguments: [category, Self.timestamp(), task.id])
                try Self.record(db, Self.task(db, task.id), kind: "restore", base: task.revision)
            }
            return try Self.task(db, id)
        }
    }

    @discardableResult public func addGroup(name: String, color: String? = nil) throws -> DotistGroup {
        try database.write { db in
            let name = try Self.validated(name, limit: 20, empty: "分组名不能为空", long: "分组名不能超过 20 个字")
            try Self.availableGroupName(db, name, except: "")
            let color = color ?? "work"
            guard Self.colors.contains(color) else { throw TaskStoreError("无效的分组颜色") }
            let id = UUID().uuidString.lowercased()
            let position = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(position),-1)+1 FROM task_groups WHERE deleted_at IS NULL") ?? 0
            let now = Self.timestamp()
            try db.execute(sql: "INSERT INTO task_groups VALUES (?,?,?,?,?,?,NULL)", arguments: [id, name, color, position, now, now])
            return DotistGroup(id: id, name: name, color: color, position: position)
        }
    }

    @discardableResult public func updateGroup(_ id: String, name: String? = nil, color: String? = nil) throws -> DotistGroup {
        guard id != DotistGroup.inboxID else { throw TaskStoreError("Inbox 是固定的收集箱") }
        return try database.write { db in
            guard let old = try Self.groups(db).first(where: { $0.id == id }) else { throw TaskStoreError("找不到分组") }
            let name = try Self.validated(name ?? old.name, limit: 20, empty: "分组名不能为空", long: "分组名不能超过 20 个字")
            try Self.availableGroupName(db, name, except: id, preservingName: name == old.name)
            let color = color ?? old.color
            guard Self.colors.contains(color) else { throw TaskStoreError("无效的分组颜色") }
            try db.execute(sql: "UPDATE task_groups SET name=?,color=?,updated_at=? WHERE id=?", arguments: [name, color, Self.timestamp(), id])
            return DotistGroup(id: id, name: name, color: color, position: old.position)
        }
    }

    public func moveGroup(_ id: String, direction: Int) throws {
        guard [-1, 1].contains(direction) else { throw TaskStoreError("排序方向无效") }
        guard id != DotistGroup.inboxID else { return }
        try database.write { db in
            let groups = try Self.groups(db).filter { $0.id != DotistGroup.inboxID }
            guard let index = groups.firstIndex(where: { $0.id == id }) else { throw TaskStoreError("找不到分组") }
            guard groups.indices.contains(index + direction) else { return }
            let other = groups[index + direction]
            let now = Self.timestamp()
            try db.execute(sql: "UPDATE task_groups SET position=?,updated_at=? WHERE id=?", arguments: [other.position, now, id])
            try db.execute(sql: "UPDATE task_groups SET position=?,updated_at=? WHERE id=?", arguments: [groups[index].position, now, other.id])
        }
    }

    public func deleteGroup(_ id: String) throws {
        guard id != DotistGroup.inboxID else { throw TaskStoreError("Inbox 是固定的收集箱") }
        try database.write { db in
            let groups = try Self.groups(db)
            guard groups.contains(where: { $0.id == id }) else { throw TaskStoreError("找不到分组") }
            guard groups.count > 1 else { throw TaskStoreError("至少保留一个分组") }
            let now = Self.timestamp()
            try db.execute(sql: "UPDATE task_groups SET deleted_at=?,updated_at=? WHERE id=?", arguments: [now, now, id])
            for task in try DotistTask.fetchAll(db, sql: "SELECT * FROM tasks WHERE category=? AND deleted_at IS NULL", arguments: [id]) {
                try db.execute(sql: "UPDATE tasks SET deleted_at=?,updated_at=?,revision=revision+1 WHERE id=?", arguments: [now, now, task.id])
                try Self.record(db, Self.task(db, task.id, deleted: true), kind: "delete", base: task.revision)
            }
        }
    }

    @discardableResult public func restoreGroup(_ id: String) throws -> DotistGroup {
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM task_groups WHERE id=?", arguments: [id]) else { throw TaskStoreError("找不到分组") }
            guard let stamp: String = row["deleted_at"] else { throw TaskStoreError("分组没有被删除") }
            let group = try DotistGroup(row: row)
            try Self.availableGroupName(db, group.name, except: id, preservingName: true)
            try db.execute(sql: "UPDATE task_groups SET deleted_at=NULL,updated_at=? WHERE id=?", arguments: [Self.timestamp(), id])
            for task in try DotistTask.fetchAll(db, sql: "SELECT * FROM tasks WHERE category=? AND deleted_at=?", arguments: [id, stamp]) {
                try db.execute(sql: "UPDATE tasks SET deleted_at=NULL,updated_at=?,revision=revision+1 WHERE id=?", arguments: [Self.timestamp(), task.id])
                try Self.record(db, Self.task(db, task.id), kind: "restore", base: task.revision)
            }
            return group
        }
    }

    /// Snapshot queries include all active descendants, independently of UI expansion.
    public func children(of id: String) throws -> [DotistTask] {
        try database.read { TaskHierarchy(try Self.tasks($0)).children(of: id) }
    }
    public func depth(of id: String) throws -> Int {
        try database.read { TaskHierarchy(try Self.tasks($0)).depth(of: id) }
    }
    public func descendants(of id: String) throws -> [DotistTask] {
        try database.read { TaskHierarchy(try Self.tasks($0)).descendants(of: id) }
    }
    public func subtreeHeight(of id: String) throws -> Int {
        try database.read { TaskHierarchy(try Self.tasks($0)).subtreeHeight(of: id) }
    }

    @discardableResult public func reparent(_ id: String, parentId: String?) throws -> DotistTask {
        try database.write { db in
            let old = try Self.task(db, id)
            if let parentId {
                let parent = try Self.task(db, parentId)
                try Self.validateParent(TaskHierarchy(try Self.tasks(db)), id: id, parent: parent)
                if old.parentId == parentId { return old }
                try Self.commitReorder(db, id, groupID: parent.category, parentID: parentId, beforeID: nil)
            } else {
                guard old.parentId != nil else { throw TaskStoreError("这已经是一级任务") }
                try Self.outdent(db, ids: [id])
            }
            return try Self.task(db, id)
        }
    }

    /// Selected descendants travel with their selected ancestor. All validation
    /// and writes (including outbox records) belong to this single transaction.
    @discardableResult public func indent(ids: [String]) throws -> [DotistTask] {
        try database.write { db in
            let hierarchy = TaskHierarchy(try Self.tasks(db))
            for id in Set(ids) { _ = try Self.task(db, id) }
            let selected = hierarchy.selectionRoots(ids: ids, groupIDs: try Self.groups(db).map(\.id))
            guard let first = selected.first else { return [] }
            let siblings = first.parentId.map { hierarchy.children(of: $0) }
                ?? hierarchy.outline().filter { $0.parentId == nil && $0.category == first.category }
            let selectedIDs = Set(ids)
            guard let index = siblings.firstIndex(where: { $0.id == first.id }),
                  let parent = siblings.prefix(index).last(where: { !selectedIDs.contains($0.id) }) else {
                throw TaskStoreError("前面没有可以作为父任务的任务")
            }
            for task in selected { try Self.validateParent(hierarchy, id: task.id, parent: parent) }
            for task in selected {
                try Self.commitReorder(db, task.id, groupID: parent.category, parentID: parent.id, beforeID: nil)
            }
            return try selected.map { try Self.task(db, $0.id) }
        }
    }

    @discardableResult public func outdent(ids: [String]) throws -> [DotistTask] {
        try database.write { try Self.outdent($0, ids: ids) }
    }

    @discardableResult private static func outdent(_ db: Database, ids: [String]) throws -> [DotistTask] {
        let hierarchy = TaskHierarchy(try tasks(db))
        for id in Set(ids) { _ = try task(db, id) }
        let selected = hierarchy.selectionRoots(ids: ids, groupIDs: try groups(db).map(\.id))
        var lastAfterParent: [String: String] = [:]
        for old in selected {
            guard let parentID = old.parentId else { continue }
            let parent = try task(db, parentID)
            let anchorID = lastAfterParent[parentID] ?? parentID
            let peers = try DotistTask.fetchAll(db, sql: "SELECT * FROM tasks WHERE category=? AND parent_id IS ? AND deleted_at IS NULL ORDER BY position,id", arguments: [parent.category, parent.parentId])
            guard let index = peers.firstIndex(where: { $0.id == anchorID }) else { throw TaskStoreError("找不到任务") }
            let beforeID = peers.dropFirst(index + 1).first?.id
            try commitReorder(db, old.id, groupID: parent.category, parentID: parent.parentId, beforeID: beforeID)
            lastAfterParent[parentID] = old.id
        }
        return try selected.map { try task(db, $0.id) }
    }

    private static func validateParent(_ hierarchy: TaskHierarchy, id: String, parent: DotistTask?) throws {
        if let parent {
            guard parent.id != id, !hierarchy.descendants(of: id).contains(where: { $0.id == parent.id }) else {
                throw TaskStoreError("不能将任务移到自己或自己的后代下面")
            }
        }
        let depth = parent.map { hierarchy.depth(of: $0.id) + 1 } ?? 0
        guard depth + hierarchy.subtreeHeight(of: id) <= DotistTask.maxDepth else {
            throw TaskStoreError("最多支持 5 层任务")
        }
    }

    /// Moves an entire subtree atomically. `beforeID` must be a destination
    /// sibling; nil appends. A stale anchor rolls back every write.
    public func commitReorder(_ id: String, groupID: String, parentID: String?, beforeID: String?) throws {
        try database.write { try Self.commitReorder($0, id, groupID: groupID, parentID: parentID, beforeID: beforeID) }
    }

    private static func commitReorder(_ db: Database, _ id: String, groupID: String, parentID: String?, beforeID: String?) throws {
        let old = try task(db, id)
        guard try groups(db).contains(where: { $0.id == groupID }) else { throw TaskStoreError("找不到分组") }
        let hierarchy = TaskHierarchy(try tasks(db))
        let parent = try parentID.map { try task(db, $0) }
        try validateParent(hierarchy, id: id, parent: parent)
        guard parent == nil || parent?.category == groupID else { throw TaskStoreError("子任务的分类跟随父任务") }
        let peers = try DotistTask.fetchAll(db, sql: "SELECT * FROM tasks WHERE category=? AND parent_id IS ? AND deleted_at IS NULL AND id<>? ORDER BY position,id", arguments: [groupID, parentID, id])
        let anchor: DotistTask?
        if let beforeID {
            guard let found = peers.first(where: { $0.id == beforeID }) else { throw TaskStoreError("找不到任务") }
            anchor = found
        } else { anchor = peers.last }
        let now = timestamp()
        try db.execute(sql: "UPDATE tasks SET category=?,parent_id=?,updated_at=?,revision=revision+1 WHERE id=?", arguments: [groupID, parentID, old.completed ? old.updatedAt : now, id])
        let moved = try task(db, id)
        try record(db, moved, kind: "update", base: old.revision)
        if let anchor { try reorder(db, task: moved, target: anchor, after: beforeID == nil) }
        if old.category != groupID {
            for child in hierarchy.descendants(of: id) {
                try db.execute(sql: "UPDATE tasks SET category=?,updated_at=?,revision=revision+1 WHERE id=?", arguments: [groupID, child.completed ? child.updatedAt : now, child.id])
                try record(db, task(db, child.id), kind: "update", base: child.revision)
            }
        }
    }

    public func reorder(_ id: String, relativeTo targetId: String, after: Bool, allTasks: Bool) throws {
        try database.write { db in
            let task = try Self.task(db, id)
            let target = try Self.task(db, targetId)
            guard allTasks || (task.category == target.category && task.parentId == target.parentId) else { throw TaskStoreError("只能调整同级任务的顺序") }
            try Self.reorder(db, task: task, target: target, after: after)
        }
    }
    public func move(_ id: String, direction: Int) throws { try move(id, direction: direction, statusColumn: false) }
    public func moveStatus(_ id: String, direction: Int) throws { try move(id, direction: direction, statusColumn: true) }
    private func move(_ id: String, direction: Int, statusColumn: Bool) throws {
        guard [-1, 1].contains(direction) else { throw TaskStoreError("排序方向无效") }
        try database.write { db in
            let task = try Self.task(db, id)
            guard !statusColumn || task.parentId == nil else { throw TaskStoreError("看板只展示一级任务") }
            let peers = try Self.tasks(db).filter {
                statusColumn ? $0.parentId == nil && $0.status == task.status : $0.category == task.category && $0.parentId == task.parentId
            }.sorted { $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position }
            guard let index = peers.firstIndex(where: { $0.id == id }), peers.indices.contains(index + direction) else { return }
            try Self.reorder(db, task: task, target: peers[index + direction], after: direction > 0)
        }
    }

    private static func reorder(_ db: Database, task: DotistTask, target: DotistTask, after: Bool) throws {
        guard task.id != target.id else { return }
        var peers = try DotistTask.fetchAll(db, sql: "SELECT * FROM tasks WHERE deleted_at IS NULL ORDER BY position,id")
        guard let source = peers.firstIndex(where: { $0.id == task.id }) else { throw TaskStoreError("找不到任务") }
        peers.remove(at: source)
        guard let targetIndex = peers.firstIndex(where: { $0.id == target.id }) else { throw TaskStoreError("找不到任务") }
        let insertion = targetIndex + (after ? 1 : 0)
        if insertion == source { return }
        peers.insert(task, at: insertion)
        // Keep the narrowest valid gap so unrelated tasks retain their manual order and positions.
        func candidate(_ left: Bool) -> (unrelated: Int, changed: Int, first: Int, last: Int, start: Int64) {
            var first = insertion
            var last = insertion
            while true {
                let lower = first == 0 ? (partialValue: Int64.min, overflow: false) : peers[first - 1].position.addingReportingOverflow(1)
                let upper = last + 1 == peers.count ? (partialValue: Int64.max, overflow: false) : peers[last + 1].position.subtractingReportingOverflow(1)
                let latest = upper.partialValue.subtractingReportingOverflow(Int64(last - first))
                if !lower.overflow && !upper.overflow && !latest.overflow && lower.partialValue <= latest.partialValue {
                    let start = min(max(peers[first].position, lower.partialValue), latest.partialValue)
                    let changed = peers[first...last].enumerated().filter { $0.element.position != start + Int64($0.offset) }
                    return (changed.filter { $0.element.id != task.id && $0.element.id != target.id }.count, changed.count, first, last, start)
                }
                if first > 0 && (last + 1 == peers.count || left) { first -= 1 }
                else { last += 1 }
            }
        }
        let left = candidate(true)
        let right = candidate(false)
        let chosen = (left.unrelated, left.changed) <= (right.unrelated, right.changed) ? left : right
        let now = timestamp()
        for (index, peer) in peers[chosen.first...chosen.last].enumerated() {
            let position = chosen.start + Int64(index)
            if peer.position == position { continue }
            try db.execute(sql: "UPDATE tasks SET position=?,updated_at=?,revision=revision+1 WHERE id=?",
                           arguments: [position, peer.completed ? peer.updatedAt : now, peer.id])
            try record(db, Self.task(db, peer.id), kind: "reorder", base: peer.revision)
        }
    }

    private static let colors = ["work", "life", "study", "teal", "rose", "moss"]
    private static func tasks(_ db: Database) throws -> [DotistTask] {
        try DotistTask.fetchAll(db, sql: "SELECT * FROM tasks WHERE deleted_at IS NULL ORDER BY category,position,id")
    }
    private static func groups(_ db: Database) throws -> [DotistGroup] {
        try DotistGroup.fetchAll(db, sql: "SELECT * FROM task_groups WHERE deleted_at IS NULL ORDER BY position,id")
    }
    static func task(_ db: Database, _ id: String, deleted: Bool = false) throws -> DotistTask {
        guard let task = try DotistTask.fetchOne(db, sql: "SELECT * FROM tasks WHERE id=?", arguments: [id]),
              deleted || task.deletedAt == nil else { throw TaskStoreError("找不到任务") }
        return task
    }
    private static func resolveGroup(_ db: Database, _ key: String) throws -> String {
        guard let id = try String.fetchOne(db, sql: "SELECT id FROM task_groups WHERE deleted_at IS NULL AND (id=? OR name=?) ORDER BY id=? DESC LIMIT 1", arguments: [key, key, key]) else { throw TaskStoreError("无效的任务分类") }
        return id
    }
    private static func availableGroupName(_ db: Database, _ name: String, except id: String, preservingName: Bool = false) throws {
        // Migrated custom Inbox names can coexist with the fixed Inbox; new name conflicts still fail.
        let inbox = preservingName ? DotistGroup.inboxID : id
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_groups WHERE deleted_at IS NULL AND name=? AND id<>? AND id<>?", arguments: [name, id, inbox]) == 0 else { throw TaskStoreError("已经有同名的分组") }
    }
    static func validated(_ value: String, limit: Int, empty: String, long: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TaskStoreError(empty) }
        guard value.unicodeScalars.count <= limit else { throw TaskStoreError(long) }
        return value
    }
    private static func validateDate(_ value: String?) throws {
        guard let value else { return }
        guard value.utf8.count == 10, value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw TaskStoreError("日期格式应为 YYYY-MM-DD") }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { throw TaskStoreError("日期格式应为 YYYY-MM-DD") }
    }
    private static func dates(_ db: Database, _ old: DotistTask, start: String?, due: String?) throws -> DotistTask {
        try validateDate(start); try validateDate(due)
        if let start, let due, start > due { throw TaskStoreError("开始日不能晚于到期日") }
        try db.execute(sql: "UPDATE tasks SET start_date=?,due_date=?,updated_at=?,revision=revision+1 WHERE id=?", arguments: [start, due, timestamp(), old.id])
        let updated = try task(db, old.id)
        try record(db, updated, kind: "update", base: old.revision)
        return updated
    }
    static func record(_ db: Database, _ task: DotistTask, kind: String, base: Int64?) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let payload = String(decoding: try encoder.encode(task), as: UTF8.self)
        try db.execute(sql: "INSERT INTO sync_outbox VALUES (?,?,?,?,?,?)", arguments: [UUID().uuidString.lowercased(), task.id, kind, base, payload, timestamp()])
    }
    static func timestamp() -> String {
        let now = Date().timeIntervalSince1970
        let formatter = ISO8601DateFormatter()
        return String(format: "%@.%09dZ", String(formatter.string(from: Date(timeIntervalSince1970: floor(now))).dropLast()), Int((now - floor(now)) * 1_000_000_000))
    }
}

extension DotistTask: FetchableRecord {
    public init(row: Row) throws {
        guard let status = TaskStatus(rawValue: row["status"]) else { throw TaskStoreError("无效的任务状态") }
        self.init(id: row["id"], title: row["title"], category: row["category"], completed: row["completed"], status: status,
                  position: row["position"], createdAt: row["created_at"], updatedAt: row["updated_at"], deletedAt: row["deleted_at"],
                  revision: row["revision"], parentId: row["parent_id"], dueDate: row["due_date"], startDate: row["start_date"])
    }
}
extension DotistGroup: FetchableRecord {
    public init(row: Row) throws { self.init(id: row["id"], name: row["name"], color: row["color"], position: row["position"]) }
}
