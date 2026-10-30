use dotist_core::Store;
use rusqlite::{types::Value, Connection, OpenFlags};
use std::{fs, path::{Path, PathBuf}, time::{Duration, SystemTime}};

fn version_four(file: &Path) -> Connection {
    let db = Connection::open(file).unwrap();
    db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
        CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, category TEXT NOT NULL, completed INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, revision INTEGER NOT NULL, remote_revision TEXT, parent_id TEXT, due_date TEXT);
        CREATE TABLE sync_outbox (operation_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, kind TEXT NOT NULL, base_revision INTEGER, payload TEXT NOT NULL, created_at TEXT NOT NULL);
        CREATE TABLE task_groups (id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL, position INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT);
        PRAGMA user_version=4;
        PRAGMA wal_checkpoint(TRUNCATE);
        INSERT INTO task_groups VALUES ('work','工作','work',0,'t','t',NULL);
        INSERT INTO tasks VALUES ('old','旧任务','work',1,7,'created','updated',NULL,9,'remote',NULL,'2026-11-10');
        INSERT INTO tasks VALUES ('deleted','已删除','work',0,8,'t','t','deleted',2,NULL,NULL,NULL);
        INSERT INTO sync_outbox VALUES ('op','old','update',8,'legacy payload','t');").unwrap();
    db
}

fn backup_paths(directory: &Path) -> Vec<PathBuf> {
    let directory = directory.join("backups");
    if !directory.exists() { return Vec::new(); }
    let mut paths = fs::read_dir(directory).unwrap().map(|entry| entry.unwrap())
        .filter(|entry| {
            let name = entry.file_name();
            let name = name.to_str().unwrap();
            entry.file_type().unwrap().is_file() && name.starts_with("tasks-v") && name.ends_with(".sqlite")
        }).map(|entry| entry.path()).collect::<Vec<_>>();
    paths.sort();
    paths
}

fn rows(db: &Connection, sql: &str) -> Vec<Vec<Value>> {
    let mut statement = db.prepare(sql).unwrap();
    let columns = statement.column_count();
    statement.query_map([], |row| (0..columns).map(|index| row.get(index)).collect())
        .unwrap().collect::<rusqlite::Result<_>>().unwrap()
}

#[test]
fn migration_backs_up_version_four_schema_and_data_including_wal() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    let db = version_four(&file);
    assert!(fs::metadata(dir.path().join("tasks.sqlite-wal")).unwrap().len() > 0);
    let queries = [
        "SELECT * FROM tasks ORDER BY id",
        "SELECT * FROM task_groups ORDER BY id",
        "SELECT * FROM sync_outbox ORDER BY operation_id",
        "SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name",
    ];
    let original = queries.map(|sql| rows(&db, sql));

    let store = Store::open(&file).unwrap();
    assert_eq!(store.list_tasks().unwrap()[0].title, "旧任务");
    assert_eq!(db.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0)).unwrap(), 5);
    let backups = backup_paths(dir.path());
    assert_eq!(backups.len(), 1);
    let name = backups[0].file_name().unwrap().to_str().unwrap();
    let stamp = name.strip_prefix("tasks-v4-").unwrap().strip_suffix(".sqlite").unwrap();
    chrono::NaiveDateTime::parse_from_str(stamp, "%Y%m%dT%H%M%S%.9fZ").unwrap();
    let backup = Connection::open_with_flags(&backups[0], OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert_eq!(backup.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0)).unwrap(), 4);
    assert_eq!(backup.pragma_query_value(None, "integrity_check", |r| r.get::<_, String>(0)).unwrap(), "ok");
    for (sql, expected) in queries.into_iter().zip(original) {
        assert_eq!(rows(&backup, sql), expected, "{sql}");
    }
}

#[test]
fn new_database_does_not_create_backups() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    let _store = Store::open(&file).unwrap();
    assert!(!dir.path().join("backups").exists());
}

#[test]
fn existing_version_zero_database_does_not_create_backups() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    drop(Connection::open(&file).unwrap());
    let _store = Store::open(&file).unwrap();
    assert!(!dir.path().join("backups").exists());
}

