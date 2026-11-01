import Foundation
import GRDB

/// Group rows and their migrated tasks are restored together by the same action.
public struct TaskHistoryGroup: Equatable, Sendable {
    public let group: DotistGroup
    public let createdAt: String
    public let updatedAt: String
    public let deletedAt: String?

    init(row: Row) throws {
        group = try DotistGroup(row: row)
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
        deletedAt = row["deleted_at"]
    }
}

/// Only touched identities are retained. A missing identity means that the
/// corresponding task/group did not exist on this side of the operation.
public struct TaskRestorePoint: Equatable, Sendable {
    public let tasks: [DotistTask]
    public let missingTaskIDs: Set<String>
    public let groups: [TaskHistoryGroup]
    public let missingGroupIDs: Set<String>

    public init(tasks: [DotistTask], missingTaskIDs: Set<String> = [], groups: [TaskHistoryGroup] = [], missingGroupIDs: Set<String> = []) {
        self.tasks = tasks
        self.missingTaskIDs = missingTaskIDs
        self.groups = groups
        self.missingGroupIDs = missingGroupIDs
    }
}

public struct TaskMutationPatch: Equatable, Sendable {
    public let before: TaskRestorePoint
    public let after: TaskRestorePoint
    public var isEmpty: Bool { before == after }
}

extension DotistTask {
    /// Revisions are transport counters. updatedAt is restored, including the
    /// completion date used by Today, but metadata-only writes aren't actions.
    func hasSameHistoryContent(as other: DotistTask) -> Bool {
        id == other.id && title == other.title && category == other.category
            && completed == other.completed && status == other.status
            && position == other.position && parentId == other.parentId
            && dueDate == other.dueDate && startDate == other.startDate
            && createdAt == other.createdAt && deletedAt == other.deletedAt
    }
}

extension TaskStore {
    /// A capture may call snapshot/query entry points from its writer queue.
    /// Outside a capture, retain the read transaction used by DatabaseQueue.read
    /// so task and group queries also agree with external SQLite connections.
    func read<T>(_ operation: (Database) throws -> T) throws -> T {
        try database.unsafeReentrantRead { db in
            if db.isInsideTransaction { return try operation(db) }
            var result: T?
            try db.inTransaction(.deferred) {
                result = try operation(db)
                return .commit
            }
            return result!
        }
    }

    /// Store entry points use savepoints so captureChanges can wrap an entire
    /// multi-operation UI action in one outer transaction on the same queue.
    func write<T>(_ operation: (Database) throws -> T) throws -> T {
        try database.unsafeReentrantWrite { db in
            var result: T?
            try db.inSavepoint {
                result = try operation(db)
                return .commit
            }
            return result!
        }
    }

    /// TEMP triggers remember the first preimage of each changed row. They are
    /// connection-local, do not migrate the database, and never copy the store.
    /// The writer queue prevents MCP/other writers from entering the capture.
    public func captureChanges(_ operation: (TaskStore) throws -> Void) throws -> TaskMutationPatch {
        try write { db in
            try Self.prepareHistoryJournal(db)
            guard try Int.fetchOne(db, sql: "SELECT enabled FROM dotist_history_capture") == 0 else {
                throw TaskStoreError("不能嵌套记录撤销历史")
            }
            try db.execute(sql: "DELETE FROM dotist_history_tasks; DELETE FROM dotist_history_groups; UPDATE dotist_history_capture SET enabled=1")
            try operation(self)
            try db.execute(sql: "UPDATE dotist_history_capture SET enabled=0")
            let patch = try Self.historyPatch(db)
            try db.execute(sql: "DELETE FROM dotist_history_tasks; DELETE FROM dotist_history_groups")
            return patch
        }
    }

    public func restore(snapshots: [DotistTask]) throws {
        try apply(patch: TaskRestorePoint(tasks: snapshots))
    }

