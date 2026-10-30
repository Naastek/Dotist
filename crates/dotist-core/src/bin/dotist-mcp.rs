use anyhow::{bail, Context, Result};
use dotist_core::{database_path, Store};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};

fn tool(name: &str, description: &str, properties: Value, required: Value) -> Value {
    json!({"name": name, "description": description, "inputSchema": {"type":"object", "properties":properties, "required":required, "additionalProperties":false}})
}
fn tools() -> Vec<Value> {
    let id = json!({"type":"string", "description":"Task ID returned by list_tasks or add_task"});
    let title = json!({"type":"string", "description":"Task title"});
    let category = json!({"type":"string", "description":"Group ID or group name (see list_groups); default groups are 工作, 生活 and 学习"});
    let group_name = json!({"type":"string", "description":"Group name, up to 20 characters"});
    let group_color = json!({"type":"string", "enum":["work","life","study","teal","rose","moss"]});
    vec![
        tool("list_tasks", "List all non-deleted local tasks", json!({}), json!([])),
        tool("add_task", "Add a task to a category, or a one-level subtask when parent_id is given", json!({"title":title,"category":category,"parent_id":{"type":"string","description":"Optional parent task ID; the subtask follows its parent's category"},"due_date":{"type":"string","description":"Optional due date, YYYY-MM-DD"}}), json!(["title","category"])),
        tool("update_task", "Change a task's title or category by ID", json!({"id":id,"title":title,"category":category}), json!(["id"])),
        tool("complete_task", "Complete or restore a task by ID", json!({"id":id,"completed":{"type":"boolean"}}), json!(["id","completed"])),
        tool("delete_task", "Delete a task (and its subtasks) by ID", json!({"id":id}), json!(["id"])),
        tool("restore_task", "Undo a deletion by ID, bringing back the task and the subtasks deleted with it", json!({"id":id}), json!(["id"])),
        tool("set_due_date", "Set a task's due date (YYYY-MM-DD), or clear it when due_date is omitted", json!({"id":id,"due_date":{"type":"string","description":"YYYY-MM-DD; omit to clear"}}), json!(["id"])),
        tool("set_start_date", "Set or clear a task start date; must not be after its due date", json!({"id":id,"start_date":{"type":"string","description":"YYYY-MM-DD; omit to clear"}}), json!(["id"])),
        tool("set_task_status", "Change status and completion together", json!({"id":id,"status":{"type":"string","enum":["todo","doing","done"]}}), json!(["id","status"])),
        tool("set_task_parent", "Indent a childless task under another top-level task (parent_id), or outdent a subtask when parent_id is omitted", json!({"id":id,"parent_id":{"type":"string"}}), json!(["id"])),
        tool("list_groups", "List the task groups in order", json!({}), json!([])),
        tool("add_group", "Add a task group", json!({"name":group_name,"color":group_color}), json!(["name"])),
        tool("update_group", "Rename or recolor a group by ID", json!({"id":id,"name":group_name,"color":group_color}), json!(["id"])),
        tool("delete_group", "Delete a group and its tasks (restorable); the last group cannot be deleted", json!({"id":id}), json!(["id"])),
        tool("restore_group", "Undo a group deletion by ID, bringing back its tasks", json!({"id":id}), json!(["id"])),
        tool("move_task", "Move a task up or down within its category", json!({"id":id,"direction":{"type":"string","enum":["up","down"]}}), json!(["id","direction"])),
    ]
}
fn required_str<'a>(args: &'a Value, key: &str) -> Result<&'a str> {
    args.get(key).and_then(Value::as_str).with_context(|| format!("缺少或无效的参数：{key}"))
}
fn call_tool(store: &mut Store, name: &str, args: &Value) -> Result<Value> {
    match name {
        "list_tasks" => Ok(serde_json::to_value(store.list_tasks()?)?),
        "add_task" => {
            let task = store.add_task_in(required_str(args,"title")?, required_str(args,"category")?, args.get("parent_id").and_then(Value::as_str))?;
            match args.get("due_date").and_then(Value::as_str) {
                Some(due) => Ok(serde_json::to_value(store.set_due_date(&task.id, Some(due))?)?),
                None => Ok(serde_json::to_value(task)?),
            }
        }
        "set_due_date" => Ok(serde_json::to_value(store.set_due_date(required_str(args,"id")?, args.get("due_date").and_then(Value::as_str))?)?),
        "set_start_date" => Ok(serde_json::to_value(store.set_start_date(required_str(args,"id")?, args.get("start_date").and_then(Value::as_str))?)?),
        "set_task_status" => {
            let status = serde_json::from_value(args.get("status").cloned().context("缺少或无效的参数：status")?)?;
            Ok(serde_json::to_value(store.set_status(required_str(args,"id")?, status)?)?)
        }
        "update_task" => {
            let id = required_str(args,"id")?;
            let title = args.get("title").and_then(Value::as_str);
            let category = args.get("category").and_then(Value::as_str);
            if title.is_none() && category.is_none() { bail!("请提供要修改的 title 或 category"); }
            Ok(serde_json::to_value(store.patch_task(id, title, category, None)?)?)
        }
        "complete_task" => {
            let completed = args.get("completed").and_then(Value::as_bool).context("缺少或无效的参数：completed")?;
            Ok(serde_json::to_value(store.patch_task(required_str(args,"id")?, None, None, Some(completed))?)?)
        }
        "set_task_parent" => Ok(serde_json::to_value(store.reparent_task(required_str(args,"id")?, args.get("parent_id").and_then(Value::as_str))?)?),
        "list_groups" => Ok(serde_json::to_value(store.list_groups()?)?),
        "add_group" => Ok(serde_json::to_value(store.add_group(required_str(args,"name")?, args.get("color").and_then(Value::as_str))?)?),
        "update_group" => {
            let name = args.get("name").and_then(Value::as_str);
            let color = args.get("color").and_then(Value::as_str);
            if name.is_none() && color.is_none() { bail!("请提供要修改的 name 或 color"); }
            Ok(serde_json::to_value(store.update_group(required_str(args,"id")?, name, color)?)?)
        }
        "delete_group" => { store.delete_group(required_str(args,"id")?)?; Ok(json!({"deleted":true})) }
        "restore_group" => Ok(serde_json::to_value(store.restore_group(required_str(args,"id")?)?)?),
        "restore_task" => Ok(serde_json::to_value(store.restore_task(required_str(args,"id")?)?)?),
        "delete_task" => { store.delete_task(required_str(args,"id")?)?; Ok(json!({"deleted":true})) }
        "move_task" => {
            let direction = match required_str(args,"direction")? { "up" => -1, "down" => 1, _ => bail!("direction 必须为 up 或 down") };
            store.move_task(required_str(args,"id")?, direction)?;
            Ok(json!({"moved":true}))
        }
        _ => bail!("未知工具：{name}"),
    }
}
fn handle(store: &mut Store, message: Value) -> Option<Value> {
    let id = message.get("id")?.clone();
    let method = message.get("method").and_then(Value::as_str).unwrap_or("");
    let result = match method {
        "initialize" => json!({"protocolVersion":"2025-06-18", "capabilities":{"tools":{"listChanged":false}}, "serverInfo":{"name":"dotist", "version":"0.1.0"}}),
        "ping" => json!({}),
        "tools/list" => json!({"tools":tools()}),
        "tools/call" => {
            let params = &message["params"];
            let name = params["name"].as_str().unwrap_or("");
            let args = params.get("arguments").unwrap_or(&Value::Null);
            match call_tool(store, name, args) {
                Ok(value) => json!({"content":[{"type":"text","text":value.to_string()}], "isError":false}),
                Err(error) => json!({"content":[{"type":"text","text":error.to_string()}], "isError":true}),
            }
        }
        _ => return Some(json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"Method not found"}})),
    };
    Some(json!({"jsonrpc":"2.0","id":id,"result":result}))
}
fn main() -> Result<()> {
    let mut store = Store::open(&database_path()?)?;
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let line = line?;
        let response = match serde_json::from_str::<Value>(&line) {
            Ok(message) => handle(&mut store, message),
            Err(_) => Some(json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}})),
        };
        if let Some(response) = response { writeln!(stdout, "{response}")?; stdout.flush()?; }
    }
    Ok(())
}
