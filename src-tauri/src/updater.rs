use crate::settings::SettingsStore;
use serde::Serialize;
use std::{sync::Mutex, time::Duration};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_updater::UpdaterExt;

pub fn config() -> Option<(&'static str, String)> {
    let key = option_env!("DOTIST_UPDATER_PUBKEY")?.trim();
    let repo = option_env!("DOTIST_UPDATE_REPO")?.trim();
    let parts: Vec<_> = repo.split('/').collect();
    if key.is_empty() || parts.len() != 2 || parts.iter().any(|p| p.is_empty() || !p.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))) { return None; }
    Some((key, format!("https://github.com/{repo}/releases/latest/download/latest.json")))
}

#[derive(Clone, Serialize)]
pub struct UpdateResult {
    status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    notes: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}
fn result(status: &'static str) -> UpdateResult { UpdateResult { status, version: None, notes: None, message: None } }
#[derive(Default)]
pub struct Pending(pub Mutex<Option<UpdateResult>>);

#[tauri::command]
pub async fn check_for_update(app: AppHandle) -> UpdateResult {
    if config().is_none() { return result("unconfigured"); }
    match async { app.updater()?.check().await }.await {
        Ok(Some(update)) => UpdateResult { status: "available", version: Some(update.version), notes: update.body, message: None },
        Ok(None) => result("up_to_date"),
        Err(error) => UpdateResult { message: Some(error.to_string()), ..result("error") },
    }
}

#[tauri::command]
pub fn pending_update(app: AppHandle) -> Option<UpdateResult> {
    if config().is_none() { return Some(result("unconfigured")); }
    let pending = app.state::<Pending>().0.lock().ok().and_then(|value| value.clone());
    let skipped = app.state::<SettingsStore>().current.lock().map(|s| s.skipped_update_version.clone()).unwrap_or_default();
    pending.filter(|value| value.version.as_deref() != Some(skipped.as_str()))
}

#[derive(Clone, Serialize)]
struct Progress { downloaded: u64, total: Option<u64> }
#[tauri::command]
pub async fn install_update(app: AppHandle) -> Result<(), String> {
    if config().is_none() { return Err("Updater is not configured".into()); }
    let update = app.updater().map_err(|e| e.to_string())?.check().await.map_err(|e| e.to_string())?.ok_or("No update available")?;
    let mut downloaded = 0u64;
    update.download_and_install(|chunk, total| {
        downloaded += chunk as u64;
        let _ = app.emit("update-progress", Progress { downloaded, total });
    }, || {}).await.map_err(|e| e.to_string())?;
    app.restart();
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(30));
        loop {
            let enabled = app.state::<SettingsStore>().current.lock().map(|s| s.auto_check_updates).unwrap_or(false);
            if enabled && config().is_some() {
                let checked = tauri::async_runtime::block_on(check_for_update(app.clone()));
                if checked.status == "available" {
                    let should_emit = app.state::<SettingsStore>().current.lock().map(|s| s.auto_check_updates && checked.version.as_deref() != Some(&s.skipped_update_version)).unwrap_or(false);
                    if should_emit {
                        if let Ok(mut pending) = app.state::<Pending>().0.lock() { *pending = Some(checked.clone()); }
                        let _ = app.emit("update-available", checked);
                    }
                }
            }
            std::thread::sleep(Duration::from_secs(24 * 60 * 60));
        }
    });
}

#[cfg(test)]
mod tests {
    #[test]
    fn plugin_config_requires_a_public_key() {
        assert!(serde_json::from_value::<tauri_plugin_updater::Config>(serde_json::json!({})).is_err());
        assert!(serde_json::from_value::<tauri_plugin_updater::Config>(serde_json::json!({
            "pubkey": "test", "endpoints": ["https://github.com/owner/repo/releases/latest/download/latest.json"]
        })).is_ok());
    }

    #[test]
    fn old_settings_get_update_defaults() {
        let settings: crate::settings::Settings = serde_json::from_str("{}").unwrap();
        assert!(settings.auto_check_updates);
        assert!(settings.skipped_update_version.is_empty());
    }
}
