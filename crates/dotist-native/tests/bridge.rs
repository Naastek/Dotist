use dotist_native::{dotist_native_call, dotist_native_close, dotist_native_open, dotist_native_string_free, NativeStore};
use serde_json::{json, Value};
use std::{ffi::{CStr, CString}, io::Write, path::PathBuf, process::{Command, Stdio}, ptr, time::{SystemTime, UNIX_EPOCH}};

struct Bridge(*mut NativeStore);
impl Bridge {
    fn open(path: &str) -> Self {
        let path = CString::new(path).unwrap();
        let mut error = ptr::null_mut();
        let store = unsafe { dotist_native_open(path.as_ptr(), &mut error) };
        assert!(!store.is_null(), "failed to open test database");
        assert!(error.is_null());
        Self(store)
    }
    fn call(&self, request: Value) -> Value {
        let request = CString::new(request.to_string()).unwrap();
        let response = unsafe { dotist_native_call(self.0, request.as_ptr()) };
        assert!(!response.is_null());
        let value = serde_json::from_str(unsafe { CStr::from_ptr(response) }.to_str().unwrap()).unwrap();
        unsafe { dotist_native_string_free(response) };
        value
    }
}
impl Drop for Bridge { fn drop(&mut self) { unsafe { dotist_native_close(self.0) } } }

fn test_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("dotist-native-bridge-{}-{}", std::process::id(), SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn real_bridge_and_mcp_share_task_identity_status_dates_and_outbox() {
    let dir = test_dir();
    let bridge = Bridge::open(dir.join("tasks.sqlite").to_str().unwrap());
    let created = bridge.call(json!({"operation":"add_task", "title":"桥接测试", "category":"work", "due_date":"2026-11-10"}));
    assert_eq!(created["ok"], true);
    let id = created["value"]["id"].as_str().unwrap();
    let child = bridge.call(json!({"operation":"add_task", "title":"子任务", "category":"work", "parent_id":id}));
    assert_eq!(child["value"]["parent_id"], id);
    let other = bridge.call(json!({"operation":"add_task", "title":"跨组", "category":"life", "due_date":"2026-11-10"}));
    let other_id = other["value"]["id"].as_str().unwrap();
    assert_eq!(bridge.call(json!({"operation":"reorder_task", "id":other_id, "target_id":id, "after":false, "all_tasks":true}))["ok"], true);
    assert_eq!(bridge.call(json!({"operation":"reorder_task", "id":other_id, "target_id":id, "after":true, "all_tasks":true}))["ok"], true);
    assert_eq!(bridge.call(json!({"operation":"set_date_range", "id":id, "start_date":"2026-11-11", "due_date":"2026-11-10"}))["ok"], false);

    let executable = std::env::var_os("DOTIST_MCP_BINARY").expect("DOTIST_MCP_BINARY must name the built MCP server");
    let mut process = Command::new(executable).env("DOTIST_DATA_DIR", &dir).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    let mut stdin = process.stdin.take().unwrap();
    writeln!(stdin, "{}", json!({"jsonrpc":"2.0", "id":1, "method":"tools/call", "params":{"name":"list_tasks", "arguments":{}}})).unwrap();
    writeln!(stdin, "{}", json!({"jsonrpc":"2.0", "id":2, "method":"tools/call", "params":{"name":"set_task_status", "arguments":{"id":id, "status":"done"}}})).unwrap();
    drop(stdin);
    let result = process.wait_with_output().unwrap();
    assert!(result.status.success());
    let replies: Vec<Value> = String::from_utf8(result.stdout).unwrap().lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    assert_eq!(replies.len(), 2);
    let mcp_tasks: Value = serde_json::from_str(replies[0]["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert!(mcp_tasks.as_array().unwrap().iter().any(|task| task["id"] == id && task["due_date"] == "2026-11-10"));
    assert_eq!(replies[1]["result"]["isError"], false);
    let tasks = bridge.call(json!({"operation":"list_tasks"}));
    let rows = tasks["value"].as_array().unwrap();
    assert!(rows.iter().any(|task| task["id"] == id && task["completed"] == true && task["status"] == "done"));
    assert!(rows.iter().any(|task| task["parent_id"] == id && task["completed"] == true));
    assert!(rows.iter().any(|task| task["id"] == other_id && task["category"] == "life" && task["due_date"] == "2026-11-10"));
    let db = rusqlite::Connection::open(dir.join("tasks.sqlite")).unwrap();
    let mut query = db.prepare("SELECT kind, base_revision, payload FROM sync_outbox WHERE task_id = ? ORDER BY rowid").unwrap();
    let entries: Vec<(String, Option<i64>, Value)> = query.query_map([id], |row| {
        let payload: String = row.get(2)?;
        Ok((row.get(0)?, row.get(1)?, serde_json::from_str(&payload).unwrap()))
    }).unwrap().map(Result::unwrap).collect();
    assert!(entries.iter().any(|(kind, base, payload)| kind == "create" && base.is_none() && payload["id"] == id && payload["revision"] == 1));
    assert!(entries.iter().any(|(kind, base, payload)| kind == "update" && base.is_some() && payload["id"] == id && payload["status"] == "done"));
    let reorders: i64 = db.query_row("SELECT COUNT(*) FROM sync_outbox WHERE task_id IN (?, ?) AND kind = 'reorder' AND base_revision IS NOT NULL", [id, other_id], |row| row.get(0)).unwrap();
    assert!(reorders > 0, "a cross-group reorder must retain its sync reservation records");
    assert_eq!(bridge.call(json!({"operation":"delete_task", "id":id}))["ok"], true);
    assert_eq!(bridge.call(json!({"operation":"restore_task", "id":id}))["value"]["id"], id);
}

#[test]
fn bridge_rejects_malformed_requests_without_modifying_tasks() {
    let dir = test_dir();
    let bridge = Bridge::open(dir.join("tasks.sqlite").to_str().unwrap());
    assert_eq!(bridge.call(json!({"operation":"reorder_task", "id":"missing"}))["ok"], false);
    assert_eq!(bridge.call(json!({"operation":"list_tasks"}))["value"], json!([]));
}

#[test]
fn update_preferences_keep_the_existing_dependency_and_persist() {
    let dir = test_dir();
    let database = dir.join("tasks.sqlite");
    let bridge = Bridge::open(database.to_str().unwrap());
    let enabled = bridge.call(json!({"operation":"update_settings", "patch":{"auto_install_updates":true}}));
    assert_eq!(enabled["value"]["auto_check_updates"], true);
    assert_eq!(enabled["value"]["auto_install_updates"], true);
    let disabled = bridge.call(json!({"operation":"update_settings", "patch":{"auto_check_updates":false, "skipped_update_version":"1.2.3"}}));
    assert_eq!(disabled["value"]["auto_install_updates"], false);
    drop(bridge);
    let reopened = Bridge::open(database.to_str().unwrap());
    let saved = reopened.call(json!({"operation":"get_settings"}));
    assert_eq!(saved["value"]["auto_check_updates"], false);
    assert_eq!(saved["value"]["auto_install_updates"], false);
    assert_eq!(saved["value"]["skipped_update_version"], "1.2.3");
}
