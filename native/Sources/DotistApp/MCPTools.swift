import DotistCore
import Foundation
import MCP

struct DotistMCPTools: Sendable {
    let store: TaskStore
    var focus: @MainActor @Sendable (DotistTask?) -> Void

    private struct Arguments: Decodable {
        var id: String?
        var title: String?
        var category: String?
        var parentId: String?
        var dueDate: String?
        var startDate: String?
        var completed: Bool?
        var status: TaskStatus?
        var name: String?
        var query: String?
        var direction: Direction?
        var tasks: [Draft]?
        enum Direction: String, Decodable { case up, down }
        struct Draft: Decodable {
            let title: String
            var category: String?
            var parentId: String?
            var dueDate: String?
        }
        func taskID() throws -> String {
            guard let id, !id.isEmpty else { throw TaskStoreError("需要任务或分组 id") }
            return id
        }
    }

    func definitions() -> [Tool] {
        let id: Value = ["type": "string", "description": "Stable task or group id returned by the tools"]
        let text: Value = ["type": "string"]
        let date: Value = ["type": ["string", "null"], "description": "Local date YYYY-MM-DD; omit or pass null to clear"]
        func tool(_ name: String, _ description: String, _ properties: [String: Value] = [:], required: [String] = [], readOnly: Bool = false, destructive: Bool = false) -> Tool {
            Tool(name: name, description: description,
                 inputSchema: ["type": "object", "properties": .object(properties), "required": .array(required.map(Value.string)), "additionalProperties": false],
                 annotations: .init(readOnlyHint: readOnly, destructiveHint: destructive))
        }
        return [
            tool("list_tasks", "Read all active tasks. Optional category filters by group id or name.", ["category": text], readOnly: true),
            tool("get_task", "Read one active task by id.", ["id": id], required: ["id"], readOnly: true),
            tool("search_tasks", "Search task titles without changing the visible UI.", ["query": text], required: ["query"], readOnly: true),
            tool("add_tasks", "Create tasks in one atomic batch. An invalid item rolls back the whole batch. Tasks support up to five levels (depth 0–4); subtasks inherit their parent's group.",
                 ["category": text, "tasks": ["type": "array", "minItems": 1, "items": ["type": "object", "properties": ["title": text, "category": text, "parent_id": id, "due_date": date], "required": ["title"], "additionalProperties": false]]], required: ["tasks"]),
            tool("update_task", "Update only supplied fields. Status todo/doing/done stays consistent with completed. Completing a parent completes all its descendants; children do not auto-complete parents.",
                 ["id": id, "title": text, "category": text, "completed": ["type": "boolean"], "status": ["type": "string", "enum": ["todo", "doing", "done"]]], required: ["id"]),
            tool("delete_task", "Soft-delete a task and its currently active subtasks. restore_task can undo this deletion.", ["id": id], required: ["id"], destructive: true),
            tool("restore_task", "Restore a task and only the descendants deleted in the same deletion batch.", ["id": id], required: ["id"]),
            tool("set_due_date", "Set or clear a task due date. It cannot be before its start date.", ["id": id, "due_date": date], required: ["id"]),
            tool("set_start_date", "Set or clear a task start date. It cannot be after its due date.", ["id": id, "start_date": date], required: ["id"]),
            tool("set_task_parent", "Move a task and its subtree under any parent (maximum five levels, no cycles), or omit parent_id to outdent it by one level.", ["id": id, "parent_id": ["type": ["string", "null"]]], required: ["id"]),
            tool("move_task", "Move a task up or down among its siblings without changing dates, group or state.", ["id": id, "direction": ["type": "string", "enum": ["up", "down"]]], required: ["id", "direction"]),
            tool("list_groups", "Read the ordered active task groups, including the internal inbox id for ungrouped tasks.", readOnly: true),
            tool("add_group", "Create a uniquely named task group.", ["name": text], required: ["name"]),
            tool("update_group", "Rename an existing task group.", ["id": id, "name": text], required: ["id", "name"]),
            tool("delete_group", "Delete a group while keeping all its tasks and subtasks in the ungrouped inbox bucket. The internal inbox cannot be deleted.", ["id": id], required: ["id"], destructive: true),
            tool("restore_group", "Restore a group. Tasks moved to inbox remain ungrouped; legacy tasks deleted with a group are restored. Conflicting active names are rejected.", ["id": id], required: ["id"]),
            tool("focus_task", "Explicitly bring Dotist forward and locate a task. Omit id to show the main window. Ordinary reads and writes never take keyboard focus.", ["id": id]),
        ]
    }

