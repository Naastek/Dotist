use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

#[test]
fn mcp_lists_adds_and_completes_tasks_using_stdio() {
    let dir = tempfile::tempdir().unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_dotist-mcp"))
        .env("DOTIST_DATA_DIR", dir.path())
        .stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    fn call(input: &mut impl Write, output: &mut impl BufRead, request: Value) -> Value {
        writeln!(input, "{}", request).unwrap();
        input.flush().unwrap();
        let mut line = String::new();
        assert_ne!(output.read_line(&mut line).unwrap(), 0, "MCP server exited unexpectedly");
        serde_json::from_str(&line).expect("stdout must contain only JSON-RPC messages")
    }
    let initialized = call(&mut stdin, &mut stdout, json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}));
    assert_eq!(initialized["result"]["protocolVersion"], "2025-06-18");
    writeln!(stdin, "{}", json!({"jsonrpc":"2.0","method":"notifications/initialized"})).unwrap();
    let list = call(&mut stdin, &mut stdout, json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}));
    assert!(list["result"]["tools"].as_array().unwrap().iter().any(|tool| tool["name"] == "add_task"));
    let added = call(&mut stdin, &mut stdout, json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add_task","arguments":{"title":"MCP 测试","category":"life"}}}));
    let task: Value = serde_json::from_str(added["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    let id = task["id"].as_str().unwrap();
    let done = call(&mut stdin, &mut stdout, json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"complete_task","arguments":{"id":id,"completed":true}}}));
    let changed: Value = serde_json::from_str(done["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(changed["completed"], true);
    let group = call(&mut stdin, &mut stdout, json!({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"add_group","arguments":{"name":"阅读"}}}));
    let group: Value = serde_json::from_str(group["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    let in_group = call(&mut stdin, &mut stdout, json!({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"add_task","arguments":{"title":"读书","category":"阅读"}}}));
    let in_group: Value = serde_json::from_str(in_group["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(in_group["category"], group["id"]);
    let dated = call(&mut stdin, &mut stdout, json!({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"add_task","arguments":{"title":"有期限","category":"work","due_date":"2026-11-05"}}}));
    let dated: Value = serde_json::from_str(dated["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(dated["due_date"], "2026-11-05");
    let cleared = call(&mut stdin, &mut stdout, json!({"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"set_due_date","arguments":{"id":dated["id"]}}}));
    let cleared: Value = serde_json::from_str(cleared["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert!(cleared["due_date"].is_null());
    let bad = call(&mut stdin, &mut stdout, json!({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"set_due_date","arguments":{"id":dated["id"],"due_date":"tomorrow"}}}));
    assert_eq!(bad["result"]["isError"], true);
    drop(stdin);
    assert!(child.wait().unwrap().success());
    let store = dotist_core::Store::open(&dir.path().join("tasks.sqlite")).unwrap();
    assert!(store.list_tasks().unwrap().iter().find(|t| t.id == id).unwrap().completed);
}
