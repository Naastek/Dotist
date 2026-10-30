use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::Mutex};

pub const TRAY_MODES: [&str; 5] = ["icon", "count", "next", "next_date", "rotate"];
pub const TRAY_ACTIONS: [&str; 7] = ["toggle", "bubble", "quick", "settings", "show", "menu", "none"];
pub const FILTER_IDS: [&str; 9] = ["today", "all", "tomorrow", "week", "nextweek", "next7", "overdue", "undated", "done"];

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    /// "system" | "light" | "dark"
    pub theme: String,
    /// "system" | "zh-CN" | "zh-TW" | "en" | "ja"
    pub language: String,
    /// Tint strength over the native glass, 4 (most see-through) to 95 (nearly solid).
    pub opacity: u8,
    /// Frosted haze and grain over the glass, 0 to 100. The system blur underneath always stays on.
    pub frost: u8,
    /// Global shortcut that shows / collapses the window; empty = disabled.
    pub toggle_shortcut: String,
    /// Global shortcut that shows the window and focuses the new-task field; empty = disabled.
    pub quick_add_shortcut: String,
    /// Global shortcut that opens the settings window; empty = disabled.
    pub settings_shortcut: String,
    pub views_shortcut: String,
    /// Deprecated: replaced by `tray_mode`; read once to migrate older files.
    pub show_tray_count: bool,
    /// What the menu bar item shows next to its icon: icon | count | next | next_date | rotate.
    pub tray_mode: String,
    /// Seconds between items when `tray_mode` is rotate.
    pub tray_rotate_secs: u16,
    /// What a left / right click on the menu bar item does: toggle | bubble | quick | settings | show | menu | none.
    pub tray_left_click: String,
    pub tray_right_click: String,
    pub always_on_top: bool,
    /// Hovering the floating bubble widens it into a capsule showing the next task.
    pub hover_expand: bool,
    /// Where Dotist shows up as an app: the Dock and/or the menu bar. Both may be off (shortcuts and the bubble still work).
    pub show_dock: bool,
    pub show_menubar: bool,
    /// Fade the window back when it is not in use (pointer away, not focused), so what is behind it stays visible.
    pub idle_fade: bool,
    /// Keeps the window as it is: no automatic collapse into the bubble and no idle fade.
    pub locked: bool,
    /// The window size the user dragged it to (logical px); 0 means the default size.
    pub window_width: u32,
    pub window_height: u32,
    /// Opacity of the window while faded, in percent.
    pub idle_opacity: u8,
    /// Seconds without the pointer or focus before the window starts to fade.
    pub idle_delay_secs: u8,
    /// Seconds the fade itself takes.
    pub idle_fade_secs: u8,
    /// Which date perspective and group the menu bar text is about (a header filter id, a group id or "all").
    pub tray_filter: String,
    pub tray_group: String,
    /// How a group's colour shows: dot (a small dot, neutral text), text (coloured name), none.
    pub group_colors: String,
    /// Header filters that are shown, in order (ids: today, all, tomorrow, week, nextweek, next7, overdue, undated, done).
    pub filters: Vec<String>,
    /// The filter opened at launch.
    pub default_filter: String,
    /// Collapse into the bubble after the window sat expanded with the pointer away and no activity.
    pub auto_collapse: bool,
    pub auto_collapse_secs: u16,
    pub auto_check_updates: bool,
    pub auto_install_updates: bool,
    pub skipped_update_version: String,
    pub last_update_error: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self { theme: "system".into(), language: "system".into(), opacity: 56, frost: 35, toggle_shortcut: "CommandOrControl+Alt+D".into(), quick_add_shortcut: "CommandOrControl+Alt+N".into(), settings_shortcut: "CommandOrControl+Alt+Comma".into(), views_shortcut: String::new(), show_tray_count: false, tray_mode: "icon".into(), tray_rotate_secs: 4, tray_left_click: "toggle".into(), tray_right_click: "menu".into(), always_on_top: true, hover_expand: true, show_dock: true, show_menubar: true, idle_fade: true, locked: false, window_width: 0, window_height: 0, idle_opacity: 55, idle_delay_secs: 5, idle_fade_secs: 2, tray_filter: "all".into(), tray_group: "all".into(), group_colors: "dot".into(), filters: FILTER_IDS.iter().map(|id| id.to_string()).collect(), default_filter: "all".into(), auto_collapse: true, auto_collapse_secs: 20, auto_check_updates: true, auto_install_updates: false, skipped_update_version: String::new(), last_update_error: String::new() }
    }
}

