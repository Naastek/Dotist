use dotist_core::{Store, Task, TaskStatus};
use rusqlite::{params, Connection};
use std::path::Path;

fn version_four(file: &Path) {
    let db = Connection::open(file).unwrap();
    db.execute_batch("CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, category TEXT NOT NULL, completed INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, revision INTEGER NOT NULL, remote_revision TEXT, parent_id TEXT, due_date TEXT);
        CREATE TABLE sync_outbox (operation_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, kind TEXT NOT NULL, base_revision INTEGER, payload TEXT NOT NULL, created_at TEXT NOT NULL);
        CREATE TABLE task_groups (id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL, position INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT);
        INSERT INTO task_groups VALUES ('work','工作','work',0,'t','t',NULL);
        INSERT INTO tasks VALUES ('a','未完成旧任务','work',0,7,'created','updated',NULL,9,'remote',NULL,'2026-11-10');
        INSERT INTO tasks VALUES ('b','完成旧任务','work',1,8,'t','t',NULL,3,NULL,'a',NULL);
        INSERT INTO tasks VALUES ('deleted','墓碑','work',1,9,'t','t','deleted',4,NULL,NULL,NULL);
        PRAGMA user_version=4;").unwrap();
    // A real legacy outbox row, not just an in-memory serialization fixture.
    let payload = r#"{"id":"b","title":"完成旧任务","category":"work","completed":true,"position":8,"created_at":"t","updated_at":"t","deleted_at":null,"revision":3,"parent_id":"a","due_date":null}"#;
    db.execute("INSERT INTO sync_outbox VALUES ('old','b','update',2,?,'t')", [payload]).unwrap();
}

#[test]
fn v4_migrates_preserves_data_and_is_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    version_four(&file);
    let mut store = Store::open(&file).unwrap();
    let tasks = store.list_tasks().unwrap();
    let a = tasks.iter().find(|task| task.id == "a").unwrap();
    assert_eq!(a.status, TaskStatus::Todo);
    assert!(!a.completed);
    assert_eq!((a.title.as_str(), a.position, a.revision), ("未完成旧任务", 7, 9));
    assert_eq!((a.created_at.as_str(), a.updated_at.as_str(), a.due_date.as_deref()), ("created", "updated", Some("2026-11-10")));
    assert!(tasks.iter().all(|task| task.start_date.is_none()));
    let b = tasks.iter().find(|task| task.id == "b").unwrap();
    assert_eq!((b.completed, b.status, b.parent_id.as_deref()), (true, TaskStatus::Done, Some("a")));
    assert_eq!(store.list_groups().unwrap()[0].name, "工作");
    store.set_status("a", TaskStatus::Doing).unwrap();
    drop(store);
    let reopened = Store::open(&file).unwrap();
    assert_eq!(reopened.list_tasks().unwrap().iter().find(|task| task.id == "a").unwrap().status, TaskStatus::Doing);
    let db = Connection::open(&file).unwrap();
    let version: i64 = db.pragma_query_value(None, "user_version", |r| r.get(0)).unwrap();
    assert_eq!(version, 5);
    assert_eq!(db.query_row("SELECT remote_revision FROM tasks WHERE id='a'", [], |r| r.get::<_, String>(0)).unwrap(), "remote");
    assert_eq!(db.query_row("SELECT status FROM tasks WHERE id='deleted'", [], |r| r.get::<_, String>(0)).unwrap(), "done");
    assert_eq!(db.query_row("SELECT count(*) FROM tasks", [], |r| r.get::<_, i64>(0)).unwrap(), 3);
}

#[test]
fn failed_migration_rolls_back_schema_and_version_and_can_retry() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    version_four(&file);
    let db = Connection::open(&file).unwrap();
    // Force failure after both columns have been added and completed rows have been mapped.
    db.execute_batch("CREATE INDEX task_status ON tasks(title);").unwrap();
    assert!(Store::open(&file).is_err());
    assert_eq!(db.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0)).unwrap(), 4);
    assert!(db.prepare("SELECT status FROM tasks").is_err());
    assert!(db.prepare("SELECT start_date FROM tasks").is_err());
    assert_eq!(db.query_row("SELECT completed FROM tasks WHERE id='b'", [], |r| r.get::<_, bool>(0)).unwrap(), true);
    db.execute_batch("DROP INDEX task_status;").unwrap();
    assert!(Store::open(&file).is_ok());
}

#[test]
fn completion_and_status_agree_in_both_directions_and_in_outbox() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    let mut store = Store::open(&file).unwrap();
    let parent = store.add_task("父", "work").unwrap();
    let child = store.add_task_in("子", "work", Some(&parent.id)).unwrap();
    assert_eq!(parent.status, TaskStatus::Todo);
    let doing = store.set_status(&child.id, TaskStatus::Doing).unwrap();
    assert!(!doing.completed);
    // Category-only updates preserve doing for the child.
    store.patch_task(&parent.id, None, Some("life"), None).unwrap();
    assert_eq!(store.list_tasks().unwrap().iter().find(|task| task.id == child.id).unwrap().status, TaskStatus::Doing);
    let done = store.patch_task(&parent.id, None, None, Some(true)).unwrap();
    assert_eq!(done.status, TaskStatus::Done);
    assert!(store.list_tasks().unwrap().iter().all(|task| task.completed && task.status == TaskStatus::Done));
    let todo = store.patch_task(&parent.id, None, None, Some(false)).unwrap();
    assert_eq!((todo.status, todo.completed), (TaskStatus::Todo, false));
    let doing = store.set_status(&parent.id, TaskStatus::Doing).unwrap();
    assert_eq!((doing.status, doing.completed), (TaskStatus::Doing, false));
    assert!(store.set_status(&parent.id, TaskStatus::Done).unwrap().completed);
    let before = store.list_tasks().unwrap();
    assert!(store.patch_task_with_status(&parent.id, None, None, Some(false), Some(TaskStatus::Done)).is_err());
    assert_eq!(store.list_tasks().unwrap(), before);
    store.delete_task(&parent.id).unwrap();
    store.restore_task(&parent.id).unwrap();
    let db = Connection::open(&file).unwrap();
    let mut query = db.prepare("SELECT payload FROM sync_outbox").unwrap();
    for payload in query.query_map([], |r| r.get::<_, String>(0)).unwrap() {
        let payload: serde_json::Value = serde_json::from_str(&payload.unwrap()).unwrap();
        assert_eq!(payload["completed"].as_bool().unwrap(), payload["status"] == "done");
        assert!(payload.get("start_date").is_some());
    }
}

