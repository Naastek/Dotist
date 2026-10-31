use anyhow::{anyhow, Context, Result};
use dotist_core::{database_path, Store, TaskStatus};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{ffi::{CStr, CString}, os::raw::c_char, path::PathBuf, ptr, sync::Mutex};

#[path = "../../../src-tauri/src/settings.rs"]
mod settings;
mod tags;

pub struct NativeStore {
    tasks: Mutex<Store>,
    settings: settings::SettingsStore,
    database_path: PathBuf,
}

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
enum Request {
    GetSettings,
    GetDatabasePath,
    GetLaunchAtLogin { app_name: String, executable: String },
    SetLaunchAtLogin { app_name: String, executable: String, enabled: bool },
    UpdateSettings { patch: SettingsPatch },
    ListTasks,
    ListGroups,
    DescribeTags,
    FilterByTag { tag: String },
    Retag { tag: String, replacement: Option<String> },
    AddTask { title: String, category: String, parent_id: Option<String>, due_date: Option<String> },
    PatchTask { id: String, title: Option<String>, category: Option<String>, completed: Option<bool>, status: Option<TaskStatus> },
    DeleteTask { id: String },
    RestoreTask { id: String },
    SetDueDate { id: String, due_date: Option<String> },
    SetStartDate { id: String, start_date: Option<String> },
    SetDateRange { id: String, start_date: Option<String>, due_date: Option<String> },
    ReparentTask { id: String, parent_id: Option<String> },
    ReorderTask { id: String, target_id: String, after: bool, all_tasks: bool },
    MoveTask { id: String, direction: i32 },
    MoveStatusTask { id: String, direction: i32 },
    AddGroup { name: String, color: Option<String> },
    UpdateGroup { id: String, name: Option<String>, color: Option<String> },
    MoveGroup { id: String, direction: i32 },
    DeleteGroup { id: String },
    RestoreGroup { id: String },
}

#[derive(Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
struct SettingsPatch {
    theme: Option<String>,
    language: Option<String>,
    opacity: Option<u8>,
    frost: Option<u8>,
    always_on_top: Option<bool>,
    hover_expand: Option<bool>,
    idle_fade: Option<bool>,
    locked: Option<bool>,
    window_width: Option<u32>,
    window_height: Option<u32>,
    idle_opacity: Option<u8>,
    idle_delay_secs: Option<u8>,
    idle_fade_secs: Option<u8>,
    group_colors: Option<String>,
    filters: Option<Vec<String>>,
    default_filter: Option<String>,
    auto_collapse: Option<bool>,
    auto_collapse_secs: Option<u16>,
    show_dock: Option<bool>,
    show_menubar: Option<bool>,
    tray_mode: Option<String>,
    tray_rotate_secs: Option<u16>,
    tray_left_click: Option<String>,
    tray_right_click: Option<String>,
    tray_filter: Option<String>,
    tray_group: Option<String>,
    toggle_shortcut: Option<String>,
    quick_add_shortcut: Option<String>,
    settings_shortcut: Option<String>,
    views_shortcut: Option<String>,
    auto_check_updates: Option<bool>,
    auto_install_updates: Option<bool>,
    skipped_update_version: Option<String>,
    last_update_error: Option<String>,
}

