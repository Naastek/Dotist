use dotist_core::Store;
use rusqlite::Connection;

#[test]
fn changes_are_visible_across_handles_and_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    let mut ui = Store::open(&file).unwrap();
    let mut mcp = Store::open(&file).unwrap();
    let first = ui.add_task("  买牛奶  ", "life").unwrap();
    assert_eq!(first.title, "买牛奶");
    assert_eq!(mcp.list_tasks().unwrap().len(), 1);
    mcp.update_task(&first.id, "买豆奶", "study", true).unwrap();
    let changed = &ui.list_tasks().unwrap()[0];
    assert_eq!(changed.title, "买豆奶");
    assert!(changed.completed);
    assert_eq!(changed.category, "study");
    assert_eq!(changed.revision, 2);
    drop(ui);
    assert_eq!(Store::open(&file).unwrap().list_tasks().unwrap()[0].title, "买豆奶");
}

#[test]
fn deletion_creates_tombstone_and_outbox_entry() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    let mut store = Store::open(&file).unwrap();
    let task = store.add_task("报告", "work").unwrap();
    store.delete_task(&task.id).unwrap();
    assert!(store.list_tasks().unwrap().is_empty());
    let db = Connection::open(file).unwrap();
    let deleted: Option<String> = db.query_row("SELECT deleted_at FROM tasks WHERE id = ?", [&task.id], |r| r.get(0)).unwrap();
    assert!(deleted.is_some());
    let count: i64 = db.query_row("SELECT COUNT(*) FROM sync_outbox WHERE task_id = ?", [&task.id], |r| r.get(0)).unwrap();
    assert_eq!(count, 2);
}

#[test]
fn failed_outbox_write_rolls_back_task() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    let mut store = Store::open(&file).unwrap();
    let db = Connection::open(file).unwrap();
    db.execute_batch("CREATE TRIGGER fail_outbox BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(FAIL, 'stop'); END;").unwrap();
    assert!(store.add_task("不要丢失", "work").is_err());
    assert!(store.list_tasks().unwrap().is_empty());
}

#[test]
fn movement_changes_order_in_its_category() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("tasks.sqlite")).unwrap();
    let one = store.add_task("one", "work").unwrap();
    let two = store.add_task("two", "work").unwrap();
    store.add_task("other", "life").unwrap();
    store.move_task(&two.id, -1).unwrap();
    let work: Vec<_> = store.list_tasks().unwrap().into_iter().filter(|t| t.category == "work").map(|t| t.id).collect();
    assert_eq!(work, vec![two.id, one.id]);
}

#[test]
fn invalid_inputs_never_create_tasks() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("tasks.sqlite")).unwrap();
    assert!(store.add_task("   ", "work").is_err());
    assert!(store.add_task("valid", "unknown").is_err());
    assert!(store.list_tasks().unwrap().is_empty());
}

#[test]
fn independent_partial_edits_preserve_other_fields() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    let mut ui = Store::open(&file).unwrap();
    let mut mcp = Store::open(&file).unwrap();
    let task = ui.add_task("原任务", "work").unwrap();
    ui.patch_task(&task.id, Some("新名称"), None, None).unwrap();
    mcp.patch_task(&task.id, None, None, Some(true)).unwrap();
    let result = ui.list_tasks().unwrap().pop().unwrap();
    assert_eq!(result.title, "新名称");
    assert!(result.completed);
}

#[test]
fn subtasks_follow_parent_and_stay_one_level() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("tasks.sqlite")).unwrap();
    let parent = store.add_task("写报告", "work").unwrap();
    let child = store.add_task_in("列提纲", "life", Some(&parent.id)).unwrap();
    assert_eq!(child.parent_id.as_deref(), Some(parent.id.as_str()));
    assert_eq!(child.category, "work");
    assert!(store.add_task_in("再嵌套", "work", Some(&child.id)).is_err());
    assert!(store.patch_task(&child.id, None, Some("life"), None).is_err());
    store.patch_task(&parent.id, None, Some("study"), None).unwrap();
    let tasks = store.list_tasks().unwrap();
    assert!(tasks.iter().all(|t| t.category == "study"));
}

