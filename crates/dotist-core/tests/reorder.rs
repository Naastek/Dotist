use dotist_core::Store;
use rusqlite::{params, Connection};

#[test]
fn reorder_is_persistent_and_preserves_hierarchy_and_other_groups() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tasks.sqlite");
    let mut store = Store::open(&path).unwrap();
    let a = store.add_task("a", "work").unwrap();
    let b = store.add_task("b", "work").unwrap();
    let c = store.add_task("c", "work").unwrap();
    let child_a = store.add_task_in("child a", "work", Some(&a.id)).unwrap();
    let child_b = store.add_task_in("child b", "work", Some(&a.id)).unwrap();
    let other = store.add_task("other", "life").unwrap();
    store.reorder_task(&c.id, &a.id, false, false).unwrap();
    store.reorder_task(&child_b.id, &child_a.id, false, false).unwrap();
    assert!(store.reorder_task(&c.id, &other.id, false, false).is_err());
    assert!(store.reorder_task(&child_b.id, &b.id, false, false).is_err());
    drop(store);
    let tasks = Store::open(&path).unwrap().list_tasks().unwrap();
    let work: Vec<_> = tasks.iter().filter(|task| task.category == "work" && task.parent_id.is_none()).map(|task| task.id.as_str()).collect();
    let children: Vec<_> = tasks.iter().filter(|task| task.parent_id.as_deref() == Some(&a.id)).map(|task| task.id.as_str()).collect();
    assert_eq!(work, vec![c.id, a.id, b.id]);
    assert_eq!(children, vec![child_b.id, child_a.id]);
    assert_eq!(tasks.iter().find(|task| task.id == other.id).unwrap().category, other.category);
}

#[test]
fn tied_positions_reorder_and_outbox_failure_rolls_back_the_whole_move() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tasks.sqlite");
    let mut store = Store::open(&path).unwrap();
    let a = store.add_task("a", "work").unwrap();
    let b = store.add_task("b", "work").unwrap();
    let db = Connection::open(&path).unwrap();
    db.execute("UPDATE tasks SET position=0 WHERE id IN (?,?)", params![a.id, b.id]).unwrap();
    store.reorder_task(&b.id, &a.id, false, false).unwrap();
    let ordered = store.list_tasks().unwrap();
    assert_eq!(ordered.iter().map(|task| task.id.as_str()).collect::<Vec<_>>(), vec![b.id.as_str(), a.id.as_str()]);
    db.execute_batch("CREATE TRIGGER fail_reorder_outbox BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(FAIL, 'stop'); END;").unwrap();
    assert!(store.reorder_task(&a.id, &b.id, false, false).is_err());
    assert_eq!(store.list_tasks().unwrap(), ordered);
}

#[test]
fn cross_group_order_keeps_group_parent_and_distant_tasks_unchanged() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tasks.sqlite");
    let mut store = Store::open(&path).unwrap();
    let parent = store.add_task("parent", "work").unwrap();
    let child = store.add_task_in("child", "work", Some(&parent.id)).unwrap();
    let other = store.add_task("other", "life").unwrap();
    let distant = store.add_task("distant", "study").unwrap();
    Connection::open(&path).unwrap().execute("UPDATE tasks SET position=1000 WHERE id=?", [&distant.id]).unwrap();
    let distant_before = store.list_tasks().unwrap().into_iter().find(|task| task.id == distant.id).unwrap();
    store.reorder_task(&other.id, &child.id, true, true).unwrap();
    drop(store);
    let mut tasks = Store::open(&path).unwrap().list_tasks().unwrap();
    assert_eq!(tasks.iter().find(|task| task.id == distant.id).unwrap(), &distant_before);
    let other_after = tasks.iter().find(|task| task.id == other.id).unwrap();
    assert_eq!(other_after.category, "life");
    assert_eq!(other_after.parent_id, None);
    assert_eq!(tasks.iter().find(|task| task.id == child.id).unwrap().parent_id.as_deref(), Some(parent.id.as_str()));
    tasks.sort_by(|a, b| (a.position, &a.id).cmp(&(b.position, &b.id)));
    let child_index = tasks.iter().position(|task| task.id == child.id).unwrap();
    assert_eq!(tasks[child_index + 1].id, other.id);
}