fn update_settings(store: &settings::SettingsStore, patch: SettingsPatch) -> Result<settings::Settings> {
    let mut current = store.current.lock().map_err(|_| anyhow!("设置不可用"))?;
    let mut next = current.clone();
    if let Some(value) = patch.theme {
        if !["system", "light", "dark"].contains(&value.as_str()) { return Err(anyhow!("无效的主题")); }
        next.theme = value;
    }
    if let Some(value) = patch.language {
        if !["system", "zh-CN", "zh-TW", "en", "ja"].contains(&value.as_str()) { return Err(anyhow!("无效的语言")); }
        next.language = value;
    }
    if let Some(value) = patch.opacity { next.opacity = value; }
    if let Some(value) = patch.frost { next.frost = value; }
    if let Some(value) = patch.always_on_top { next.always_on_top = value; }
    if let Some(value) = patch.hover_expand { next.hover_expand = value; }
    if let Some(value) = patch.idle_fade { next.idle_fade = value; }
    if let Some(value) = patch.locked { next.locked = value; }
    if let Some(value) = patch.window_width { next.window_width = value; }
    if let Some(value) = patch.window_height { next.window_height = value; }
    if let Some(value) = patch.idle_opacity { next.idle_opacity = value; }
    if let Some(value) = patch.idle_delay_secs { next.idle_delay_secs = value; }
    if let Some(value) = patch.idle_fade_secs { next.idle_fade_secs = value; }
    if let Some(value) = patch.group_colors {
        if !["dot", "text", "none"].contains(&value.as_str()) { return Err(anyhow!("无效的分组颜色样式")); }
        next.group_colors = value;
    }
    if let Some(value) = patch.filters { next.filters = settings::clean_filters(&value); }
    if let Some(value) = patch.default_filter {
        if !settings::FILTER_IDS.contains(&value.as_str()) { return Err(anyhow!("无效的筛选器")); }
        next.default_filter = value;
    }
    if let Some(value) = patch.auto_collapse { next.auto_collapse = value; }
    if let Some(value) = patch.auto_collapse_secs { next.auto_collapse_secs = value.clamp(1, 600); }
    if let Some(value) = patch.show_dock { next.show_dock = value; }
    if let Some(value) = patch.show_menubar { next.show_menubar = value; }
    if let Some(value) = patch.tray_mode {
        if !settings::TRAY_MODES.contains(&value.as_str()) { return Err(anyhow!("无效的菜单栏显示方式")); }
        next.tray_mode = value;
    }
    if let Some(value) = patch.tray_rotate_secs { next.tray_rotate_secs = value; }
    if let Some(value) = patch.tray_left_click {
        if !settings::TRAY_ACTIONS.contains(&value.as_str()) { return Err(anyhow!("无效的点击操作")); }
        next.tray_left_click = value;
    }
    if let Some(value) = patch.tray_right_click {
        if !settings::TRAY_ACTIONS.contains(&value.as_str()) { return Err(anyhow!("无效的点击操作")); }
        next.tray_right_click = value;
    }
    if let Some(value) = patch.tray_filter {
        if !settings::FILTER_IDS.contains(&value.as_str()) { return Err(anyhow!("无效的筛选器")); }
        next.tray_filter = value;
    }
    if let Some(value) = patch.tray_group { next.tray_group = value; }
    if let Some(value) = patch.toggle_shortcut { next.toggle_shortcut = value; }
    if let Some(value) = patch.quick_add_shortcut { next.quick_add_shortcut = value; }
    if let Some(value) = patch.settings_shortcut { next.settings_shortcut = value; }
    if let Some(value) = patch.views_shortcut { next.views_shortcut = value; }
    if let Some(value) = patch.auto_check_updates { next.auto_check_updates = value; if !value { next.auto_install_updates = false; } }
    if let Some(value) = patch.auto_install_updates { next.auto_install_updates = value; if value { next.auto_check_updates = true; } }
    if let Some(value) = patch.skipped_update_version { next.skipped_update_version = value; }
    if let Some(value) = patch.last_update_error { next.last_update_error = value; }
    let shortcuts = [&next.toggle_shortcut, &next.quick_add_shortcut, &next.settings_shortcut, &next.views_shortcut];
    if shortcuts.iter().enumerate().any(|(index, value)| !value.is_empty() && shortcuts.iter().skip(index + 1).any(|other| value == other)) {
        return Err(anyhow!("不同的动作不能使用同一个快捷键"));
    }
    next.sanitize();
    store.save(&next).map_err(|error| anyhow!(error))?;
    *current = next.clone();
    Ok(next)
}