    /// Apply all rows before validating the resulting graph. Intermediate
    /// parent/category states never escape this transaction. New-task undo uses
    /// tombstones so its delete is also represented in the sync outbox.
    public func apply(patch: TaskRestorePoint) throws {
        try write { db in
            let now = Self.timestamp()
            for state in patch.groups {
                let group = state.group
                try db.execute(sql: """
                    INSERT INTO task_groups (id,name,color,position,created_at,updated_at,deleted_at)
                    VALUES (?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                    name=excluded.name,color=excluded.color,position=excluded.position,
                    created_at=excluded.created_at,updated_at=excluded.updated_at,deleted_at=excluded.deleted_at
                    """, arguments: [group.id, group.name, group.color, group.position, state.createdAt, state.updatedAt, state.deletedAt])
            }
            for id in patch.missingGroupIDs {
                try db.execute(sql: "UPDATE task_groups SET deleted_at=?,updated_at=? WHERE id=? AND deleted_at IS NULL", arguments: [now, now, id])
            }
            for state in patch.tasks {
                let old = try DotistTask.fetchOne(db, sql: "SELECT * FROM tasks WHERE id=?", arguments: [state.id])
                // Redo/undo is a new sync mutation; revisions never move back.
                let revision = max(old?.revision ?? 0, state.revision) + 1
                try db.execute(sql: """
                    INSERT INTO tasks (id,title,category,completed,status,position,created_at,updated_at,deleted_at,revision,parent_id,due_date,start_date)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                    title=excluded.title,category=excluded.category,completed=excluded.completed,status=excluded.status,
                    position=excluded.position,created_at=excluded.created_at,updated_at=excluded.updated_at,
                    deleted_at=excluded.deleted_at,revision=excluded.revision,parent_id=excluded.parent_id,
                    due_date=excluded.due_date,start_date=excluded.start_date
                    """, arguments: [state.id, state.title, state.category, state.completed, state.status.rawValue, state.position,
                                      state.createdAt, state.updatedAt, state.deletedAt, revision, state.parentId, state.dueDate, state.startDate])
                let restored = try Self.task(db, state.id, deleted: true)
                let kind = state.deletedAt != nil ? "delete" : old == nil ? "create" : old?.deletedAt != nil ? "restore" : "update"
                try Self.record(db, restored, kind: kind, base: old?.revision)
            }
            for id in patch.missingTaskIDs {
                guard let old = try DotistTask.fetchOne(db, sql: "SELECT * FROM tasks WHERE id=? AND deleted_at IS NULL", arguments: [id]) else { continue }
                try db.execute(sql: "UPDATE tasks SET deleted_at=?,updated_at=?,revision=revision+1 WHERE id=?", arguments: [now, now, id])
                try Self.record(db, Self.task(db, id, deleted: true), kind: "delete", base: old.revision)
            }
            try Self.validateRestoredGraph(db)
        }
    }