#[test]
fn reordering_does_not_make_an_old_completed_task_look_newly_completed() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tasks.sqlite");
    let mut store = Store::open(&path).unwrap();
    store.add_task("a", "work").unwrap();
    let completed = store.add_task("completed", "work").unwrap();
    let c = store.add_task("c", "work").unwrap();
    store.add_task("after", "work").unwrap();
    store.set_due_date(&completed.id, Some("2026-01-01")).unwrap();
    store.patch_task(&completed.id, None, None, Some(true)).unwrap();
    let db = Connection::open(&path).unwrap();
    db.execute("UPDATE tasks SET updated_at='2026-01-02T00:00:00Z' WHERE id=?", [&completed.id]).unwrap();
    let before = store.list_tasks().unwrap().into_iter().find(|task| task.id == completed.id).unwrap();
    store.reorder_task(&c.id, &completed.id, false, false).unwrap();
    let after = store.list_tasks().unwrap().into_iter().find(|task| task.id == completed.id).unwrap();
    assert_ne!(after.position, before.position);
    assert_eq!(after.updated_at, before.updated_at);
    assert_eq!(after.revision, before.revision + 1);
    let entries: i64 = db.query_row("SELECT COUNT(*) FROM sync_outbox WHERE task_id=? AND kind='reorder'", [&completed.id], |row| row.get(0)).unwrap();
    assert_eq!(entries, 1);
}

#[test]
fn sibling_reorder_preserves_the_relative_order_of_other_groups() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tasks.sqlite");
    let mut store = Store::open(&path).unwrap();
    let a = store.add_task("a", "work").unwrap();
    let x = store.add_task("x", "life").unwrap();
    let b = store.add_task("b", "work").unwrap();
    let db = Connection::open(&path).unwrap();
    db.execute("UPDATE tasks SET position=0 WHERE id=?", [&a.id]).unwrap();
    db.execute("UPDATE tasks SET position=1 WHERE id=?", [&x.id]).unwrap();
    db.execute("UPDATE tasks SET position=5 WHERE id=?", [&b.id]).unwrap();
    store.reorder_task(&b.id, &a.id, false, false).unwrap();
    let mut tasks = store.list_tasks().unwrap();
    tasks.sort_by(|a, b| (a.position, &a.id).cmp(&(b.position, &b.id)));
    assert_eq!(tasks.iter().map(|task| task.id.as_str()).collect::<Vec<_>>(), vec![b.id.as_str(), a.id.as_str(), x.id.as_str()]);
}

#[test]
fn existing_move_commands_preserve_cross_view_order() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tasks.sqlite");
    let mut store = Store::open(&path).unwrap();
    let a = store.add_task("a", "work").unwrap();
    let x = store.add_task("x", "life").unwrap();
    let b = store.add_task("b", "work").unwrap();
    store.set_status(&x.id, dotist_core::TaskStatus::Doing).unwrap();
    let db = Connection::open(&path).unwrap();
    for (id, position) in [(&a.id, 0), (&x.id, 1), (&b.id, 5)] {
        db.execute("UPDATE tasks SET position=? WHERE id=?", params![position, id]).unwrap();
    }
    store.move_status_task(&a.id, 1).unwrap();
    let mut tasks = store.list_tasks().unwrap();
    tasks.sort_by(|a, b| (a.position, &a.id).cmp(&(b.position, &b.id)));
    assert_eq!(tasks.iter().map(|task| task.id.as_str()).collect::<Vec<_>>(), vec![x.id.as_str(), b.id.as_str(), a.id.as_str()]);
    store.move_task(&a.id, -1).unwrap();
    let mut tasks = store.list_tasks().unwrap();
    tasks.sort_by(|a, b| (a.position, &a.id).cmp(&(b.position, &b.id)));
    assert_eq!(tasks.iter().map(|task| task.id.as_str()).collect::<Vec<_>>(), vec![x.id.as_str(), a.id.as_str(), b.id.as_str()]);
}