#[test]
fn date_range_validation_rejects_both_write_directions_atomically() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    let mut store = Store::open(&file).unwrap();
    let task = store.add_task("日期", "work").unwrap();
    store.set_due_date(&task.id, Some("2026-11-10")).unwrap();
    let before = store.list_tasks().unwrap();
    assert!(store.set_start_date(&task.id, Some("2026-11-11")).unwrap_err().to_string().contains("开始日不能晚于到期日"));
    assert_eq!(store.list_tasks().unwrap(), before);
    store.set_start_date(&task.id, Some("2026-11-10")).unwrap();
    let before = store.list_tasks().unwrap();
    let db = Connection::open(&file).unwrap();
    let count = || db.query_row("SELECT count(*) FROM sync_outbox", [], |r| r.get::<_, i64>(0)).unwrap();
    let old_count = count();
    assert!(store.set_due_date(&task.id, Some("2026-11-09")).is_err());
    assert!(store.set_start_date(&task.id, Some("2026-02-30")).is_err());
    assert!(store.set_start_date(&task.id, Some("2026-1-01")).is_err());
    assert_eq!(store.list_tasks().unwrap(), before);
    assert_eq!(count(), old_count);
    store.set_due_date(&task.id, None).unwrap();
    store.set_start_date(&task.id, Some("2027-01-01")).unwrap();
    assert_eq!(store.set_start_date(&task.id, None).unwrap().start_date, None);
}

#[test]
fn legacy_outbox_json_defaults_status_from_completed_and_start_to_none() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    version_four(&file);
    let _store = Store::open(&file).unwrap();
    let db = Connection::open(&file).unwrap();
    let payload: String = db.query_row("SELECT payload FROM sync_outbox WHERE operation_id='old'", [], |r| r.get(0)).unwrap();
    let done: Task = serde_json::from_str(&payload).unwrap();
    assert_eq!((done.status, done.start_date), (TaskStatus::Done, None));
    let todo: Task = serde_json::from_str(&payload.replace("\"completed\":true", "\"completed\":false")).unwrap();
    assert_eq!((todo.status, todo.completed), (TaskStatus::Todo, false));
    let mut modern = serde_json::to_value(todo).unwrap();
    modern["status"] = serde_json::json!("doing");
    assert_eq!(serde_json::from_value::<Task>(modern).unwrap().status, TaskStatus::Doing);
}

#[test]
fn board_reorders_across_groups_even_when_positions_are_tied() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    let mut store = Store::open(&file).unwrap();
    let a = store.add_task("a", "work").unwrap();
    let b = store.add_task("b", "life").unwrap();
    let c = store.add_task("c", "study").unwrap();
    store.set_status(&c.id, TaskStatus::Doing).unwrap();
    let db = Connection::open(&file).unwrap();
    db.execute("UPDATE tasks SET position=0 WHERE id IN (?,?)", params![a.id, b.id]).unwrap();
    let mut peers = store.list_tasks().unwrap().into_iter().filter(|task| task.status == TaskStatus::Todo).collect::<Vec<_>>();
    peers.sort_by(|a,b| (a.position, &a.id).cmp(&(b.position, &b.id)));
    let first = peers[0].id.clone();
    store.move_status_task(&first, 1).unwrap();
    let tasks = store.list_tasks().unwrap();
    let mut after = tasks.iter().filter(|task| task.status == TaskStatus::Todo).collect::<Vec<_>>();
    after.sort_by_key(|task| task.position);
    assert_eq!(after[1].id, first);
    assert_eq!(tasks.iter().find(|task| task.id == c.id).unwrap().position, c.position);
    assert!(store.move_status_task(&first, 0).is_err());
}


#[test]
fn date_range_update_is_atomic_and_validated() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("tasks.sqlite")).unwrap();
    let task = store.add_task("范围", "work").unwrap();
    store.set_date_range(&task.id, Some("2026-11-01"), Some("2026-11-02")).unwrap();
    let before = store.list_tasks().unwrap();
    assert!(store.set_date_range(&task.id, Some("2026-11-04"), Some("2026-11-03")).is_err());
    assert_eq!(store.list_tasks().unwrap(), before);
    let moved = store.set_date_range(&task.id, Some("2026-11-10"), Some("2026-11-11")).unwrap();
    assert_eq!((moved.start_date.as_deref(), moved.due_date.as_deref()), (Some("2026-11-10"), Some("2026-11-11")));
}