    private static func prepareHistoryJournal(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TEMP TABLE IF NOT EXISTS dotist_history_capture (enabled INTEGER NOT NULL);
            INSERT INTO dotist_history_capture SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM dotist_history_capture);
            """
        )
        for (table, journal) in [("tasks", "dotist_history_tasks"), ("task_groups", "dotist_history_groups")] {
            try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS \(journal) AS SELECT *,1 AS existed FROM main.\(table) WHERE 0")
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS \(journal)_id ON \(journal)(id)")
            let columns = try db.columns(in: table).map(\.name)
            // An outer UPSERT overrides a trigger's OR IGNORE policy. Explicit
            // deduplication keeps the first preimage when INSERT also fires UPDATE.
            for (event, source, existed) in [("INSERT", "NEW", 0), ("UPDATE", "OLD", 1), ("DELETE", "OLD", 1)] {
                let values = columns.map { "\(source).\($0)" }.joined(separator: ",")
                // BEFORE INSERT also runs for an UPSERT of an existing identity.
                // Capture that row before NEW can masquerade as a new creation.
                let existing = event == "INSERT" ? """
                    INSERT INTO \(journal) SELECT \(columns.joined(separator: ",")),1 FROM main.\(table)
                    WHERE id=NEW.id AND NOT EXISTS (SELECT 1 FROM \(journal) WHERE id=NEW.id);
                    """ : ""
                try db.execute(sql: """
                    CREATE TEMP TRIGGER IF NOT EXISTS \(journal)_\(event) BEFORE \(event) ON main.\(table)
                    WHEN (SELECT enabled FROM dotist_history_capture)=1 BEGIN
                        \(existing)
                        INSERT INTO \(journal) SELECT \(values),\(existed)
                        WHERE NOT EXISTS (SELECT 1 FROM \(journal) WHERE id=\(source).id);
                    END
                    """
                )
            }
        }
    }

    private static func historyPatch(_ db: Database) throws -> TaskMutationPatch {
        var beforeTasks: [DotistTask] = [], afterTasks: [DotistTask] = []
        var beforeMissing: Set<String> = [], afterMissing: Set<String> = []
        for row in try Row.fetchAll(db, sql: "SELECT * FROM dotist_history_tasks ORDER BY id") {
            let id: String = row["id"]
            let old = (row["existed"] as Bool) ? try DotistTask(row: row) : nil
            let new = try DotistTask.fetchOne(db, sql: "SELECT * FROM tasks WHERE id=?", arguments: [id])
            if let old, let new, old.hasSameHistoryContent(as: new) { continue }
            if old == nil && new == nil { continue }
            if let old { beforeTasks.append(old) } else { beforeMissing.insert(id) }
            if let new { afterTasks.append(new) } else { afterMissing.insert(id) }
        }
        var beforeGroups: [TaskHistoryGroup] = [], afterGroups: [TaskHistoryGroup] = []
        var beforeMissingGroups: Set<String> = [], afterMissingGroups: Set<String> = []
        for row in try Row.fetchAll(db, sql: "SELECT * FROM dotist_history_groups ORDER BY id") {
            let id: String = row["id"]
            let old = (row["existed"] as Bool) ? try TaskHistoryGroup(row: row) : nil
            let new = try Row.fetchOne(db, sql: "SELECT * FROM task_groups WHERE id=?", arguments: [id]).map { try TaskHistoryGroup(row: $0) }
            if old?.group == new?.group && old?.deletedAt == new?.deletedAt { continue }
            if let old { beforeGroups.append(old) } else { beforeMissingGroups.insert(id) }
            if let new { afterGroups.append(new) } else { afterMissingGroups.insert(id) }
        }
        return TaskMutationPatch(
            before: .init(tasks: beforeTasks, missingTaskIDs: beforeMissing, groups: beforeGroups, missingGroupIDs: beforeMissingGroups),
            after: .init(tasks: afterTasks, missingTaskIDs: afterMissing, groups: afterGroups, missingGroupIDs: afterMissingGroups))
    }

    private static func validateRestoredGraph(_ db: Database) throws {
        let tasks = try DotistTask.fetchAll(db, sql: "SELECT * FROM tasks WHERE deleted_at IS NULL")
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let groups = Set(try String.fetchAll(db, sql: "SELECT id FROM task_groups WHERE deleted_at IS NULL"))
        for task in tasks {
            guard groups.contains(task.category) else { throw TaskStoreError("所属分组已删除，请先恢复分组") }
            guard task.completed == (task.status == .done) else { throw TaskStoreError("完成标记与状态不一致") }
            var seen: Set<String> = [task.id]
            var current = task
            var depth = 0
            while let parentID = current.parentId {
                guard seen.insert(parentID).inserted else { throw TaskStoreError("不能将任务移到自己或自己的后代下面") }
                guard let parent = byID[parentID] else { throw TaskStoreError("找不到任务") }
                guard parent.category == current.category else { throw TaskStoreError("子任务的分类跟随父任务") }
                depth += 1
                guard depth <= DotistTask.maxDepth else { throw TaskStoreError("最多支持 5 层任务") }
                current = parent
            }
        }
    }
}