#[test]
fn reopening_latest_database_does_not_create_backups() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    drop(Store::open(&file).unwrap());
    drop(Store::open(&file).unwrap());
    assert!(!dir.path().join("backups").exists());

    fs::remove_file(&file).unwrap();
    drop(version_four(&file));
    drop(Store::open(&file).unwrap());
    let backups = backup_paths(dir.path());
    assert_eq!(backups.len(), 1);
    drop(Store::open(&file).unwrap());
    assert_eq!(backup_paths(dir.path()), backups);
}

#[test]
fn retention_keeps_five_newest_backups_and_preserves_other_files() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    let _db = version_four(&file);
    let backups = dir.path().join("backups");
    fs::create_dir(&backups).unwrap();
    let mut old = Vec::new();
    for index in 0..7 {
        let path = backups.join(format!("tasks-v{}-20000101T000000Z.sqlite", 9 - index));
        let handle = fs::File::create(&path).unwrap();
        let modified = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000 + index);
        handle.set_times(fs::FileTimes::new().set_modified(modified)).unwrap();
        old.push(path);
    }
    let unrelated = ["notes.txt", "tasks.sqlite", "tasks-v4-old.sqlite-wal", "other-v4-old.sqlite"];
    for name in unrelated { fs::write(backups.join(name), "keep").unwrap(); }
    let nested = backups.join("tasks-v4-directory.sqlite");
    fs::create_dir(&nested).unwrap();
    fs::write(nested.join("tasks-v4-nested.sqlite"), "keep").unwrap();
    let outside = dir.path().join("tasks-v4-outside.sqlite");
    fs::write(&outside, "keep").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&outside, backups.join("tasks-v4-linked.sqlite")).unwrap();

    let _store = Store::open(&file).unwrap();
    let remaining = backup_paths(dir.path());
    assert_eq!(remaining.len(), 5);
    for path in &old[..3] { assert!(!path.exists()); }
    for path in &old[3..] { assert!(remaining.contains(path)); }
    for name in unrelated { assert_eq!(fs::read_to_string(backups.join(name)).unwrap(), "keep"); }
    assert_eq!(fs::read_to_string(nested.join("tasks-v4-nested.sqlite")).unwrap(), "keep");
    assert_eq!(fs::read_to_string(&outside).unwrap(), "keep");
    #[cfg(unix)]
    assert!(fs::symlink_metadata(backups.join("tasks-v4-linked.sqlite")).unwrap().file_type().is_symlink());
    let newest = remaining.iter().find(|path| !old.contains(path)).unwrap();
    let backup = Connection::open_with_flags(newest, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert_eq!(backup.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0)).unwrap(), 4);
}

#[test]
fn failed_backup_stops_before_migration() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    let db = version_four(&file);
    let original = rows(&db, "SELECT * FROM tasks ORDER BY id");
    fs::write(dir.path().join("backups"), "blocked").unwrap();
    let error = Store::open(&file).err().unwrap();
    assert!(error.to_string().contains("迁移前备份任务数据库失败"));
    assert_eq!(db.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0)).unwrap(), 4);
    assert!(db.prepare("SELECT status FROM tasks").is_err());
    assert_eq!(rows(&db, "SELECT * FROM tasks ORDER BY id"), original);
    fs::remove_file(dir.path().join("backups")).unwrap();
    assert!(Store::open(&file).is_ok());
}

#[test]
fn newer_schema_is_rejected_without_changing_database() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("tasks.sqlite");
    {
        let db = Connection::open(&file).unwrap();
        db.execute_batch("CREATE TABLE future (value TEXT); INSERT INTO future VALUES ('保留'); PRAGMA user_version=6;").unwrap();
    }
    let original = fs::read(&file).unwrap();
    let error = Store::open(&file).err().unwrap();
    assert!(error.to_string().contains("数据库版本较新"));
    assert_eq!(fs::read(&file).unwrap(), original);
    assert!(!dir.path().join("backups").exists());
    assert!(!dir.path().join("tasks.sqlite-wal").exists());
    let db = Connection::open(&file).unwrap();
    assert_eq!(db.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0)).unwrap(), 6);
    assert_eq!(db.query_row("SELECT value FROM future", [], |r| r.get::<_, String>(0)).unwrap(), "保留");
    assert_eq!(db.pragma_query_value(None, "journal_mode", |r| r.get::<_, String>(0)).unwrap(), "delete");
}
