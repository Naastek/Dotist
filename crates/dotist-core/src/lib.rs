use anyhow::{bail, Context, Result};
use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};
use std::{path::{Path, PathBuf}, time::Duration};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum TaskStatus { Todo, Doing, Done }
impl TaskStatus {
    fn as_str(self) -> &'static str { match self { Self::Todo => "todo", Self::Doing => "doing", Self::Done => "done" } }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(from = "StoredTask")]
pub struct Task {
    pub id: String,
    pub title: String,
    pub category: String,
    pub completed: bool,
    pub position: i64,
    pub created_at: String,
    pub updated_at: String,
    pub deleted_at: Option<String>,
    pub revision: i64,
    pub parent_id: Option<String>,
    /// Local calendar date `YYYY-MM-DD`, no time of day.
    pub due_date: Option<String>,
    pub status: TaskStatus,
    #[serde(default)]
    pub start_date: Option<String>,
}

#[derive(Deserialize)]
struct StoredTask {
    pub id: String,
    pub title: String,
    pub category: String,
    pub completed: bool,
    pub position: i64,
    pub created_at: String,
    pub updated_at: String,
    pub deleted_at: Option<String>,
    pub revision: i64,
    pub parent_id: Option<String>,
    /// Local calendar date `YYYY-MM-DD`, no time of day.
    pub due_date: Option<String>,
    #[serde(default)]
    pub status: Option<TaskStatus>,
    #[serde(default)]
    pub start_date: Option<String>,
}
impl From<StoredTask> for Task {
    fn from(old: StoredTask) -> Self {
        let status = old.status.unwrap_or(if old.completed { TaskStatus::Done } else { TaskStatus::Todo });
        Self { status, completed: status == TaskStatus::Done, id: old.id, title: old.title, category: old.category, position: old.position, created_at: old.created_at, updated_at: old.updated_at, deleted_at: old.deleted_at, revision: old.revision, parent_id: old.parent_id, due_date: old.due_date, start_date: old.start_date }
    }
}

pub fn database_path() -> Result<PathBuf> {
    if let Some(dir) = std::env::var_os("DOTIST_DATA_DIR") {
        return Ok(PathBuf::from(dir).join("tasks.sqlite"));
    }
    let home = std::env::var_os("HOME").context("无法确定本机用户目录")?;
    Ok(PathBuf::from(home).join("Library/Application Support/com.dotist.app/tasks.sqlite"))
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Group {
    pub id: String,
    pub name: String,
    pub color: String,
    pub position: i64,
}

pub const GROUP_COLORS: [&str; 6] = ["work", "life", "study", "teal", "rose", "moss"];
const LATEST_SCHEMA_VERSION: i64 = 5;

pub struct Store { conn: Connection }

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() { std::fs::create_dir_all(parent)?; }
        let conn = Connection::open(path).context("无法打开任务数据库")?;
        conn.busy_timeout(Duration::from_secs(3))?;
        let version: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version > LATEST_SCHEMA_VERSION { bail!("数据库版本较新，请升级 Dotist 后再打开"); }
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")?;
        if version > 0 && version < LATEST_SCHEMA_VERSION {
            backup_database(&conn, path, version).context("迁移前备份任务数据库失败")?;
        }
        if version == 0 {
            conn.execute_batch("BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY, title TEXT NOT NULL, category TEXT NOT NULL,
                    completed INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL,
                    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT,
                    revision INTEGER NOT NULL, remote_revision TEXT
                );
                CREATE INDEX IF NOT EXISTS task_order ON tasks(category, position, id);
                CREATE TABLE IF NOT EXISTS sync_outbox (
                    operation_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, kind TEXT NOT NULL,
                    base_revision INTEGER, payload TEXT NOT NULL, created_at TEXT NOT NULL
                );
                PRAGMA user_version=1; COMMIT;")?;
        }
        if version < 2 {
            conn.execute_batch("BEGIN IMMEDIATE;
                ALTER TABLE tasks ADD COLUMN parent_id TEXT;
                CREATE INDEX IF NOT EXISTS task_parent ON tasks(parent_id);
                PRAGMA user_version=2; COMMIT;")?;
        }
        if version < 3 {
            let now = timestamp();
            let tx = conn.unchecked_transaction()?;
            tx.execute_batch("CREATE TABLE IF NOT EXISTS task_groups (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL, position INTEGER NOT NULL,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT);")?;
            for (position, (id, name)) in [("work", "工作"), ("life", "生活"), ("study", "学习")].into_iter().enumerate() {
                tx.execute("INSERT OR IGNORE INTO task_groups (id,name,color,position,created_at,updated_at) VALUES (?,?,?,?,?,?)", params![id, name, id, position as i64, now, now])?;
            }
            tx.execute_batch("PRAGMA user_version=3;")?;
            tx.commit()?;
        }
        if version < 4 {
            conn.execute_batch("BEGIN IMMEDIATE;
                ALTER TABLE tasks ADD COLUMN due_date TEXT;
                CREATE INDEX IF NOT EXISTS task_due ON tasks(due_date);
                PRAGMA user_version=4; COMMIT;")?;
        }
        if version < 5 {
            let tx = conn.unchecked_transaction()?;
            tx.execute_batch("ALTER TABLE tasks ADD COLUMN status TEXT NOT NULL DEFAULT 'todo' CHECK(status IN ('todo','doing','done'));
                ALTER TABLE tasks ADD COLUMN start_date TEXT;
                UPDATE tasks SET status=CASE WHEN completed=1 THEN 'done' ELSE 'todo' END;
                CREATE INDEX task_status ON tasks(status,position,id);
                PRAGMA user_version=5;")?;
            tx.commit()?;
        }
        Ok(Self { conn })
    }

    pub fn list_tasks(&self) -> Result<Vec<Task>> {
        let mut stmt = self.conn.prepare(&format!("SELECT {COLUMNS} FROM tasks WHERE deleted_at IS NULL ORDER BY category,position,id"))?;
        let rows = stmt.query_map([], task_from_row)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn add_task(&mut self, title: &str, category: &str) -> Result<Task> {
        self.add_task_in(title, category, None)
    }

    /// Adds a task; with `parent_id` it becomes a one-level subtask that follows its parent's category.
    pub fn add_task_in(&mut self, title: &str, category: &str, parent_id: Option<&str>) -> Result<Task> {
        let title = validated_title(title)?;
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let category = resolve_group(&tx, category)?;
        let category = category.as_str();
        let (category, position): (String, i64) = match parent_id {
            Some(parent_id) => {
                let parent = find_task(&tx, parent_id)?;
                if parent.parent_id.is_some() { bail!("子任务下不能再添加子任务"); }
                let position = tx.query_row("SELECT COALESCE(MAX(position), -1) + 1 FROM tasks WHERE parent_id=? AND deleted_at IS NULL", [parent_id], |r| r.get(0))?;
                (parent.category, position)
            }
            None => {
                let position = tx.query_row("SELECT COALESCE(MAX(position), -1) + 1 FROM tasks WHERE category=? AND parent_id IS NULL AND deleted_at IS NULL", [category], |r| r.get(0))?;
                (category.to_owned(), position)
            }
        };
        let now = timestamp();
        let task = Task { id: Uuid::new_v4().to_string(), title: title.to_owned(), category, completed: false, position, created_at: now.clone(), updated_at: now, deleted_at: None, revision: 1, parent_id: parent_id.map(str::to_owned), due_date: None, start_date: None, status: TaskStatus::Todo };
        tx.execute("INSERT INTO tasks (id,title,category,completed,position,created_at,updated_at,deleted_at,revision,parent_id,due_date) VALUES (?,?,?,?,?,?,?,?,?,?,?)", params![task.id, task.title, task.category, task.completed, task.position, task.created_at, task.updated_at, task.deleted_at, task.revision, task.parent_id, task.due_date])?;
        enqueue(&tx, &task, "create", None)?;
        tx.commit()?;
        Ok(task)
    }

    pub fn update_task(&mut self, id: &str, title: &str, category: &str, completed: bool) -> Result<Task> {
        self.patch_task(id, Some(title), Some(category), Some(completed))
    }

    pub fn patch_task(&mut self, id: &str, title: Option<&str>, category: Option<&str>, completed: Option<bool>) -> Result<Task> {
        self.patch_task_with_status(id, title, category, completed, None)
    }

    pub fn set_status(&mut self, id: &str, status: TaskStatus) -> Result<Task> {
        self.patch_task_with_status(id, None, None, None, Some(status))
    }

    pub fn patch_task_with_status(&mut self, id: &str, title: Option<&str>, category: Option<&str>, completed: Option<bool>, status: Option<TaskStatus>) -> Result<Task> {
        if let (Some(completed), Some(status)) = (completed, status) {
            if completed != (status == TaskStatus::Done) { bail!("完成标记与状态不一致"); }
        }
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let old = find_task(&tx, id)?;
        let title = validated_title(title.unwrap_or(&old.title))?;
        let resolved = match category { Some(value) => resolve_group(&tx, value)?, None => old.category.clone() };
        let category = resolved.as_str();
        if old.parent_id.is_some() && category != old.category { bail!("子任务的分类跟随父任务"); }
        let status = status.unwrap_or_else(|| match completed {
            Some(true) => TaskStatus::Done, Some(false) => TaskStatus::Todo, None => old.status,
        });
        let completed = status == TaskStatus::Done;
        let position = if old.category != category {
            tx.query_row("SELECT COALESCE(MAX(position), -1)+1 FROM tasks WHERE category=? AND parent_id IS NULL AND deleted_at IS NULL", [category], |r| r.get(0))?
        } else { old.position };
        let now = timestamp();
        tx.execute("UPDATE tasks SET title=?,category=?,completed=?,status=?,position=?,updated_at=?,revision=revision+1 WHERE id=?", params![title, category, completed, status.as_str(), position, now, id])?;
        let updated = find_task(&tx, id)?;
        enqueue(&tx, &updated, "update", Some(old.revision))?;
        // Children follow the parent's category, and completing a parent completes them all.
        let cascade_complete = completed && !old.completed;
        let category_changed = old.category != category;
        if cascade_complete || category_changed {
            for child in children_of(&tx, id)? {
                let child_completed = child.completed || cascade_complete;
                if child_completed == child.completed && !category_changed { continue; }
                tx.execute("UPDATE tasks SET category=?,completed=?,status=?,updated_at=?,revision=revision+1 WHERE id=?", params![category, child_completed, if cascade_complete { TaskStatus::Done } else { child.status }.as_str(), now, child.id])?;
                let changed = find_task(&tx, &child.id)?;
                enqueue(&tx, &changed, "update", Some(child.revision))?;
            }
        }
        tx.commit()?;
        Ok(updated)
    }

    /// Sets or clears (`None`) the due date; the date must be a real calendar day written `YYYY-MM-DD`.
    pub fn set_due_date(&mut self, id: &str, due: Option<&str>) -> Result<Task> {
        self.set_date(id, due, false)
    }

    pub fn set_start_date(&mut self, id: &str, start: Option<&str>) -> Result<Task> {
        self.set_date(id, start, true)
    }

    /// Updates both dates in one transaction, including validation and outbox entry.
    pub fn set_date_range(&mut self, id: &str, start: Option<&str>, due: Option<&str>) -> Result<Task> {
        for value in [start, due].into_iter().flatten() {
            let date = chrono::NaiveDate::parse_from_str(value, "%Y-%m-%d").map_err(|_| anyhow::anyhow!("日期格式应为 YYYY-MM-DD"))?;
            if date.format("%Y-%m-%d").to_string() != value { bail!("日期格式应为 YYYY-MM-DD"); }
        }
        if let (Some(start), Some(due)) = (start, due) { if start > due { bail!("开始日不能晚于到期日"); } }
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let old = find_task(&tx, id)?;
        tx.execute("UPDATE tasks SET start_date=?,due_date=?,updated_at=?,revision=revision+1 WHERE id=?", params![start, due, timestamp(), id])?;
        let updated = find_task(&tx, id)?;
        enqueue(&tx, &updated, "update", Some(old.revision))?;
        tx.commit()?;
        Ok(updated)
    }

    fn set_date(&mut self, id: &str, value: Option<&str>, start: bool) -> Result<Task> {
        let value = value.map(|text| -> Result<String> {
            let date = chrono::NaiveDate::parse_from_str(text, "%Y-%m-%d").map_err(|_| anyhow::anyhow!(if start { "开始日格式应为 YYYY-MM-DD" } else { "到期日格式应为 YYYY-MM-DD" }))?;
            if date.format("%Y-%m-%d").to_string() != text { bail!("日期格式应为 YYYY-MM-DD"); }
            Ok(text.to_owned())
        }).transpose()?;
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let old = find_task(&tx, id)?;
        let (start_date, due_date) = if start { (value, old.due_date.clone()) } else { (old.start_date.clone(), value) };
        if let (Some(start), Some(due)) = (&start_date, &due_date) {
            if start > due { bail!("开始日不能晚于到期日"); }
        }
        tx.execute("UPDATE tasks SET start_date=?,due_date=?,updated_at=?,revision=revision+1 WHERE id=?", params![start_date, due_date, timestamp(), id])?;
        let updated = find_task(&tx, id)?;
        enqueue(&tx, &updated, "update", Some(old.revision))?;
        tx.commit()?;
        Ok(updated)
    }

    pub fn delete_task(&mut self, id: &str) -> Result<()> {
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let old = find_task(&tx, id)?;
        let now = timestamp();
        let mut targets = children_of(&tx, id)?;
        targets.push(old);
        for task in targets {
            tx.execute("UPDATE tasks SET deleted_at=?,updated_at=?,revision=revision+1 WHERE id=?", params![now, now, task.id])?;
            let deleted = fetch_task(&tx, &task.id)?.context("找不到任务")?;
            enqueue(&tx, &deleted, "delete", Some(task.revision))?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Undoes `delete_task`: brings the task back in its original position, along with the subtasks deleted with it.
    pub fn restore_task(&mut self, id: &str) -> Result<Task> {
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let old = fetch_task(&tx, id)?.context("找不到任务")?;
        let Some(stamp) = old.deleted_at.clone() else { bail!("任务没有被删除") };
        if let Some(parent_id) = &old.parent_id { find_task(&tx, parent_id).map_err(|_| anyhow::anyhow!("父任务已删除，无法恢复子任务"))?; }
        let mut stmt = tx.prepare(&format!("SELECT {COLUMNS} FROM tasks WHERE (id=? OR parent_id=?) AND deleted_at=?"))?;
        let targets = stmt.query_map(params![id, id, stamp], task_from_row)?.collect::<rusqlite::Result<Vec<_>>>()?;
        drop(stmt);
        let now = timestamp();
        for task in targets {
            tx.execute("UPDATE tasks SET deleted_at=NULL,updated_at=?,revision=revision+1 WHERE id=?", params![now, task.id])?;
            let restored = find_task(&tx, &task.id)?;
            enqueue(&tx, &restored, "restore", Some(task.revision))?;
        }
        let restored = find_task(&tx, id)?;
        tx.commit()?;
        Ok(restored)
    }

    pub fn list_groups(&self) -> Result<Vec<Group>> { live_groups(&self.conn) }

    pub fn add_group(&mut self, name: &str, color: Option<&str>) -> Result<Group> {
        let name = validated_group_name(name)?;
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if name_taken(&tx, name, None)? { bail!("已经有同名的分组"); }
        let groups = live_groups(&tx)?;
        let color = match color {
            Some(color) if GROUP_COLORS.contains(&color) => color.to_owned(),
            Some(_) => bail!("无效的分组颜色"),
            None => GROUP_COLORS.iter().find(|c| !groups.iter().any(|g| g.color == **c)).unwrap_or(&GROUP_COLORS[groups.len() % GROUP_COLORS.len()]).to_string(),
        };
        let position: i64 = tx.query_row("SELECT COALESCE(MAX(position), -1) + 1 FROM task_groups WHERE deleted_at IS NULL", [], |r| r.get(0))?;
        let now = timestamp();
        let group = Group { id: Uuid::new_v4().to_string(), name: name.to_owned(), color, position };
        tx.execute("INSERT INTO task_groups (id,name,color,position,created_at,updated_at) VALUES (?,?,?,?,?,?)", params![group.id, group.name, group.color, group.position, now, now])?;
        tx.commit()?;
        Ok(group)
    }

    pub fn update_group(&mut self, id: &str, name: Option<&str>, color: Option<&str>) -> Result<Group> {
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let old = live_groups(&tx)?.into_iter().find(|g| g.id == id).context("找不到分组")?;
        let name = match name { Some(name) => validated_group_name(name)?.to_owned(), None => old.name.clone() };
        if name_taken(&tx, &name, Some(id))? { bail!("已经有同名的分组"); }
        let color = match color { Some(color) if GROUP_COLORS.contains(&color) => color.to_owned(), Some(_) => bail!("无效的分组颜色"), None => old.color.clone() };
        tx.execute("UPDATE task_groups SET name=?,color=?,updated_at=? WHERE id=?", params![name, color, timestamp(), id])?;
        tx.commit()?;
        Ok(Group { name, color, ..old })
    }

    pub fn move_group(&mut self, id: &str, direction: i32) -> Result<()> {
        if direction != -1 && direction != 1 { bail!("排序方向无效"); }
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let groups = live_groups(&tx)?;
        let index = groups.iter().position(|g| g.id == id).context("找不到分组")?;
        let other = index as i64 + direction as i64;
        if other >= 0 && (other as usize) < groups.len() {
            let other = &groups[other as usize];
            let now = timestamp();
            tx.execute("UPDATE task_groups SET position=?,updated_at=? WHERE id=?", params![other.position, now, id])?;
            tx.execute("UPDATE task_groups SET position=?,updated_at=? WHERE id=?", params![groups[index].position, now, other.id])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Deletes a group together with its tasks (all stamped alike so `restore_group` can bring them back).
    pub fn delete_group(&mut self, id: &str) -> Result<()> {
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let groups = live_groups(&tx)?;
        if !groups.iter().any(|g| g.id == id) { bail!("找不到分组"); }
        if groups.len() <= 1 { bail!("至少保留一个分组"); }
        let now = timestamp();
        tx.execute("UPDATE task_groups SET deleted_at=?,updated_at=? WHERE id=?", params![now, now, id])?;
        let mut stmt = tx.prepare(&format!("SELECT {COLUMNS} FROM tasks WHERE category=? AND deleted_at IS NULL"))?;
        let tasks = stmt.query_map([id], task_from_row)?.collect::<rusqlite::Result<Vec<_>>>()?;
        drop(stmt);
        for task in tasks {
            tx.execute("UPDATE tasks SET deleted_at=?,updated_at=?,revision=revision+1 WHERE id=?", params![now, now, task.id])?;
            let deleted = fetch_task(&tx, &task.id)?.context("找不到任务")?;
            enqueue(&tx, &deleted, "delete", Some(task.revision))?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn restore_group(&mut self, id: &str) -> Result<Group> {
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let (name, color, position, stamp): (String, String, i64, Option<String>) = tx.query_row("SELECT name,color,position,deleted_at FROM task_groups WHERE id=?", [id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))).optional()?.context("找不到分组")?;
        let Some(stamp) = stamp else { bail!("分组没有被删除") };
        if name_taken(&tx, &name, None)? { bail!("已经有同名的分组，无法恢复"); }
        let now = timestamp();
        tx.execute("UPDATE task_groups SET deleted_at=NULL,updated_at=? WHERE id=?", params![now, id])?;
        let mut stmt = tx.prepare(&format!("SELECT {COLUMNS} FROM tasks WHERE category=? AND deleted_at=?"))?;
        let tasks = stmt.query_map(params![id, stamp], task_from_row)?.collect::<rusqlite::Result<Vec<_>>>()?;
        drop(stmt);
        for task in tasks {
            tx.execute("UPDATE tasks SET deleted_at=NULL,updated_at=?,revision=revision+1 WHERE id=?", params![now, task.id])?;
            let restored = find_task(&tx, &task.id)?;
            enqueue(&tx, &restored, "restore", Some(task.revision))?;
        }
        tx.commit()?;
        Ok(Group { id: id.to_owned(), name, color, position })
    }

    /// Indent (`parent_id = Some`) makes a childless task a subtask of another top-level task;
    /// outdent (`None`) turns a subtask back into a top-level task right after its former parent.
    pub fn reparent_task(&mut self, id: &str, parent_id: Option<&str>) -> Result<Task> {
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let old = find_task(&tx, id)?;
        let now = timestamp();
        match parent_id {
            Some(parent_id) => {
                if parent_id == id { bail!("不能缩进到自己下面"); }
                let parent = find_task(&tx, parent_id)?;
                if parent.parent_id.is_some() { bail!("只支持一级子任务"); }
                if !children_of(&tx, id)?.is_empty() { bail!("有子任务的任务不能再缩进"); }
                if old.parent_id.as_deref() == Some(parent_id) { return Ok(old); }
                let position: i64 = tx.query_row("SELECT COALESCE(MAX(position), -1) + 1 FROM tasks WHERE parent_id=? AND deleted_at IS NULL", [parent_id], |r| r.get(0))?;
                tx.execute("UPDATE tasks SET parent_id=?,category=?,position=?,updated_at=?,revision=revision+1 WHERE id=?", params![parent_id, parent.category, position, now, id])?;
            }
            None => {
                let former = old.parent_id.clone().context("这已经是一级任务")?;
                let parent = find_task(&tx, &former)?;
                let mut stmt = tx.prepare(&format!("SELECT {COLUMNS} FROM tasks WHERE category=? AND parent_id IS NULL AND deleted_at IS NULL AND position>?"))?;
                let shifted = stmt.query_map(params![parent.category, parent.position], task_from_row)?.collect::<rusqlite::Result<Vec<_>>>()?;
                drop(stmt);
                for task in shifted {
                    tx.execute("UPDATE tasks SET position=position+1,updated_at=?,revision=revision+1 WHERE id=?", params![now, task.id])?;
                    let moved = find_task(&tx, &task.id)?;
                    enqueue(&tx, &moved, "reorder", Some(task.revision))?;
                }
                tx.execute("UPDATE tasks SET parent_id=NULL,position=?,updated_at=?,revision=revision+1 WHERE id=?", params![parent.position + 1, now, id])?;
            }
        }
        let updated = find_task(&tx, id)?;
        enqueue(&tx, &updated, "update", Some(old.revision))?;
        tx.commit()?;
        Ok(updated)
    }

    /// Reorders top-level tasks in a status column across groups. Normalization handles tied positions.
    pub fn move_status_task(&mut self, id: &str, direction: i32) -> Result<()> {
        if direction != -1 && direction != 1 { bail!("排序方向无效"); }
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let task = find_task(&tx, id)?;
        if task.parent_id.is_some() { bail!("看板只展示一级任务"); }
        let mut stmt = tx.prepare(&format!("SELECT {COLUMNS} FROM tasks WHERE status=? AND parent_id IS NULL AND deleted_at IS NULL ORDER BY position,id"))?;
        let mut peers = stmt.query_map([task.status.as_str()], task_from_row)?.collect::<rusqlite::Result<Vec<_>>>()?;
        drop(stmt);
        let index = peers.iter().position(|peer| peer.id == id).context("找不到任务")?;
        let other = index as i64 + direction as i64;
        if other >= 0 && other < peers.len() as i64 {
            peers.swap(index, other as usize);
            let now = timestamp();
            for (position, peer) in peers.iter().enumerate() {
                if peer.position == position as i64 { continue; }
                tx.execute("UPDATE tasks SET position=?,updated_at=?,revision=revision+1 WHERE id=?", params![position as i64, now, peer.id])?;
                enqueue(&tx, &find_task(&tx, &peer.id)?, "reorder", Some(peer.revision))?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn move_task(&mut self, id: &str, direction: i32) -> Result<()> {
        if direction != -1 && direction != 1 { bail!("排序方向无效"); }
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let task = find_task(&tx, id)?;
        let comparator = if direction == -1 { "<" } else { ">" };
        let order = if direction == -1 { "DESC" } else { "ASC" };
        let sql = format!("SELECT {COLUMNS} FROM tasks WHERE category=? AND parent_id IS ? AND deleted_at IS NULL AND position {comparator} ? ORDER BY position {order}, id {order} LIMIT 1");
        let other = tx.query_row(&sql, params![task.category, task.parent_id, task.position], task_from_row).optional()?;
        if let Some(other) = other {
            let now = timestamp();
            tx.execute("UPDATE tasks SET position=?,updated_at=?,revision=revision+1 WHERE id=?", params![other.position, now, task.id])?;
            tx.execute("UPDATE tasks SET position=?,updated_at=?,revision=revision+1 WHERE id=?", params![task.position, now, other.id])?;
            let a = find_task(&tx, &task.id)?;
            let b = find_task(&tx, &other.id)?;
            enqueue(&tx, &a, "reorder", Some(task.revision))?;
            enqueue(&tx, &b, "reorder", Some(other.revision))?;
        }
        tx.commit()?;
        Ok(())
    }
}

fn backup_database(conn: &Connection, path: &Path, version: i64) -> Result<()> {
    let directory = path.parent().unwrap_or(Path::new(".")).join("backups");
    std::fs::create_dir_all(&directory).context("无法创建数据库备份目录")?;
    let backup = directory.join(format!("tasks-v{version}-{}.sqlite", Utc::now().format("%Y%m%dT%H%M%S%.9fZ")));
    let destination = backup.to_str().context("数据库备份路径不是有效的 UTF-8")?;
    conn.execute("VACUUM INTO ?", [destination]).context("无法备份任务数据库")?;

    let mut backups = Vec::new();
    for entry in std::fs::read_dir(&directory).context("无法读取数据库备份目录")? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if name.starts_with("tasks-v") && name.ends_with(".sqlite") && entry.file_type()?.is_file() {
            backups.push((entry.metadata()?.modified()?, entry.path()));
        }
    }
    backups.sort();
    let excess = backups.len().saturating_sub(5);
    for (_, backup) in backups.into_iter().take(excess) {
        std::fs::remove_file(backup).context("无法清理旧数据库备份")?;
    }
    Ok(())
}

const COLUMNS: &str = "id,title,category,completed,position,created_at,updated_at,deleted_at,revision,parent_id,due_date,status,start_date";
fn timestamp() -> String { Utc::now().to_rfc3339() }
fn validated_title(title: &str) -> Result<&str> {
    let title = title.trim();
    if title.is_empty() { bail!("任务内容不能为空"); }
    if title.chars().count() > 500 { bail!("任务内容不能超过 500 个字"); }
    Ok(title)
}
/// Accepts a group id or its name and returns the id of a live group.
fn resolve_group(conn: &Connection, key: &str) -> Result<String> {
    conn.query_row("SELECT id FROM task_groups WHERE deleted_at IS NULL AND (id=?1 OR name=?1) ORDER BY id=?1 DESC LIMIT 1", [key], |r| r.get(0)).optional()?.context("无效的任务分类")
}
fn validated_group_name(name: &str) -> Result<&str> {
    let name = name.trim();
    if name.is_empty() { bail!("分组名不能为空"); }
    if name.chars().count() > 20 { bail!("分组名不能超过 20 个字"); }
    Ok(name)
}
fn group_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Group> {
    Ok(Group { id: row.get(0)?, name: row.get(1)?, color: row.get(2)?, position: row.get(3)? })
}
fn live_groups(conn: &Connection) -> Result<Vec<Group>> {
    let mut stmt = conn.prepare("SELECT id,name,color,position FROM task_groups WHERE deleted_at IS NULL ORDER BY position,id")?;
    let rows = stmt.query_map([], group_from_row)?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}
fn name_taken(conn: &Connection, name: &str, except: Option<&str>) -> Result<bool> {
    let count: i64 = conn.query_row("SELECT COUNT(*) FROM task_groups WHERE deleted_at IS NULL AND name=? AND id<>?", params![name, except.unwrap_or("")], |r| r.get(0))?;
    Ok(count > 0)
}
fn task_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Task> {
    Ok(Task { id: row.get(0)?, title: row.get(1)?, category: row.get(2)?, completed: row.get(3)?, position: row.get(4)?, created_at: row.get(5)?, updated_at: row.get(6)?, deleted_at: row.get(7)?, revision: row.get(8)?, parent_id: row.get(9)?, due_date: row.get(10)?, status: match row.get::<_, String>(11)?.as_str() { "done" => TaskStatus::Done, "doing" => TaskStatus::Doing, _ => TaskStatus::Todo }, start_date: row.get(12)? })
}
fn fetch_task(conn: &Connection, id: &str) -> Result<Option<Task>> {
    Ok(conn.query_row(&format!("SELECT {COLUMNS} FROM tasks WHERE id=?"), [id], task_from_row).optional()?)
}
fn find_task(conn: &Connection, id: &str) -> Result<Task> {
    match fetch_task(conn, id)? { Some(task) if task.deleted_at.is_none() => Ok(task), _ => bail!("找不到任务") }
}
fn enqueue(tx: &Transaction<'_>, task: &Task, kind: &str, base: Option<i64>) -> Result<()> {
    tx.execute("INSERT INTO sync_outbox(operation_id,task_id,kind,base_revision,payload,created_at) VALUES (?,?,?,?,?,?)", params![Uuid::new_v4().to_string(), task.id, kind, base, serde_json::to_string(task)?, timestamp()])?;
    Ok(())
}
fn children_of(conn: &Connection, id: &str) -> Result<Vec<Task>> {
    let mut stmt = conn.prepare(&format!("SELECT {COLUMNS} FROM tasks WHERE parent_id=? AND deleted_at IS NULL ORDER BY position,id"))?;
    let rows = stmt.query_map([id], task_from_row)?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}
