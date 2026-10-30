use dotist_core::Store;
use rusqlite::Connection;

#[test]
fn due_dates_can_be_set_validated_and_cleared() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("tasks.sqlite")).unwrap();
    let task = store.add_task("交报告", "work").unwrap();
    assert_eq!(task.due_date, None);
    let set = store.set_due_date(&task.id, Some("2026-11-03")).unwrap();
    assert_eq!(set.due_date.as_deref(), Some("2026-11-03"));
    assert_eq!(set.revision, task.revision + 1);
    assert!(store.set_due_date(&task.id, Some("2026-02-30")).is_err());
    assert!(store.set_due_date(&task.id, Some("明天")).is_err());
    assert!(store.set_due_date("missing", Some("2026-11-03")).is_err());
    assert_eq!(store.list_tasks().unwrap()[0].due_date.as_deref(), Some("2026-11-03"));
    let cleared = store.set_due_date(&task.id, None).unwrap();
    assert_eq!(cleared.due_date, None);
}

#[test]
fn migration_from_version_three_adds_due_date_and_keeps_tasks() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    {
        let db = Connection::open(&file).unwrap();
        db.execute_batch("CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, category TEXT NOT NULL, completed INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, revision INTEGER NOT NULL, remote_revision TEXT, parent_id TEXT);
            CREATE TABLE sync_outbox (operation_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, kind TEXT NOT NULL, base_revision INTEGER, payload TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE task_groups (id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL, position INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT);
            INSERT INTO task_groups VALUES ('work','工作','work',0,'t','t',NULL);
            INSERT INTO tasks VALUES ('a','旧任务','work',0,0,'t','t',NULL,1,NULL,NULL);
            PRAGMA user_version=3;").unwrap();
    }
    let mut store = Store::open(&file).unwrap();
    let tasks = store.list_tasks().unwrap();
    assert_eq!((tasks[0].title.as_str(), tasks[0].due_date.clone()), ("旧任务", None));
    store.set_due_date("a", Some("2026-12-01")).unwrap();
    drop(store);
    let version: i64 = Connection::open(&file).unwrap().pragma_query_value(None, "user_version", |r| r.get(0)).unwrap();
    assert_eq!(version, 5);
}