#[test]
fn completing_parent_completes_children_but_not_the_reverse() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("tasks.sqlite")).unwrap();
    let parent = store.add_task("P", "work").unwrap();
    let a = store.add_task_in("a", "work", Some(&parent.id)).unwrap();
    let b = store.add_task_in("b", "work", Some(&parent.id)).unwrap();
    store.patch_task(&a.id, None, None, Some(true)).unwrap();
    store.patch_task(&b.id, None, None, Some(true)).unwrap();
    assert!(!store.list_tasks().unwrap().iter().find(|t| t.id == parent.id).unwrap().completed);
    store.patch_task(&a.id, None, None, Some(false)).unwrap();
    store.patch_task(&parent.id, None, None, Some(true)).unwrap();
    assert!(store.list_tasks().unwrap().iter().all(|t| t.completed));
}

#[test]
fn delete_and_restore_bring_back_task_position_and_subtasks() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("tasks.sqlite")).unwrap();
    let one = store.add_task("one", "work").unwrap();
    let two = store.add_task("two", "work").unwrap();
    let child = store.add_task_in("child", "work", Some(&two.id)).unwrap();
    store.delete_task(&two.id).unwrap();
    assert_eq!(store.list_tasks().unwrap().len(), 1);
    assert!(store.restore_task(&child.id).is_err());
    let restored = store.restore_task(&two.id).unwrap();
    assert_eq!(restored.position, two.position);
    let ids: Vec<_> = store.list_tasks().unwrap().into_iter().map(|t| t.id).collect();
    assert_eq!(ids.len(), 3);
    assert!(ids.contains(&one.id) && ids.contains(&child.id));
    assert!(store.restore_task(&two.id).is_err());
}

#[test]
fn subtask_movement_stays_among_siblings() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("tasks.sqlite")).unwrap();
    let parent = store.add_task("P", "work").unwrap();
    let other = store.add_task("Q", "work").unwrap();
    let a = store.add_task_in("a", "work", Some(&parent.id)).unwrap();
    let b = store.add_task_in("b", "work", Some(&parent.id)).unwrap();
    store.move_task(&a.id, -1).unwrap();
    assert_eq!(store.list_tasks().unwrap().iter().find(|t| t.id == a.id).unwrap().position, a.position);
    store.move_task(&b.id, -1).unwrap();
    let tasks = store.list_tasks().unwrap();
    assert!(tasks.iter().find(|t| t.id == b.id).unwrap().position < tasks.iter().find(|t| t.id == a.id).unwrap().position);
    assert_eq!(tasks.iter().find(|t| t.id == other.id).unwrap().position, other.position);
}

#[test]
fn migration_from_version_one_keeps_existing_data() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    {
        let db = Connection::open(&file).unwrap();
        db.execute_batch("CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, category TEXT NOT NULL, completed INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, revision INTEGER NOT NULL, remote_revision TEXT);
            CREATE TABLE sync_outbox (operation_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, kind TEXT NOT NULL, base_revision INTEGER, payload TEXT NOT NULL, created_at TEXT NOT NULL);
            INSERT INTO tasks VALUES ('old','旧任务','life',1,0,'t','t',NULL,3,NULL);
            PRAGMA user_version=1;").unwrap();
    }
    let store = Store::open(&file).unwrap();
    let tasks = store.list_tasks().unwrap();
    assert_eq!(tasks.len(), 1);
    assert_eq!((tasks[0].title.as_str(), tasks[0].completed, tasks[0].revision, tasks[0].parent_id.clone()), ("旧任务", true, 3, None));
    drop(store);
    let version: i64 = Connection::open(&file).unwrap().pragma_query_value(None, "user_version", |r| r.get(0)).unwrap();
    assert_eq!(version, 5);
}