fn execute(store: &mut Store, settings: &settings::SettingsStore, path: &std::path::Path, request: Request) -> Result<Value> {
    match request {
        Request::GetSettings => Ok(serde_json::to_value(settings.current.lock().map_err(|_| anyhow!("设置不可用"))?.clone())?),
        Request::GetDatabasePath => Ok(serde_json::to_value(path.to_string_lossy().as_ref())?),
        Request::GetLaunchAtLogin { app_name, executable } => {
            let manager = auto_launch::AutoLaunchBuilder::new().set_app_name(&app_name).set_app_path(&executable).build()?;
            Ok(json!(manager.is_enabled()?))
        }
        Request::SetLaunchAtLogin { app_name, executable, enabled } => {
            let manager = auto_launch::AutoLaunchBuilder::new().set_app_name(&app_name).set_app_path(&executable).build()?;
            if enabled { manager.enable()?; } else { manager.disable()?; }
            Ok(json!(manager.is_enabled()?))
        }
        Request::UpdateSettings { patch } => Ok(serde_json::to_value(update_settings(settings, patch)?)?),
        Request::ListTasks => Ok(serde_json::to_value(store.list_tasks()?)?),
        Request::ListGroups => Ok(serde_json::to_value(store.list_groups()?)?),
        Request::DescribeTags => Ok(serde_json::to_value(tags::describe(&store.list_tasks()?))?),
        Request::FilterByTag { tag } => Ok(serde_json::to_value(tags::filter(&store.list_tasks()?, &tag))?),
        Request::Retag { tag, replacement } => {
            let replacement = replacement.map(|value| value.trim().trim_start_matches('#').chars().filter(|c| !c.is_whitespace()).take(24).collect::<String>());
            if replacement.as_deref() == Some("") || replacement.as_deref() == Some(tag.as_str()) { return Ok(Value::Null); }
            for task in store.list_tasks()? {
                let title = tags::rewrite(&task.title, &tag, replacement.as_deref());
                if title != task.title { store.patch_task(&task.id, Some(&title), None, None)?; }
            }
            Ok(Value::Null)
        }
        Request::AddTask { title, category, parent_id, due_date } => {
            let task = store.add_task_in(&title, &category, parent_id.as_deref())?;
            let task = match due_date { Some(due) => store.set_due_date(&task.id, Some(&due))?, None => task };
            Ok(serde_json::to_value(task)?)
        }
        Request::PatchTask { id, title, category, completed, status } => Ok(serde_json::to_value(store.patch_task_with_status(&id, title.as_deref(), category.as_deref(), completed, status)?)?),
        Request::DeleteTask { id } => { store.delete_task(&id)?; Ok(Value::Null) }
        Request::RestoreTask { id } => Ok(serde_json::to_value(store.restore_task(&id)?)?),
        Request::SetDueDate { id, due_date } => Ok(serde_json::to_value(store.set_due_date(&id, due_date.as_deref())?)?),
        Request::SetStartDate { id, start_date } => Ok(serde_json::to_value(store.set_start_date(&id, start_date.as_deref())?)?),
        Request::SetDateRange { id, start_date, due_date } => Ok(serde_json::to_value(store.set_date_range(&id, start_date.as_deref(), due_date.as_deref())?)?),
        Request::ReparentTask { id, parent_id } => Ok(serde_json::to_value(store.reparent_task(&id, parent_id.as_deref())?)?),
        Request::ReorderTask { id, target_id, after, all_tasks } => { store.reorder_task(&id, &target_id, after, all_tasks)?; Ok(Value::Null) }
        Request::MoveTask { id, direction } => { store.move_task(&id, direction)?; Ok(Value::Null) }
        Request::MoveStatusTask { id, direction } => { store.move_status_task(&id, direction)?; Ok(Value::Null) }
        Request::AddGroup { name, color } => Ok(serde_json::to_value(store.add_group(&name, color.as_deref())?)?),
        Request::UpdateGroup { id, name, color } => Ok(serde_json::to_value(store.update_group(&id, name.as_deref(), color.as_deref())?)?),
        Request::MoveGroup { id, direction } => { store.move_group(&id, direction)?; Ok(Value::Null) }
        Request::DeleteGroup { id } => { store.delete_group(&id)?; Ok(Value::Null) }
        Request::RestoreGroup { id } => Ok(serde_json::to_value(store.restore_group(&id)?)?),
    }
}

fn output(result: Result<Value>) -> *mut c_char {
    let value = match result { Ok(value) => json!({"ok": true, "value": value}), Err(error) => json!({"ok": false, "error": error.to_string()}) };
    CString::new(value.to_string()).expect("JSON escapes embedded NUL bytes").into_raw()
}

/// Opens the same SQLite database as the existing UI and MCP. A null path selects `database_path()`.
/// On failure, `error_out` receives a string that must be released with `dotist_native_string_free`.
#[no_mangle]
pub unsafe extern "C" fn dotist_native_open(path: *const c_char, error_out: *mut *mut c_char) -> *mut NativeStore {
    let result = (|| -> Result<NativeStore> {
        let path = if path.is_null() { database_path()? } else { PathBuf::from(CStr::from_ptr(path).to_str().context("数据库路径不是有效 UTF-8")?) };
        Ok(NativeStore {
            tasks: Mutex::new(Store::open(&path)?),
            settings: settings::SettingsStore::load(path.with_file_name("settings.json")),
            database_path: path,
        })
    })();
    match result {
        Ok(store) => Box::into_raw(Box::new(store)),
        Err(error) => {
            if !error_out.is_null() { *error_out = output(Err(error)); }
            ptr::null_mut()
        }
    }
}

/// Executes one typed JSON request. The returned JSON string belongs to the caller.
#[no_mangle]
pub unsafe extern "C" fn dotist_native_call(store: *mut NativeStore, request: *const c_char) -> *mut c_char {
    output((|| -> Result<Value> {
        let store = store.as_ref().context("任务存储尚未打开")?;
        if request.is_null() { return Err(anyhow!("请求不能为空")); }
        let request: Request = serde_json::from_str(CStr::from_ptr(request).to_str().context("请求不是有效 UTF-8")?)?;
        let mut tasks = store.tasks.lock().map_err(|_| anyhow!("任务存储不可用"))?;
        execute(&mut tasks, &store.settings, &store.database_path, request)
    })())
}

#[no_mangle]
pub unsafe extern "C" fn dotist_native_string_free(value: *mut c_char) {
    if !value.is_null() { drop(CString::from_raw(value)); }
}

#[no_mangle]
pub unsafe extern "C" fn dotist_native_close(store: *mut NativeStore) {
    if !store.is_null() { drop(Box::from_raw(store)); }
}