/// Keeps known filter ids once each, in the given order; an empty list falls back to the full set.
pub fn clean_filters(filters: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for id in filters { if FILTER_IDS.contains(&id.as_str()) && !out.contains(id) { out.push(id.clone()); } }
    if out.is_empty() { FILTER_IDS.iter().map(|id| id.to_string()).collect() } else { out }
}

impl Settings {
    /// Brings values saved by older versions (which allowed a fully clear window) back into the supported range.
    pub fn sanitize(&mut self) {
        self.opacity = self.opacity.clamp(4, 95);
        self.frost = self.frost.min(100);
        self.idle_opacity = self.idle_opacity.clamp(20, 95);
        if self.window_width == 0 || self.window_height == 0 { self.window_width = 0; self.window_height = 0; }
        else { self.window_width = self.window_width.clamp(320, 4000); self.window_height = self.window_height.clamp(440, 4000); }
        self.idle_delay_secs = self.idle_delay_secs.clamp(1, 60);
        self.idle_fade_secs = self.idle_fade_secs.clamp(1, 10);
        if !FILTER_IDS.contains(&self.tray_filter.as_str()) { self.tray_filter = "all".into(); }
        self.filters = clean_filters(&self.filters);
        if !(["dot", "text", "none"].contains(&self.group_colors.as_str())) { self.group_colors = "dot".into(); }
        if self.show_tray_count { if self.tray_mode == "icon" { self.tray_mode = "count".into(); } self.show_tray_count = false; }
        if !TRAY_MODES.contains(&self.tray_mode.as_str()) { self.tray_mode = "icon".into(); }
        self.tray_rotate_secs = self.tray_rotate_secs.clamp(2, 60);
        if !TRAY_ACTIONS.contains(&self.tray_left_click.as_str()) { self.tray_left_click = "toggle".into(); }
        if !TRAY_ACTIONS.contains(&self.tray_right_click.as_str()) { self.tray_right_click = "menu".into(); }
        if !FILTER_IDS.contains(&self.default_filter.as_str()) { self.default_filter = "all".into(); }
    }
}

/// Preferences live in their own JSON file next to the database, never in the task database.
pub struct SettingsStore { path: PathBuf, pub current: Mutex<Settings> }

impl SettingsStore {
    pub fn load(path: PathBuf) -> Self {
        let mut current: Settings = std::fs::read_to_string(&path).ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default();
        current.sanitize();
        Self { path, current: Mutex::new(current) }
    }

