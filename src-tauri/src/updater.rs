use crate::settings::{Settings, SettingsStore};
use serde::Serialize;
use std::{sync::{atomic::{AtomicBool, Ordering}, Mutex}, time::{Duration, Instant}};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_updater::{Update, UpdaterExt};

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
pub struct Pending {
    result: Mutex<Option<UpdateResult>>,
    installing: AtomicBool,
    downloaded: Mutex<Option<(Update, Vec<u8>)>>,
}

#[tauri::command]
pub async fn check_for_update(app: AppHandle) -> UpdateResult {
    match async { app.updater()?.check().await }.await {
        Ok(Some(update)) => UpdateResult { status: "available", version: Some(update.version), notes: update.body, message: None },
        Ok(None) => result("up_to_date"),
        Err(error) => UpdateResult { message: Some(error.to_string()), ..result("error") },
    }
}

#[tauri::command]
pub fn pending_update(app: AppHandle) -> Option<UpdateResult> {
    let pending = app.state::<Pending>().result.lock().ok().and_then(|value| value.clone());
    let skipped = app.state::<SettingsStore>().current.lock().map(|s| s.skipped_update_version.clone()).unwrap_or_default();
    pending.filter(|value| value.version.as_deref() != Some(skipped.as_str()))
}

#[derive(Clone, Serialize)]
struct Progress { downloaded: u64, total: Option<u64> }

fn automatic_install_allowed(settings: &Settings, version: &str) -> bool {
    settings.auto_check_updates && settings.auto_install_updates && settings.skipped_update_version != version
}

async fn install(app: AppHandle, automatic: bool) -> Result<(), String> {
    if app.state::<Pending>().installing.swap(true, Ordering::SeqCst) { return Err("Update installation is already in progress".into()); }
    let result = download(&app).await.and_then(|(update, bytes)| {
        if automatic {
            if app.state::<SettingsStore>().current.lock().map(|s| automatic_install_allowed(&s, &update.version)).unwrap_or(false) {
                let ready = UpdateResult { status: "downloaded", version: Some(update.version.clone()), notes: update.body.clone(), message: None };
                *app.state::<Pending>().downloaded.lock().map_err(|e| e.to_string())? = Some((update, bytes));
                *app.state::<Pending>().result.lock().map_err(|e| e.to_string())? = Some(ready.clone());
                let _ = app.emit("update-available", ready);
            }
            return Ok(());
        }
        update.install(bytes).map_err(|e| e.to_string())?;
        if let Err(error) = app.state::<SettingsStore>().set_update_error(String::new()) { eprintln!("Could not clear update error: {error}"); }
        app.restart();
    });
    app.state::<Pending>().installing.store(false, Ordering::SeqCst);
    result
}

async fn download(app: &AppHandle) -> Result<(Update, Vec<u8>), String> {
    let update = app.updater().map_err(|e| e.to_string())?.check().await.map_err(|e| e.to_string())?.ok_or("No update available")?;
    let mut downloaded = 0u64;
    let bytes = update.download(|chunk, total| {
        downloaded += chunk as u64;
        let _ = app.emit("update-progress", Progress { downloaded, total });
    }, || {}).await.map_err(|e| e.to_string())?;
    Ok((update, bytes))
}

#[tauri::command]
pub async fn install_update(app: AppHandle) -> Result<(), String> { install(app, false).await }

pub fn install_on_exit(app: &AppHandle) {
    if app.state::<Pending>().installing.swap(true, Ordering::SeqCst) { return; }
    let downloaded = app.state::<Pending>().downloaded.lock().ok().and_then(|mut pending| pending.take());
    if let Some((update, bytes)) = downloaded {
        let allowed = app.state::<SettingsStore>().current.lock().map(|s| automatic_install_allowed(&s, &update.version)).unwrap_or(false);
        if allowed {
            let error = update.install(bytes).err().map(|error| error.to_string()).unwrap_or_default();
            if let Err(save_error) = app.state::<SettingsStore>().set_update_error(error) { eprintln!("Could not save update result: {save_error}"); }
        }
    }
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(30));
        let mut last_check: Option<Instant> = None;
        let mut was_enabled = false;
        let mut was_automatic = false;
        loop {
            let (enabled, automatic) = app.state::<SettingsStore>().current.lock().map(|s| (s.auto_check_updates, s.auto_install_updates)).unwrap_or((false, false));
            if enabled && (!was_enabled || (automatic && !was_automatic) || last_check.map_or(true, |last| last.elapsed() >= Duration::from_secs(24 * 60 * 60))) {
                last_check = Some(Instant::now());
                let checked = tauri::async_runtime::block_on(check_for_update(app.clone()));
                if checked.status == "available" {
                    let should_emit = app.state::<SettingsStore>().current.lock().map(|s| s.auto_check_updates && checked.version.as_deref() != Some(&s.skipped_update_version)).unwrap_or(false);
                    if should_emit {
                        if let Ok(mut pending) = app.state::<Pending>().result.lock() { *pending = Some(checked.clone()); }
                        let _ = app.emit("update-available", checked.clone());
                        if automatic {
                            if let Err(error) = tauri::async_runtime::block_on(install(app.clone(), true)) {
                                let failed = UpdateResult { message: Some(error), ..checked };
                                if let Ok(mut pending) = app.state::<Pending>().result.lock() { *pending = Some(failed.clone()); }
                                let _ = app.emit("update-available", failed);
                            }
                        }
                    }
                }
            }
            was_enabled = enabled;
            was_automatic = automatic;
            std::thread::sleep(Duration::from_secs(60));
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
        assert!(!settings.auto_install_updates);
        assert!(settings.skipped_update_version.is_empty());
    }

    #[test]
    fn automatic_install_respects_settings_and_skipped_versions() {
        let mut settings = crate::settings::Settings::default();
        assert!(!super::automatic_install_allowed(&settings, "0.1.2"));
        settings.auto_install_updates = true;
        assert!(super::automatic_install_allowed(&settings, "0.1.2"));
        settings.skipped_update_version = "0.1.2".into();
        assert!(!super::automatic_install_allowed(&settings, "0.1.2"));
        assert!(super::automatic_install_allowed(&settings, "0.1.3"));
        settings.auto_check_updates = false;
        assert!(!super::automatic_install_allowed(&settings, "0.1.3"));
    }
}
