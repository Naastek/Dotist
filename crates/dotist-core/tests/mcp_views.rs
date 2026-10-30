use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

#[test]
fn mcp_status_and_dates_use_core_rules() {
    let dir = tempfile::tempdir().unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_dotist-mcp"))
        .env("DOTIST_DATA_DIR", dir.path()).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    let mut call = |name: &str, args: Value| -> Value {
        writeln!(input, "{}", json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":name,"arguments":args}})).unwrap();
        input.flush().unwrap();
        let mut line = String::new();
        assert!(output.read_line(&mut line).unwrap() > 0);
        let reply: Value = serde_json::from_str(&line).unwrap();
        if reply["result"]["isError"] == true { reply["result"].clone() }
        else { serde_json::from_str(reply["result"]["content"][0]["text"].as_str().unwrap()).unwrap() }
    };
    let task = call("add_task", json!({"title":"视图任务","category":"work","due_date":"2026-11-10"}));
    let id = &task["id"];
    assert_eq!(task["status"], "todo");
    let doing = call("set_task_status", json!({"id":id,"status":"doing"}));
    assert_eq!((doing["status"].as_str(), doing["completed"].as_bool()), (Some("doing"), Some(false)));
    let done = call("complete_task", json!({"id":id,"completed":true}));
    assert_eq!(done["status"], "done");
    let todo = call("complete_task", json!({"id":id,"completed":false}));
    assert_eq!(todo["status"], "todo");
    assert_eq!(call("set_task_status", json!({"id":id,"status":"done"}))["completed"], true);
    assert_eq!(call("set_start_date", json!({"id":id,"start_date":"2026-11-09"}))["start_date"], "2026-11-09");
    assert_eq!(call("set_start_date", json!({"id":id,"start_date":"2026-11-11"}))["isError"], true);
    assert_eq!(call("set_due_date", json!({"id":id,"due_date":"2026-11-08"}))["isError"], true);
    assert_eq!(call("set_task_status", json!({"id":id,"status":"unknown"}))["isError"], true);
    assert!(call("set_start_date", json!({"id":id}))["start_date"].is_null());
    drop(call);
    drop(input);
    assert!(child.wait().unwrap().success());
    let store = dotist_core::Store::open(&dir.path().join("tasks.sqlite")).unwrap();
    let saved = store.list_tasks().unwrap().pop().unwrap();
    assert!(saved.completed);
    assert_eq!(saved.status, dotist_core::TaskStatus::Done);
    assert_eq!(saved.due_date.as_deref(), Some("2026-11-10"));
}
