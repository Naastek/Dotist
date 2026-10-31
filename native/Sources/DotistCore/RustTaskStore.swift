import DotistCoreFFI
import Foundation

public struct TaskStoreError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

private struct Response<Value: Decodable>: Decodable {
    let ok: Bool
    let value: Value?
    let error: String?
}
private struct Empty: Decodable {}

/// A process-local connection to the same Rust core and SQLite schema used by MCP.
public final class RustTaskStore: @unchecked Sendable {
    private let handle: OpaquePointer

    /// Pass nil to use the existing application database path; tests provide an isolated path.
    public init(databasePath: String? = nil) throws {
        var error: UnsafeMutablePointer<CChar>?
        let opened = databasePath.map { path in path.withCString { dotist_native_open($0, &error) } } ?? dotist_native_open(nil, &error)
        guard let opened else {
            let message = error.flatMap { value in
                try? JSONDecoder().decode(Response<Empty>.self, from: Data(bytes: value, count: strlen(value))).error
            } ?? "无法打开任务数据库"
            if let error { dotist_native_string_free(error) }
            throw TaskStoreError(message: message)
        }
        handle = opened
    }

    deinit { dotist_native_close(handle) }

    private func call<T: Decodable>(_ operation: String, _ arguments: [String: Any] = [:], as: T.Type) throws -> T? {
        let data = try JSONSerialization.data(withJSONObject: arguments.merging(["operation": operation]) { _, new in new })
        let response = String(decoding: data, as: UTF8.self).withCString { dotist_native_call(handle, $0) }
        guard let response else { throw TaskStoreError(message: "任务服务未返回结果") }
        defer { dotist_native_string_free(response) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(Response<T>.self, from: Data(bytes: response, count: strlen(response)))
        guard result.ok else { throw TaskStoreError(message: result.error ?? "任务操作失败") }
        return result.value
    }

    private func required<T: Decodable>(_ operation: String, _ arguments: [String: Any] = [:], as: T.Type) throws -> T {
        guard let value = try call(operation, arguments, as: T.self) else { throw TaskStoreError(message: "任务服务返回了空结果") }
        return value
    }

    private func change(_ operation: String, _ arguments: [String: Any]) throws {
        _ = try call(operation, arguments, as: Empty.self)
    }

    public func listTasks() throws -> [DotistTask] { try required("list_tasks", as: [DotistTask].self) }
    public func listGroups() throws -> [DotistGroup] { try required("list_groups", as: [DotistGroup].self) }
    public func describeTags() throws -> DotistTagDescription { try required("describe_tags", as: DotistTagDescription.self) }
    public func filterByTag(_ tag: String) throws -> [DotistTask] { try required("filter_by_tag", ["tag": tag], as: [DotistTask].self) }
    public func retag(_ tag: String, replacement: String?) throws { try change("retag", ["tag": tag, "replacement": replacement as Any? ?? NSNull()]) }
    public func settings() throws -> DotistSettings { try required("get_settings", as: DotistSettings.self) }
    public func databasePath() throws -> String { try required("get_database_path", as: String.self) }
    public func launchAtLogin(appName: String, executable: String) throws -> Bool {
        try required("get_launch_at_login", ["app_name": appName, "executable": executable], as: Bool.self)
    }
    @discardableResult public func setLaunchAtLogin(appName: String, executable: String, enabled: Bool) throws -> Bool {
        try required("set_launch_at_login", ["app_name": appName, "executable": executable, "enabled": enabled], as: Bool.self)
    }
    @discardableResult public func updateSettings(_ patch: DotistSettingsPatch) throws -> DotistSettings {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let value = try JSONSerialization.jsonObject(with: encoder.encode(patch))
        return try required("update_settings", ["patch": value], as: DotistSettings.self)
    }
    @discardableResult public func addTask(title: String, category: String, parentId: String? = nil, dueDate: String? = nil) throws -> DotistTask {
        try required("add_task", ["title": title, "category": category, "parent_id": parentId as Any? ?? NSNull(), "due_date": dueDate as Any? ?? NSNull()], as: DotistTask.self)
    }
    @discardableResult public func patchTask(id: String, title: String? = nil, category: String? = nil, completed: Bool? = nil, status: TaskStatus? = nil) throws -> DotistTask {
        try required("patch_task", ["id": id, "title": title as Any? ?? NSNull(), "category": category as Any? ?? NSNull(), "completed": completed as Any? ?? NSNull(), "status": status?.rawValue as Any? ?? NSNull()], as: DotistTask.self)
    }
    public func deleteTask(_ id: String) throws { try change("delete_task", ["id": id]) }
    @discardableResult public func restoreTask(_ id: String) throws -> DotistTask { try required("restore_task", ["id": id], as: DotistTask.self) }
    @discardableResult public func setDueDate(_ id: String, date: String?) throws -> DotistTask { try required("set_due_date", ["id": id, "due_date": date as Any? ?? NSNull()], as: DotistTask.self) }
    @discardableResult public func setStartDate(_ id: String, date: String?) throws -> DotistTask { try required("set_start_date", ["id": id, "start_date": date as Any? ?? NSNull()], as: DotistTask.self) }
    @discardableResult public func setDateRange(_ id: String, start: String?, due: String?) throws -> DotistTask { try required("set_date_range", ["id": id, "start_date": start as Any? ?? NSNull(), "due_date": due as Any? ?? NSNull()], as: DotistTask.self) }
    @discardableResult public func reparent(_ id: String, parentId: String?) throws -> DotistTask { try required("reparent_task", ["id": id, "parent_id": parentId as Any? ?? NSNull()], as: DotistTask.self) }
    public func reorder(_ id: String, relativeTo targetId: String, after: Bool, allTasks: Bool) throws { try change("reorder_task", ["id": id, "target_id": targetId, "after": after, "all_tasks": allTasks]) }
    public func move(_ id: String, direction: Int) throws { try change("move_task", ["id": id, "direction": direction]) }
    public func moveStatus(_ id: String, direction: Int) throws { try change("move_status_task", ["id": id, "direction": direction]) }
    @discardableResult public func addGroup(name: String, color: String? = nil) throws -> DotistGroup { try required("add_group", ["name": name, "color": color as Any? ?? NSNull()], as: DotistGroup.self) }
    @discardableResult public func updateGroup(_ id: String, name: String? = nil, color: String? = nil) throws -> DotistGroup { try required("update_group", ["id": id, "name": name as Any? ?? NSNull(), "color": color as Any? ?? NSNull()], as: DotistGroup.self) }
    public func moveGroup(_ id: String, direction: Int) throws { try change("move_group", ["id": id, "direction": direction]) }
    public func deleteGroup(_ id: String) throws { try change("delete_group", ["id": id]) }
    @discardableResult public func restoreGroup(_ id: String) throws -> DotistGroup { try required("restore_group", ["id": id], as: DotistGroup.self) }
}