    func call(_ name: String, _ values: [String: Value]?) async -> CallTool.Result {
        do {
            guard let definition = definitions().first(where: { $0.name == name }) else { throw TaskStoreError("未知工具：\(name)") }
            let values = values ?? [:]
            let properties = definition.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            guard Set(values.keys).isSubset(of: Set(properties.keys)) else { throw TaskStoreError("包含不支持的参数") }
            if name == "add_tasks", let drafts = values["tasks"]?.arrayValue {
                let allowed = Set(["title", "category", "parent_id", "due_date"])
                guard drafts.allSatisfy({ $0.objectValue.map { Set($0.keys).isSubset(of: allowed) } == true }) else {
                    throw TaskStoreError("批次任务包含不支持的字段")
                }
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let arguments = try decoder.decode(Arguments.self, from: JSONEncoder().encode(values))
            switch name {
            case "list_tasks":
                let tasks = try store.listTasks()
                guard let group = arguments.category else { return try result(tasks) }
                guard let id = try store.listGroups().first(where: { $0.id == group })?.id ?? store.listGroups().first(where: { $0.name == group })?.id else { throw TaskStoreError("无效的任务分类") }
                return try result(tasks.filter { $0.category == id })
            case "get_task":
                let id = try arguments.taskID()
                guard let task = try store.listTasks().first(where: { $0.id == id }) else { throw TaskStoreError("找不到任务") }
                return try result(task)
            case "search_tasks":
                guard let query = arguments.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { throw TaskStoreError("搜索词不能为空") }
                return try result(store.listTasks().filter { $0.title.localizedCaseInsensitiveContains(query) })
            case "add_tasks":
                guard let tasks = arguments.tasks, !tasks.isEmpty else { throw TaskStoreError("tasks 至少包含一项") }
                let drafts = try tasks.map { task in
                    guard let group = task.category ?? arguments.category else { throw TaskStoreError("每个任务需要 category，或为批次指定 category") }
                    return TaskStore.NewTask(title: task.title, category: group, parentId: task.parentId, dueDate: task.dueDate)
                }
                return try result(store.addTasks(drafts))
            case "update_task":
                guard arguments.title != nil || arguments.category != nil || arguments.completed != nil || arguments.status != nil else { throw TaskStoreError("请提供要修改的字段") }
                return try result(store.patchTask(id: arguments.taskID(), title: arguments.title, category: arguments.category, completed: arguments.completed, status: arguments.status))
            case "delete_task": try store.deleteTask(arguments.taskID())
            case "restore_task": return try result(store.restoreTask(arguments.taskID()))
            case "set_due_date": return try result(store.setDueDate(arguments.taskID(), date: arguments.dueDate))
            case "set_start_date": return try result(store.setStartDate(arguments.taskID(), date: arguments.startDate))
            case "set_task_parent": return try result(store.reparent(arguments.taskID(), parentId: arguments.parentId))
            case "move_task":
                guard let direction = arguments.direction else { throw TaskStoreError("需要 direction：up 或 down") }
                try store.move(arguments.taskID(), direction: direction == .up ? -1 : 1)
            case "list_groups": return try result(store.listGroups())
            case "add_group":
                guard let name = arguments.name else { throw TaskStoreError("需要分组名称") }
                return try result(store.addGroup(name: name))
            case "update_group":
                guard let name = arguments.name else { throw TaskStoreError("需要分组名称") }
                return try result(store.updateGroup(arguments.taskID(), name: name))
            case "delete_group": try store.deleteGroup(arguments.taskID())
            case "restore_group": return try result(store.restoreGroup(arguments.taskID()))
            case "focus_task":
                let task = try arguments.id.map { id in
                    guard let task = try store.listTasks().first(where: { $0.id == id }) else { throw TaskStoreError("找不到任务") }
                    return task
                }
                await focus(task)
            default: throw TaskStoreError("未知工具")
            }
            return CallTool.Result(content: [.text("ok")])
        } catch {
            return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        }
    }

    private func result<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return CallTool.Result(content: [.text(String(decoding: try encoder.encode(value), as: UTF8.self))])
    }
}