    pub fn save(&self, settings: &Settings) -> Result<(), String> {
        if let Some(parent) = self.path.parent() { std::fs::create_dir_all(parent).map_err(|e| e.to_string())?; }
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(settings).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, &self.path).map_err(|e| e.to_string())
    }

    pub fn set_update_error(&self, error: String) -> Result<(), String> {
        let mut current = self.current.lock().map_err(|e| e.to_string())?;
        let mut next = current.clone();
        next.last_update_error = error;
        self.save(&next)?;
        *current = next;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_or_partial_files_fall_back_to_defaults() {
        let dir = std::env::temp_dir().join(format!("dotist-settings-{}", std::process::id()));
        let path = dir.join("settings.json");
        assert_eq!(*SettingsStore::load(path.clone()).current.lock().unwrap(), Settings::default());
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(&path, r#"{"theme":"dark","language":"ja","toggle_shortcut":"Control+Alt+K","filters":["today","done"]}"#).unwrap();
        let loaded = SettingsStore::load(path.clone());
        assert_eq!(loaded.current.lock().unwrap().theme, "dark");
        assert!(loaded.current.lock().unwrap().always_on_top);
        assert_eq!(loaded.current.lock().unwrap().views_shortcut, "");
        assert_eq!(loaded.current.lock().unwrap().language, "ja");
        assert_eq!(loaded.current.lock().unwrap().toggle_shortcut, "Control+Alt+K");
        assert_eq!(loaded.current.lock().unwrap().filters, vec!["today", "done"]);
        let prior = loaded.current.lock().unwrap().clone();
        loaded.save(&prior).unwrap();
        assert_eq!(*SettingsStore::load(path.clone()).current.lock().unwrap(), prior);
        std::fs::write(&path, "not json").unwrap();
        assert_eq!(*SettingsStore::load(path).current.lock().unwrap(), Settings::default());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn values_saved_by_older_versions_are_brought_into_range() {
        let dir = std::env::temp_dir().join(format!("dotist-settings-old-{}", std::process::id()));
        let path = dir.join("settings.json");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(&path, r#"{"opacity":0,"frost":250}"#).unwrap();
        let loaded = SettingsStore::load(path);
        let current = loaded.current.lock().unwrap();
        assert_eq!((current.opacity, current.frost), (4, 100));
        drop(current);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn filters_are_cleaned_and_default_to_all_of_them() {
        assert_eq!(clean_filters(&["done".into(), "bogus".into(), "today".into(), "done".into()]), vec!["done".to_string(), "today".to_string()]);
        assert_eq!(clean_filters(&[]).len(), FILTER_IDS.len());
        assert_eq!(Settings::default().filters.len(), FILTER_IDS.len());
        assert!(Settings::default().idle_fade);
        let mut sized = Settings { window_width: 100, window_height: 99999, ..Settings::default() };
        sized.sanitize();
        assert_eq!((sized.window_width, sized.window_height), (320, 4000));
        let mut half = Settings { window_width: 500, window_height: 0, ..Settings::default() };
        half.sanitize();
        assert_eq!((half.window_width, half.window_height), (0, 0));
        let mut faded = Settings { idle_opacity: 3, ..Settings::default() };
        faded.sanitize();
        assert_eq!(faded.idle_opacity, 20);
        assert_eq!((Settings::default().idle_delay_secs, Settings::default().idle_fade_secs), (5, 2));
        let mut odd = Settings { idle_delay_secs: 0, idle_fade_secs: 99, tray_filter: "nope".into(), ..Settings::default() };
        odd.sanitize();
        assert_eq!((odd.idle_delay_secs, odd.idle_fade_secs, odd.tray_filter.as_str()), (1, 10, "all"));
    }

    #[test]
    fn tray_settings_are_migrated_and_kept_consistent() {
        let mut old = Settings { show_tray_count: true, ..Settings::default() };
        old.sanitize();
        assert_eq!((old.tray_mode.as_str(), old.show_tray_count), ("count", false));
        let mut odd = Settings { tray_mode: "bogus".into(), tray_rotate_secs: 0, tray_left_click: "menu".into(), tray_right_click: "quick".into(), ..Settings::default() };
        odd.sanitize();
        assert_eq!((odd.tray_mode.as_str(), odd.tray_rotate_secs), ("icon", 2));
        // Left and right are independent: choosing the menu for one never changes the other.
        assert_eq!((odd.tray_left_click.as_str(), odd.tray_right_click.as_str()), ("menu", "quick"));
        assert_eq!(Settings::default().tray_left_click, "toggle");
    }

    #[test]
    fn save_round_trips() {
        let dir = std::env::temp_dir().join(format!("dotist-settings-rt-{}", std::process::id()));
        let path = dir.join("settings.json");
        let store = SettingsStore::load(path.clone());
        let mut next = Settings::default();
        next.theme = "light".into();
        next.toggle_shortcut = String::new();
        store.save(&next).unwrap();
        assert_eq!(*SettingsStore::load(path).current.lock().unwrap(), next);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn automatic_update_errors_survive_a_restart_and_can_be_cleared() {
        let dir = std::env::temp_dir().join(format!("dotist-settings-update-error-{}", std::process::id()));
        let path = dir.join("settings.json");
        let store = SettingsStore::load(path.clone());
        store.set_update_error("disk full".into()).unwrap();
        let reloaded = SettingsStore::load(path.clone());
        assert_eq!(reloaded.current.lock().unwrap().last_update_error, "disk full");
        reloaded.set_update_error(String::new()).unwrap();
        assert!(SettingsStore::load(path).current.lock().unwrap().last_update_error.is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
