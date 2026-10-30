use dotist_core::Store;
use rusqlite::Connection;

fn store() -> (tempfile::TempDir, Store) {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(&dir.path().join("tasks.sqlite")).unwrap();
    (dir, store)
}

#[test]
fn fresh_database_has_the_three_default_groups() {
    let (_dir, store) = store();
    let names: Vec<_> = store.list_groups().unwrap().into_iter().map(|g| (g.id, g.name, g.color)).collect();
    assert_eq!(names, vec![("work".into(), "工作".into(), "work".into()), ("life".into(), "生活".into(), "life".into()), ("study".into(), "学习".into(), "study".into())]);
}

#[test]
fn migration_from_version_two_adds_groups_and_keeps_tasks() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    {
        let db = Connection::open(&file).unwrap();
        db.execute_batch("CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, category TEXT NOT NULL, completed INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, revision INTEGER NOT NULL, remote_revision TEXT, parent_id TEXT);
            CREATE TABLE sync_outbox (operation_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, kind TEXT NOT NULL, base_revision INTEGER, payload TEXT NOT NULL, created_at TEXT NOT NULL);
            INSERT INTO tasks VALUES ('a','旧任务','study',0,0,'t','t',NULL,1,NULL,NULL);
            PRAGMA user_version=2;").unwrap();
    }
    let mut store = Store::open(&file).unwrap();
    assert_eq!(store.list_groups().unwrap().len(), 3);
    assert_eq!(store.list_tasks().unwrap()[0].category, "study");
    store.add_task("新任务", "学习").unwrap();
}

#[test]
fn groups_can_be_added_renamed_recolored_and_reordered() {
    let (_dir, mut store) = store();
    let group = store.add_group("  读书  ", None).unwrap();
    assert_eq!((group.name.as_str(), group.color.as_str(), group.position), ("读书", "teal", 3));
    assert!(store.add_group("读书", None).is_err());
    assert!(store.add_group("  ", None).is_err());
    assert!(store.add_group("x", Some("neon")).is_err());
    let renamed = store.update_group(&group.id, Some("阅读"), Some("rose")).unwrap();
    assert_eq!((renamed.name.as_str(), renamed.color.as_str()), ("阅读", "rose"));
    assert!(store.update_group(&group.id, Some("工作"), None).is_err());
    store.move_group(&group.id, -1).unwrap();
    let ids: Vec<_> = store.list_groups().unwrap().into_iter().map(|g| g.id).collect();
    assert_eq!(ids[2], group.id);
    let task = store.add_task("读第一章", "阅读").unwrap();
    assert_eq!(task.category, group.id);
}

#[test]
fn deleting_a_group_removes_its_tasks_and_restore_brings_them_back() {
    let (_dir, mut store) = store();
    let group = store.add_group("临时", None).unwrap();
    let parent = store.add_task("甲", &group.id).unwrap();
    store.add_task_in("乙", &group.id, Some(&parent.id)).unwrap();
    let keep = store.add_task("留下", "work").unwrap();
    store.delete_group(&group.id).unwrap();
    assert_eq!(store.list_groups().unwrap().len(), 3);
    assert_eq!(store.list_tasks().unwrap().iter().map(|t| t.id.clone()).collect::<Vec<_>>(), vec![keep.id.clone()]);
    assert!(store.add_task("丙", &group.id).is_err());
    store.restore_group(&group.id).unwrap();
    assert_eq!(store.list_groups().unwrap().len(), 4);
    assert_eq!(store.list_tasks().unwrap().len(), 3);
}

#[test]
fn the_last_group_cannot_be_deleted() {
    let (_dir, mut store) = store();
    store.delete_group("life").unwrap();
    store.delete_group("study").unwrap();
    assert!(store.delete_group("work").is_err());
}

#[test]
fn indent_and_outdent_change_the_task_level() {
    let (_dir, mut store) = store();
    let a = store.add_task("A", "work").unwrap();
    let b = store.add_task("B", "work").unwrap();
    let c = store.add_task("C", "work").unwrap();
    let indented = store.reparent_task(&b.id, Some(&a.id)).unwrap();
    assert_eq!(indented.parent_id.as_deref(), Some(a.id.as_str()));
    assert!(store.reparent_task(&a.id, Some(&c.id)).is_err(), "a task with children cannot be indented");
    assert!(store.reparent_task(&c.id, Some(&b.id)).is_err(), "only one level");
    assert!(store.reparent_task(&a.id, None).is_err(), "already top level");
    let out = store.reparent_task(&b.id, None).unwrap();
    assert_eq!(out.parent_id, None);
    let tops: Vec<_> = store.list_tasks().unwrap().into_iter().filter(|t| t.parent_id.is_none()).map(|t| t.title).collect();
    assert_eq!(tops, vec!["A", "B", "C"]);
}
