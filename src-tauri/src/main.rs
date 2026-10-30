#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod settings;
mod updater;
use dotist_core::{database_path, Group, Store, Task, TaskStatus};
use serde::{Deserialize, Serialize};
use settings::{clean_filters, Settings, SettingsStore, FILTER_IDS, TRAY_ACTIONS, TRAY_MODES};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt as _};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};
use std::sync::{atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering}, Mutex};
use tauri::{
    WebviewUrl, WebviewWindowBuilder, TitleBarStyle,
    image::Image,
    menu::{Menu, MenuBuilder, MenuItem, PredefinedMenuItem, SubmenuBuilder},
    window::{Effect, EffectState, EffectsBuilder},
    tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, PhysicalSize, State, Theme, WebviewWindow, WindowEvent, Wry,
};

type SharedStore = Mutex<Store>;

const BUBBLE: f64 = 48.0;
/// The vibrancy mask is a stretchable image whose caps must fit inside the window, so a 48pt bubble takes a radius just under half.
const BUBBLE_RADIUS: f64 = BUBBLE / 2.0 - 1.0;
const CAPSULE_MIN: f64 = 120.0;
const MIN_WIDTH: f64 = 320.0;
const MIN_HEIGHT: f64 = 440.0;
const WINDOW_RADIUS: f64 = 16.0;

/// Strength of the NSVisualEffectView (see `blur_alpha_for`).
static BLUR_ALPHA_BITS: AtomicU64 = AtomicU64::new(0x3FF0000000000000); // 1.0


/// The system blur stays at full strength: a partly transparent blur layer lets the sharp desktop show through,
/// which reads as harsh, ghosted glass. Frost and transparency are shaped by the tint, haze and grain instead.
fn blur_alpha_for(_frost: u8) -> f64 { 1.0 }

#[cfg(target_os = "macos")]
fn apply_blur_alpha(window: &WebviewWindow) {
    let alpha = f64::from_bits(BLUR_ALPHA_BITS.load(Ordering::SeqCst));
    let handle = window.clone();
    let _ = window.run_on_main_thread(move || {
        use objc2::{class, msg_send, runtime::{AnyObject, Bool}};
        let Ok(pointer) = handle.ns_window() else { return };
        // SAFETY: the pointer is the window's NSWindow, and this runs on the main thread. Only standard
        // NSView / NSArray selectors are sent, to the effect views the window-vibrancy layer added.
        unsafe {
            let ns_window = pointer as *mut AnyObject;
            let content: *mut AnyObject = msg_send![ns_window, contentView];
            if content.is_null() { return; }
            let subviews: *mut AnyObject = msg_send![content, subviews];
            if subviews.is_null() { return; }
            let count: usize = msg_send![subviews, count];
            for index in 0..count {
                let view: *mut AnyObject = msg_send![subviews, objectAtIndex: index];
                let is_effect: Bool = msg_send![view, isKindOfClass: class!(NSVisualEffectView)];
                if is_effect.as_bool() { let _: () = msg_send![view, setAlphaValue: alpha]; }
            }
        }
    });
}
#[cfg(not(target_os = "macos"))]
fn apply_blur_alpha(_window: &WebviewWindow) {}

fn set_blur_strength(app: &AppHandle, frost: u8) {
    BLUR_ALPHA_BITS.store(blur_alpha_for(frost).to_bits(), Ordering::SeqCst);
    for label in ["main", "quick"] { if let Some(window) = app.get_webview_window(label) { apply_blur_alpha(&window); } }
}

/// Whole-window opacity (NSWindow alphaValue), used to fade the window back while it is not in use.
#[cfg(target_os = "macos")]
fn set_window_alpha(window: &WebviewWindow, alpha: f64) {
    let handle = window.clone();
    let _ = window.run_on_main_thread(move || {
        use objc2::{msg_send, runtime::AnyObject};
        let Ok(pointer) = handle.ns_window() else { return };
        // SAFETY: the pointer is this window's NSWindow and we are on the main thread; setAlphaValue: takes a CGFloat.
        unsafe { let ns_window = pointer as *mut AnyObject; let _: () = msg_send![ns_window, setAlphaValue: alpha]; }
    });
}
#[cfg(not(target_os = "macos"))]
fn set_window_alpha(_window: &WebviewWindow, _alpha: f64) {}

/// Native vibrancy follows the window shape: rounded rectangle for the window, pill for the bubble.
fn set_effects_radius(window: &WebviewWindow, radius: f64) {
    let _ = window.set_effects(EffectsBuilder::new().effect(Effect::Popover).state(EffectState::Active).radius(radius).build());
    apply_blur_alpha(window);
    invalidate_shadow(window);
}
/// The system shadow keeps the window apart from what is behind it. After a shape change macOS has to recompute it,
/// and a transparent window only gets one once its content has painted, so it is recomputed a few times shortly after.
fn refresh_shadow(window: &WebviewWindow) {
    // The main window's shadow is drawn by the page in a window of its own (see create_shadow_window), where it can be as soft and wide as it needs.
    if window.label() == "main" { let _ = window.set_shadow(false); return; }
    let _ = window.set_shadow(false);
    let _ = window.set_shadow(true);
    invalidate_shadow(window);
    let later = window.clone();
    std::thread::spawn(move || for ms in [250u64, 700, 1500] {
        std::thread::sleep(std::time::Duration::from_millis(ms));
        invalidate_shadow(&later);
    });
}

/// This is a floating notes window, not a document window: macOS must not tile it (half screen) or full-screen it when it is
/// dragged to a screen edge.
#[cfg(target_os = "macos")]
fn disallow_tiling(window: &WebviewWindow) {
    let handle = window.clone();
    let _ = window.run_on_main_thread(move || {
        use objc2::{msg_send, runtime::AnyObject};
        let Ok(pointer) = handle.ns_window() else { return };
        // SAFETY: the pointer is this window's NSWindow and we are on the main thread; collectionBehavior is an NSUInteger bit set.
        unsafe {
            let ns_window = pointer as *mut AnyObject;
            let behavior: usize = msg_send![ns_window, collectionBehavior];
            // FullScreenNone (1 << 9) and FullScreenDisallowsTiling (1 << 12)
            let _: () = msg_send![ns_window, setCollectionBehavior: behavior | (1 << 9) | (1 << 12)];
        }
    });
}
#[cfg(not(target_os = "macos"))]
fn disallow_tiling(_window: &WebviewWindow) {}

/// The system shadow cannot be made wider or softer, so the main window gets its own: a transparent, click-through window
/// just behind it, a little larger on every side, in which the page draws a long, diffuse shadow. It follows the main window.
const SHADOW_PAD: f64 = 80.0;
fn create_shadow_window(app: &AppHandle) {
    let Some(main) = app.get_webview_window("main") else { return };
    let builder = WebviewWindowBuilder::new(app, "shadow", WebviewUrl::App("index.html?shadow".into()))
        .title("")
        .inner_size(400.0, 400.0)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible_on_all_workspaces(true)
        .focused(false)
        .visible(false);
    let Ok(shadow) = builder.build() else { return };
    let _ = shadow.set_ignore_cursor_events(true);
    attach_below(&main, &shadow);
    let app = app.clone();
    std::thread::spawn(move || {
        let mut last: Option<(i32, i32, u32, u32)> = None;
        let mut last_look = String::new();
        let mut ticks = 0u32;
        loop {
            std::thread::sleep(std::time::Duration::from_millis(16));
            if !main.is_visible().unwrap_or(false) { if shadow.is_visible().unwrap_or(false) { let _ = shadow.hide(); } continue; }
            let (Ok(pos), Ok(size), Ok(scale)) = (main.outer_position(), main.outer_size(), main.scale_factor()) else { continue };
            let pad = (SHADOW_PAD * scale).round() as i32;
            // macOS will not let a window poke above the menu bar, so the top margin shrinks when the window is near the top.
            let area_top = main.current_monitor().ok().flatten().map(|m| m.work_area().position.y).unwrap_or(0);
            let pad_top = (pos.y - area_top).clamp(0, pad);
            let frame = (pos.x - pad, pos.y - pad_top, size.width + 2 * pad as u32, size.height + (pad_top + pad) as u32);
            if last != Some(frame) {
                last = Some(frame);
                let _ = shadow.set_size(PhysicalSize::new(frame.2, frame.3));
                let _ = shadow.set_position(PhysicalPosition::new(frame.0, frame.1));
            }
            let (w, h) = (size.width as f64 / scale, size.height as f64 / scale);
            let radius = if w.min(h) <= 70.0 { (w.min(h) / 2.0).round() } else { WINDOW_RADIUS };
            // Also repeated every half second: the page may not have been loaded yet when the first one went out, and a lost one
            // would leave the shadow shaped for a window that is no longer the same size.
            ticks += 1;
            let look = format!("{radius}/{pad_top}");
            if look != last_look || ticks % 30 == 0 { last_look = look; let _ = app.emit_to("shadow", "dotist://shadow-radius", serde_json::json!({ "radius": radius, "top": pad_top as f64 / scale, "pad": SHADOW_PAD })); }
            if !shadow.is_visible().unwrap_or(true) { let _ = shadow.show(); attach_below(&main, &shadow); }
        }
    });
}

/// Orders `child` just behind `parent` and lets AppKit keep it there as the parent moves.
#[cfg(target_os = "macos")]
fn attach_below(parent: &WebviewWindow, child: &WebviewWindow) {
    let (parent, child) = (parent.clone(), child.clone());
    let _ = parent.clone().run_on_main_thread(move || {
        use objc2::{msg_send, runtime::AnyObject};
        let (Ok(p), Ok(c)) = (parent.ns_window(), child.ns_window()) else { return };
        // SAFETY: both pointers are live NSWindows and this runs on the main thread; NSWindowBelow is -1.
        unsafe { let _: () = msg_send![p as *mut AnyObject, addChildWindow: c as *mut AnyObject, ordered: -1isize]; }
    });
}
#[cfg(not(target_os = "macos"))]
fn attach_below(_parent: &WebviewWindow, _child: &WebviewWindow) {}

/// Ask AppKit to recompute the shadow from the window's current (rounded, translucent) shape.
#[cfg(target_os = "macos")]
fn invalidate_shadow(window: &WebviewWindow) {
    let handle = window.clone();
    let _ = window.run_on_main_thread(move || {
        use objc2::{msg_send, runtime::AnyObject};
        let Ok(pointer) = handle.ns_window() else { return };
        // SAFETY: the pointer is this window's NSWindow and we are on the main thread; invalidateShadow takes no arguments.
        unsafe { let ns_window = pointer as *mut AnyObject; let _: () = msg_send![ns_window, invalidateShadow]; }
    });
}
#[cfg(not(target_os = "macos"))]
fn invalidate_shadow(_window: &WebviewWindow) {}

#[derive(Default)]
struct Bubble {
    active: AtomicBool,
    saved: Mutex<Option<(PhysicalPosition<i32>, PhysicalSize<u32>)>>,
    snap_generation: AtomicU64,
    open_generation: AtomicU64,
    animating: AtomicBool,
    resize_generation: AtomicU64,
}

#[derive(Default)]
struct TrayState {
    icon: Mutex<Option<TrayIcon>>,
    menu: Mutex<Option<Menu<Wry>>>,
    /// The app menu's Settings item, so it can be relabelled when the language changes.
    app_settings: Mutex<Option<MenuItem<Wry>>>,
    app_views: Mutex<Option<MenuItem<Wry>>>,
    /// What the menu bar item can show; with several entries it cycles through them.
    titles: Mutex<Vec<String>>,
    index: AtomicU32,
    rotate_secs: AtomicU32,
    /// The groups currently listed in the menu's groups submenu, to skip rebuilding when nothing changed.
    groups: Mutex<Vec<(String, String)>>,
}

#[tauri::command]
fn list_tasks(store: State<'_, SharedStore>) -> Result<Vec<Task>, String> {
    store.lock().map_err(|e| e.to_string())?.list_tasks().map_err(|e| e.to_string())
}
#[tauri::command]
fn add_task(store: State<'_, SharedStore>, title: String, category: String, parent_id: Option<String>, due_date: Option<String>) -> Result<Task, String> {
    let mut store = store.lock().map_err(|e| e.to_string())?;
    let task = store.add_task_in(&title, &category, parent_id.as_deref()).map_err(|e| e.to_string())?;
    match due_date {
        Some(due) => store.set_due_date(&task.id, Some(&due)).map_err(|e| e.to_string()),
        None => Ok(task),
    }
}
#[tauri::command]
fn set_due_date(app: AppHandle, store: State<'_, SharedStore>, id: String, due_date: Option<String>) -> Result<Task, String> {
    let task = store.lock().map_err(|e| e.to_string())?.set_due_date(&id, due_date.as_deref()).map_err(|e| e.to_string())?;
    let _ = app.emit("dotist://tasks-changed", ());
    Ok(task)
}
#[tauri::command]
fn patch_task(app: AppHandle, store: State<'_, SharedStore>, id: String, title: Option<String>, category: Option<String>, completed: Option<bool>, status: Option<TaskStatus>) -> Result<Task, String> {
    let task = store.lock().map_err(|e| e.to_string())?.patch_task_with_status(&id, title.as_deref(), category.as_deref(), completed, status).map_err(|e| e.to_string())?;
    let _ = app.emit("dotist://tasks-changed", ());
    Ok(task)
}
#[tauri::command]
fn set_start_date(app: AppHandle, store: State<'_, SharedStore>, id: String, start_date: Option<String>) -> Result<Task, String> {
    let task = store.lock().map_err(|e| e.to_string())?.set_start_date(&id, start_date.as_deref()).map_err(|e| e.to_string())?;
    let _ = app.emit("dotist://tasks-changed", ());
    Ok(task)
}
#[tauri::command]
fn set_date_range(app: AppHandle, store: State<'_, SharedStore>, id: String, start_date: Option<String>, due_date: Option<String>) -> Result<Task, String> {
    let task = store.lock().map_err(|e| e.to_string())?.set_date_range(&id, start_date.as_deref(), due_date.as_deref()).map_err(|e| e.to_string())?;
    let _ = app.emit("dotist://tasks-changed", ());
    Ok(task)
}
#[tauri::command]
fn move_status_task(app: AppHandle, store: State<'_, SharedStore>, id: String, direction: i32) -> Result<(), String> {
    store.lock().map_err(|e| e.to_string())?.move_status_task(&id, direction).map_err(|e| e.to_string())?;
    let _ = app.emit("dotist://tasks-changed", ());
    Ok(())
}

#[tauri::command]
fn delete_task(store: State<'_, SharedStore>, id: String) -> Result<(), String> {
    store.lock().map_err(|e| e.to_string())?.delete_task(&id).map_err(|e| e.to_string())
}
#[tauri::command]
fn restore_task(store: State<'_, SharedStore>, id: String) -> Result<Task, String> {
    store.lock().map_err(|e| e.to_string())?.restore_task(&id).map_err(|e| e.to_string())
}
#[tauri::command]
fn move_task(store: State<'_, SharedStore>, id: String, direction: i32) -> Result<(), String> {
    store.lock().map_err(|e| e.to_string())?.move_task(&id, direction).map_err(|e| e.to_string())
}

#[tauri::command]
fn list_groups(store: State<'_, SharedStore>) -> Result<Vec<Group>, String> {
    store.lock().map_err(|e| e.to_string())?.list_groups().map_err(|e| e.to_string())
}
#[tauri::command]
fn add_group(store: State<'_, SharedStore>, name: String, color: Option<String>) -> Result<Group, String> {
    store.lock().map_err(|e| e.to_string())?.add_group(&name, color.as_deref()).map_err(|e| e.to_string())
}
#[tauri::command]
fn update_group(store: State<'_, SharedStore>, id: String, name: Option<String>, color: Option<String>) -> Result<Group, String> {
    store.lock().map_err(|e| e.to_string())?.update_group(&id, name.as_deref(), color.as_deref()).map_err(|e| e.to_string())
}
#[tauri::command]
fn move_group(store: State<'_, SharedStore>, id: String, direction: i32) -> Result<(), String> {
    store.lock().map_err(|e| e.to_string())?.move_group(&id, direction).map_err(|e| e.to_string())
}
#[tauri::command]
fn delete_group(store: State<'_, SharedStore>, id: String) -> Result<(), String> {
    store.lock().map_err(|e| e.to_string())?.delete_group(&id).map_err(|e| e.to_string())
}
#[tauri::command]
fn restore_group(store: State<'_, SharedStore>, id: String) -> Result<Group, String> {
    store.lock().map_err(|e| e.to_string())?.restore_group(&id).map_err(|e| e.to_string())
}
#[tauri::command]
fn reparent_task(store: State<'_, SharedStore>, id: String, parent_id: Option<String>) -> Result<Task, String> {
    store.lock().map_err(|e| e.to_string())?.reparent_task(&id, parent_id.as_deref()).map_err(|e| e.to_string())
}

fn work_area(window: &WebviewWindow) -> Result<(PhysicalPosition<i32>, PhysicalSize<u32>, f64), String> {
    let monitor = window.current_monitor().map_err(|e| e.to_string())?
        .or(window.primary_monitor().map_err(|e| e.to_string())?)
        .ok_or("找不到屏幕")?;
    let area = monitor.work_area();
    Ok((area.position, area.size, monitor.scale_factor()))
}

#[derive(Clone, Copy)]
struct Rect { left: f64, top: f64, right: f64, bottom: f64 }
fn lerp(a: f64, b: f64, t: f64) -> f64 { a + (b - a) * t }
fn lerp_rect(a: Rect, b: Rect, t: f64) -> Rect { Rect { left: lerp(a.left, b.left, t), top: lerp(a.top, b.top, t), right: lerp(a.right, b.right, t), bottom: lerp(a.bottom, b.bottom, t) } }

// Easing curves. `ease_out_back` overshoots the target slightly and settles, which reads as a gentle spring.
fn ease_out_cubic(t: f64) -> f64 { 1.0 - (1.0 - t).powi(3) }
fn ease_in_out_cubic(t: f64) -> f64 { if t < 0.5 { 4.0 * t * t * t } else { 1.0 - (-2.0 * t + 2.0).powi(3) / 2.0 } }
fn ease_out_back(t: f64, overshoot: f64) -> f64 { let c = overshoot + 1.0; 1.0 + c * (t - 1.0).powi(3) + overshoot * (t - 1.0).powi(2) }

/// Drives the window frame from `from` to `to` by wall-clock time, so the duration is exact however long a frame takes.
/// The vibrancy corner radius follows along. Returns early when `cancelled` turns true.
fn animate_frame(window: &WebviewWindow, from: Rect, to: Rect, radii: (f64, f64), duration_ms: u64, ease: &dyn Fn(f64) -> f64, cancelled: &dyn Fn() -> bool) {
    let started = std::time::Instant::now();
    let total = (duration_ms.max(1)) as f64 / 1000.0;
    let mut last_radius = f64::MIN;
    loop {
        let t = (started.elapsed().as_secs_f64() / total).min(1.0);
        let rect = lerp_rect(from, to, ease(t));
        let width = (rect.right - rect.left).round().max(1.0);
        let height = (rect.bottom - rect.top).round().max(1.0);
        let _ = window.set_size(PhysicalSize::new(width as u32, height as u32));
        let _ = window.set_position(PhysicalPosition::new(rect.left.round() as i32, rect.top.round() as i32));
        // Rebuilding the vibrancy mask is the costly step, so only do it when the radius visibly changed.
        let radius = lerp(radii.0, radii.1, ease_out_cubic(t));
        if (radius - last_radius).abs() >= 1.0 { set_effects_radius(window, radius); last_radius = radius; }
        if t >= 1.0 || cancelled() { break; }
        std::thread::sleep(std::time::Duration::from_millis(3));
    }
}

const DEFAULT_SIZE: (f64, f64) = (364.0, 620.0);

/// The size the user last dragged the window to, or the default.
fn persisted_size(app: &AppHandle) -> (f64, f64) {
    app.state::<SettingsStore>().current.lock().ok().filter(|s| s.window_width > 0 && s.window_height > 0).map(|s| (s.window_width as f64, s.window_height as f64)).unwrap_or(DEFAULT_SIZE)
}

/// Remembers a new window size once resizing has settled (not while the window is a bubble or animating).
fn remember_size(app: &AppHandle, window: &WebviewWindow, generation: u64) {
    let (app, window) = (app.clone(), window.clone());
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(500));
        let bubble = app.state::<Bubble>();
        if bubble.resize_generation.load(Ordering::SeqCst) != generation || bubble.active.load(Ordering::SeqCst) || bubble.animating.load(Ordering::SeqCst) { return; }
        let (Ok(size), Ok(scale)) = (window.outer_size(), window.scale_factor()) else { return };
        let (width, height) = ((size.width as f64 / scale).round() as u32, (size.height as f64 / scale).round() as u32);
        if width < 320 || height < 440 { return; }
        let store = app.state::<SettingsStore>();
        let updated = store.current.lock().map(|mut current| { current.window_width = width; current.window_height = height; current.clone() });
        if let Ok(updated) = updated { let _ = store.save(&updated); }
    });
}

/// Back to the default window size.
#[tauri::command]
fn reset_window_size(app: AppHandle, bubble: State<'_, Bubble>) -> Result<(), String> {
    let store = app.state::<SettingsStore>();
    let updated = store.current.lock().map(|mut current| { current.window_width = 0; current.window_height = 0; current.clone() }).map_err(|e| e.to_string())?;
    store.save(&updated)?;
    if let Ok(mut saved) = bubble.saved.lock() { if let (Some((pos, _)), Some(window)) = (saved.clone(), app.get_webview_window("main")) { let scale = window.scale_factor().unwrap_or(1.0); *saved = Some((pos, PhysicalSize::new((DEFAULT_SIZE.0 * scale) as u32, (DEFAULT_SIZE.1 * scale) as u32))); } }
    if !bubble.active.load(Ordering::SeqCst) { if let Some(window) = app.get_webview_window("main") { let _ = window.set_size(LogicalSize::new(DEFAULT_SIZE.0, DEFAULT_SIZE.1)); } }
    Ok(())
}

/// Animates the native window (and its vibrancy) between the full window and the 48px bubble.
/// The bubble sits exactly where the collapse button (top-right corner of the window) is.
/// Collapsing eases in and out; expanding springs a little past its size and settles.
#[tauri::command]
async fn animate_bubble(window: WebviewWindow, bubble: State<'_, Bubble>, bubble_mode: bool, duration_ms: u64) -> Result<(), String> {
    let (area_pos, area_size, scale) = work_area(&window)?;
    let pos = window.outer_position().map_err(|e| e.to_string())?;
    let size = window.outer_size().map_err(|e| e.to_string())?;
    let current = Rect { left: pos.x as f64, top: pos.y as f64, right: pos.x as f64 + size.width as f64, bottom: pos.y as f64 + size.height as f64 };
    let (area_left, area_top) = (area_pos.x as f64, area_pos.y as f64);
    let (area_right, area_bottom) = (area_left + area_size.width as f64, area_top + area_size.height as f64);
    let bubble_px = BUBBLE * scale;
    // Centre of the collapse button relative to the window's top-right corner: 22px in, 22px down.
    let anchor = (22.0 * scale, 22.0 * scale);
    let (target, radii) = if bubble_mode {
        if bubble.active.load(Ordering::SeqCst) { return Ok(()); }
        *bubble.saved.lock().map_err(|e| e.to_string())? = Some((pos, size));
        // The bubble always lands fully on screen, even when the window was dragged partly off it.
        let left = (current.right - anchor.0 - bubble_px / 2.0).clamp(area_left, (area_right - bubble_px).max(area_left));
        let top = (current.top + anchor.1 - bubble_px / 2.0).clamp(area_top, (area_bottom - bubble_px).max(area_top));
        window.set_min_size(Some(LogicalSize::new(BUBBLE, BUBBLE))).map_err(|e| e.to_string())?;
        window.set_resizable(false).map_err(|e| e.to_string())?;
        (Rect { left, top, right: left + bubble_px, bottom: top + bubble_px }, (WINDOW_RADIUS, BUBBLE_RADIUS))
    } else {
        if !bubble.active.load(Ordering::SeqCst) { return Ok(()); }
        let saved = bubble.saved.lock().map_err(|e| e.to_string())?.take();
        let (default_w, default_h) = persisted_size(window.app_handle());
        let (width, height) = saved.map(|(_, s)| (s.width as f64, s.height as f64)).unwrap_or((default_w * scale, default_h * scale));
        let (width, height) = (width.min(area_right - area_left), height.min(area_bottom - area_top));
        // The bubble core is at the right end of the capsule when it sits on the right half of the screen.
        let on_right = current.left + (current.right - current.left) / 2.0 > area_left + (area_right - area_left) / 2.0;
        let core_left = if on_right { current.right - bubble_px } else { current.left };
        let right = (core_left + bubble_px / 2.0 + anchor.0).max(area_left + width).min(area_right);
        let top = (current.top + bubble_px / 2.0 - anchor.1).clamp(area_top, (area_bottom - height).max(area_top));
        (Rect { left: right - width, top, right, bottom: top + height }, (BUBBLE_RADIUS, WINDOW_RADIUS))
    };
    if !bubble_mode { window.set_min_size(Some(LogicalSize::new(BUBBLE, BUBBLE))).map_err(|e| e.to_string())?; }
    bubble.open_generation.fetch_add(1, Ordering::SeqCst);
    bubble.animating.store(true, Ordering::SeqCst);
    if bubble_mode {
        animate_frame(&window, current, target, radii, duration_ms, &ease_in_out_cubic, &|| false);
        bubble.active.store(true, Ordering::SeqCst);
    } else {
        animate_frame(&window, current, target, radii, duration_ms, &|t| ease_out_back(t, 0.8), &|| false);
        window.set_min_size(Some(LogicalSize::new(MIN_WIDTH, MIN_HEIGHT))).map_err(|e| e.to_string())?;
        window.set_resizable(true).map_err(|e| e.to_string())?;
        bubble.active.store(false, Ordering::SeqCst);
    }
    set_effects_radius(&window, radii.1);
    refresh_shadow(&window);
    bubble.animating.store(false, Ordering::SeqCst);
    Ok(())
}

/// The logical size the window will grow back to, so the page can lay its content out at that size up front.
#[tauri::command]
fn bubble_target_size(window: WebviewWindow, bubble: State<'_, Bubble>) -> Result<(f64, f64), String> {
    let scale = window.scale_factor().map_err(|e| e.to_string())?;
    let saved = bubble.saved.lock().map_err(|e| e.to_string())?.map(|(_, size)| (size.width as f64 / scale, size.height as f64 / scale));
    Ok(saved.unwrap_or_else(|| persisted_size(window.app_handle())))
}

/// Widens the bubble into a capsule (hover) toward the screen interior, or shrinks it back, animated.
/// `width` is the logical width the content needs; it is clamped to something sensible for the screen.
#[tauri::command]
async fn set_bubble_open(window: WebviewWindow, bubble: State<'_, Bubble>, open: bool, width: Option<f64>) -> Result<(), String> {
    if !bubble.active.load(Ordering::SeqCst) { return Ok(()); }
    let generation = bubble.open_generation.fetch_add(1, Ordering::SeqCst) + 1;
    let (area_pos, area_size, scale) = work_area(&window)?;
    let pos = window.outer_position().map_err(|e| e.to_string())?;
    let size = window.outer_size().map_err(|e| e.to_string())?;
    let max_width = (area_size.width as f64 / scale * 0.5).min(440.0).max(CAPSULE_MIN);
    let target_width = if open { width.unwrap_or(CAPSULE_MIN).clamp(CAPSULE_MIN, max_width) } else { BUBBLE };
    let from = Rect { left: pos.x as f64, top: pos.y as f64, right: pos.x as f64 + size.width as f64, bottom: pos.y as f64 + size.height as f64 };
    let target_px = (target_width * scale).round();
    let on_right = pos.x + size.width as i32 / 2 > area_pos.x + area_size.width as i32 / 2;
    let to = if on_right { Rect { left: from.right - target_px, ..from } } else { Rect { right: from.left + target_px, ..from } };
    window.set_min_size(Some(LogicalSize::new(BUBBLE, BUBBLE))).map_err(|e| e.to_string())?;
    let cancelled = || bubble.open_generation.load(Ordering::SeqCst) != generation || !bubble.active.load(Ordering::SeqCst);
    if open {
        animate_frame(&window, from, to, (BUBBLE_RADIUS, BUBBLE_RADIUS), 260, &ease_out_cubic, &cancelled);
    } else {
        animate_frame(&window, from, to, (BUBBLE_RADIUS, BUBBLE_RADIUS), 180, &ease_out_cubic, &cancelled);
    }
    // Make sure the mask matches the final size, even if the last frame was cut short by a newer request.
    if bubble.active.load(Ordering::SeqCst) && bubble.open_generation.load(Ordering::SeqCst) == generation { set_effects_radius(&window, BUBBLE_RADIUS); }
    Ok(())
}

/// The page decides what the menu bar item should say (it knows the tasks and the language); this stores it.
#[tauri::command]
fn set_tray_titles(app: AppHandle, titles: Vec<String>) {
    let state = app.state::<TrayState>();
    if let Ok(mut current) = state.titles.lock() { if *current == titles { return; } *current = titles; }
    state.index.store(0, Ordering::SeqCst);
    refresh_tray_title(&state);
}

fn refresh_tray_title(tray: &TrayState) {
    let title = tray.titles.lock().ok().and_then(|titles| if titles.is_empty() { None } else { titles.get(tray.index.load(Ordering::SeqCst) as usize % titles.len()).cloned() });
    if let Ok(guard) = tray.icon.lock() { if let Some(icon) = guard.as_ref() { let _ = icon.set_title(title); } }
}

/// The tray library highlights the status item when the right button goes down and only clears it on a left-button
/// release, so a right click that runs an action (instead of opening the menu) leaves it stuck. Clear it by hand.
#[cfg(target_os = "macos")]
fn clear_tray_highlight(tray: &TrayIcon) {
    let _ = tray.with_inner_tray_icon(|inner| {
        if let Some(item) = inner.ns_status_item() {
            use objc2::{msg_send, runtime::{AnyObject, Bool}};
            // SAFETY: `item` is the live NSStatusItem owned by the tray; its button is asked to drop its highlight.
            unsafe {
                let button: *mut AnyObject = msg_send![&*item, button];
                if !button.is_null() { let _: () = msg_send![button, highlight: Bool::NO]; }
            }
        }
    });
}
#[cfg(not(target_os = "macos"))]
fn clear_tray_highlight(_tray: &TrayIcon) {}

/// What a click on the menu bar item does.
fn run_tray_action(app: &AppHandle, action: &str) {
    match action {
        "toggle" => toggle_main(app),
        "bubble" => { if app.state::<Bubble>().active.load(Ordering::SeqCst) { expand_main(app); } else { show_main(app); let _ = app.emit("dotist://collapse", ()); } }
        "quick" => open_quick_window(app),
        "settings" => open_settings_window(app),
        "show" => expand_main(app),
        _ => {}
    }
}

/// The menu stays attached and each button decides on its own whether a click opens it; the other buttons run their action.
fn apply_tray_menu(app: &AppHandle) {
    let (left, right) = app.state::<SettingsStore>().current.lock().map(|s| (s.tray_left_click.clone(), s.tray_right_click.clone())).unwrap_or_else(|_| ("toggle".into(), "menu".into()));
    let state = app.state::<TrayState>();
    let menu = state.menu.lock().ok().and_then(|slot| slot.clone());
    let guard = state.icon.lock();
    if let Ok(guard) = guard {
        if let Some(icon) = guard.as_ref() {
            let _ = icon.set_menu(menu);
            // tray-icon has a flag per button; Tauri only wraps the left one, so reach the inner tray icon for both.
            let (menu_left, menu_right) = (left == "menu", right == "menu");
            let _ = icon.with_inner_tray_icon(move |inner| {
                inner.set_show_menu_on_left_click(menu_left);
                inner.set_show_menu_on_right_click(menu_right);
            });
        }
    }
}

fn show_main(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

/// Dock icon and menu bar item are independent; with both off Dotist stays reachable through its shortcuts and the bubble.
#[derive(Default)]
struct ViewsPresence(AtomicBool);
fn effective_dock(setting: bool, views_open: bool) -> bool { setting || views_open }
fn apply_presence(app: &AppHandle, dock: bool, menubar: bool) {
    let dock = effective_dock(dock, app.state::<ViewsPresence>().0.load(Ordering::SeqCst));
    #[cfg(target_os = "macos")]
    { let _ = app.set_dock_visibility(dock); }
    #[cfg(not(target_os = "macos"))]
    let _ = dock;
    if let Ok(guard) = app.state::<TrayState>().icon.lock() { if let Some(icon) = guard.as_ref() { let _ = icon.set_visible(menubar); } }
}

fn expand_main(app: &AppHandle) {
    show_main(app);
    if app.state::<Bubble>().active.load(Ordering::SeqCst) { let _ = app.emit("dotist://expand", ()); }
}

fn toggle_main(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else { return };
    if app.state::<Bubble>().active.load(Ordering::SeqCst) { let _ = app.emit("dotist://expand", ()); show_main(app); }
    else if window.is_visible().unwrap_or(true) { let _ = app.emit("dotist://collapse", ()); }
    else { show_main(app); }
}

/// After a drag ends (or when the bubble is found partly off screen): pull it fully back onto the screen.
fn schedule_snap(window: WebviewWindow) {
    let app = window.app_handle().clone();
    let generation = app.state::<Bubble>().snap_generation.fetch_add(1, Ordering::SeqCst) + 1;
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(180));
        let bubble = app.state::<Bubble>();
        if !bubble.active.load(Ordering::SeqCst) || bubble.snap_generation.load(Ordering::SeqCst) != generation || bubble.animating.load(Ordering::SeqCst) { return; }
        // The window has stopped moving: a native drag never reports its end to the page, so say so.
        let _ = app.emit("dotist://drag-end", ());
        let Ok((area_pos, area_size, _)) = work_area(&window) else { return };
        let (Ok(pos), Ok(size)) = (window.outer_position(), window.outer_size()) else { return };
        let max_x = (area_pos.x + area_size.width as i32 - size.width as i32).max(area_pos.x);
        let max_y = (area_pos.y + area_size.height as i32 - size.height as i32).max(area_pos.y);
        let (x, y) = (pos.x.clamp(area_pos.x, max_x), pos.y.clamp(area_pos.y, max_y));
        if x != pos.x || y != pos.y { let _ = window.set_position(PhysicalPosition::new(x, y)); }
    });
}

#[derive(Serialize)]
struct SettingsView {
    #[serde(flatten)]
    settings: Settings,
    launch_at_login: bool,
    mcp_path: String,
    db_path: String,
    version: String,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct SettingsPatch {
    theme: Option<String>,
    language: Option<String>,
    opacity: Option<u8>,
    frost: Option<u8>,
    toggle_shortcut: Option<String>,
    quick_add_shortcut: Option<String>,
    settings_shortcut: Option<String>,
    views_shortcut: Option<String>,
    tray_mode: Option<String>,
    tray_rotate_secs: Option<u16>,
    tray_left_click: Option<String>,
    tray_right_click: Option<String>,
    always_on_top: Option<bool>,
    hover_expand: Option<bool>,
    show_dock: Option<bool>,
    show_menubar: Option<bool>,
    idle_fade: Option<bool>,
    locked: Option<bool>,
    idle_opacity: Option<u8>,
    idle_delay_secs: Option<u8>,
    idle_fade_secs: Option<u8>,
    tray_filter: Option<String>,
    tray_group: Option<String>,
    group_colors: Option<String>,
    filters: Option<Vec<String>>,
    default_filter: Option<String>,
    auto_collapse: Option<bool>,
    auto_collapse_secs: Option<u16>,
    auto_check_updates: Option<bool>,
    auto_install_updates: Option<bool>,
    skipped_update_version: Option<String>,
    launch_at_login: Option<bool>,
}

fn mcp_path() -> String {
    std::env::current_exe().ok().and_then(|exe| exe.parent().map(|dir| dir.join("dotist-mcp"))).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()
}
fn db_path_string() -> String { database_path().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default() }

fn settings_view(app: &AppHandle) -> SettingsView {
    let settings = app.state::<SettingsStore>().current.lock().map(|s| s.clone()).unwrap_or_default();
    SettingsView { settings, launch_at_login: app.autolaunch().is_enabled().unwrap_or(false), mcp_path: mcp_path(), db_path: db_path_string(), version: app.package_info().version.to_string() }
}

/// Resolves the language setting ("system" follows the first macOS preferred language).
fn resolve_language(setting: &str) -> &'static str {
    let tag = if setting == "system" {
        std::process::Command::new("defaults").args(["read", "-g", "AppleLanguages"]).output().ok()
            .and_then(|out| String::from_utf8(out.stdout).ok())
            .and_then(|text| text.split('"').nth(1).map(str::to_owned))
            .unwrap_or_else(|| "en".into())
    } else { setting.to_owned() };
    let tag = tag.to_lowercase();
    if tag.starts_with("zh") { if tag.contains("hant") || tag.contains("-tw") || tag.contains("-hk") || tag.contains("-mo") { "zh-TW" } else { "zh-CN" } }
    else if tag.starts_with("ja") { "ja" } else { "en" }
}

/// Native strings (menu bar, window titles). Everything inside the windows is translated by the page.
fn native_text(lang: &str, key: &str) -> &'static str {
    match (key, lang) {
        ("show", "en") => "Show Dotist", ("show", "zh-TW") => "顯示視窗", ("show", "ja") => "ウインドウを表示", ("show", _) => "显示窗口",
        ("collapse", "en") => "Collapse to Bubble", ("collapse", "zh-TW") => "收起為懸浮球", ("collapse", "ja") => "バブルに折りたたむ", ("collapse", _) => "收起为悬浮球",
        ("count", "en") => "Show Count in Menu Bar", ("count", "zh-TW") => "在選單列顯示數字", ("count", "ja") => "メニューバーに件数を表示", ("count", _) => "在菜单栏显示数字",
        ("views", "en") => "Task Views", ("views", "zh-TW") => "任務視圖", ("views", "ja") => "タスクビュー", ("views", _) => "任务视图",
        ("settings", "en") => "Settings…", ("settings", "zh-TW") => "設定…", ("settings", "ja") => "設定…", ("settings", _) => "设置…",
        ("quit", "en") => "Quit Dotist", ("quit", "zh-TW") => "結束 Dotist", ("quit", "ja") => "Dotist を終了", ("quit", _) => "退出 Dotist",
        ("quick", "en") => "Quick Add…", ("quick", "zh-TW") => "快速新增…", ("quick", "ja") => "クイック追加…", ("quick", _) => "快速添加…",
        ("groups_title", "en") => "Groups", ("groups_title", "zh-TW") => "分組", ("groups_title", "ja") => "グループ", ("groups_title", _) => "分组",
        ("filters_title", "en") => "Date Perspective", ("filters_title", "zh-TW") => "日期透視", ("filters_title", "ja") => "日付の切り口", ("filters_title", _) => "日期透视",
        ("all_groups", "en") => "All Groups", ("all_groups", "zh-TW") => "全部分組", ("all_groups", "ja") => "すべてのグループ", ("all_groups", _) => "全部分组",
        ("settings_title", "en") => "Dotist Settings", ("settings_title", "zh-TW") => "Dotist 設定", ("settings_title", "ja") => "Dotist 設定", ("settings_title", _) => "Dotist 设置",
        _ => "",
    }
}

fn filter_label(lang: &str, id: &str) -> &'static str {
    match (id, lang) {
        ("today", "en") => "Today", ("today", "zh-TW") => "今天", ("today", "ja") => "今日", ("today", _) => "今天",
        ("all", "en") => "All", ("all", "zh-TW") => "全部", ("all", "ja") => "すべて", ("all", _) => "全部",
        ("tomorrow", "en") => "Tomorrow", ("tomorrow", "zh-TW") => "明天", ("tomorrow", "ja") => "明日", ("tomorrow", _) => "明天",
        ("week", "en") => "This week", ("week", "zh-TW") => "本週", ("week", "ja") => "今週", ("week", _) => "本周",
        ("nextweek", "en") => "Next week", ("nextweek", "zh-TW") => "下週", ("nextweek", "ja") => "来週", ("nextweek", _) => "下周",
        ("next7", "en") => "Next 7 days", ("next7", "zh-TW") => "未來 7 天", ("next7", "ja") => "今後 7 日", ("next7", _) => "未来 7 天",
        ("overdue", "en") => "Overdue", ("overdue", "zh-TW") => "已逾期", ("overdue", "ja") => "期限切れ", ("overdue", _) => "已逾期",
        ("undated", "en") => "No date", ("undated", "zh-TW") => "無日期", ("undated", "ja") => "日付なし", ("undated", _) => "无日期",
        ("done", "en") => "Completed", ("done", "zh-TW") => "已完成", ("done", "ja") => "完了", ("done", _) => "已完成",
        _ => "",
    }
}

const INDENT: &str = "\u{2003}\u{2003}";

/// The menu bar menu, flat: window actions, then the groups and the date perspectives written out and indented under
/// their headings (⌘0…⌘9 for groups, ⌥⌘1…⌥⌘9 for perspectives, in the order chosen in settings), then Settings and Quit.
fn build_tray_menu(app: &AppHandle, lang: &str, groups: &[(String, String)], filters: &[String]) -> tauri::Result<Menu<Wry>> {
    let menu = Menu::new(app)?;
    menu.append(&MenuItem::with_id(app, "show", native_text(lang, "show"), true, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(app, "collapse", native_text(lang, "collapse"), true, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(app, "views", native_text(lang, "views"), true, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(app, "quick", native_text(lang, "quick"), true, None::<&str>)?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(app, "hdr-groups", native_text(lang, "groups_title"), false, None::<&str>)?)?;
    let mut entries: Vec<(String, String)> = vec![("all".into(), native_text(lang, "all_groups").into())];
    entries.extend(groups.iter().cloned());
    for (index, (id, name)) in entries.iter().enumerate() {
        let accelerator = if index <= 9 { Some(format!("CmdOrCtrl+{index}")) } else { None };
        menu.append(&MenuItem::with_id(app, format!("group:{id}"), format!("{INDENT}{name}"), true, accelerator.as_deref())?)?;
    }
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(app, "hdr-filters", native_text(lang, "filters_title"), false, None::<&str>)?)?;
    for (index, id) in filters.iter().enumerate() {
        let accelerator = if index < 9 { Some(format!("Alt+CmdOrCtrl+{}", index + 1)) } else { None };
        menu.append(&MenuItem::with_id(app, format!("filter:{id}"), format!("{INDENT}{}", filter_label(lang, id)), true, accelerator.as_deref())?)?;
    }
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(app, "settings", native_text(lang, "settings"), true, Some("CmdOrCtrl+,"))?)?;
    menu.append(&MenuItem::with_id(app, "quit", native_text(lang, "quit"), true, None::<&str>)?)?;
    Ok(menu)
}

/// Rebuilds the menu bar menu from the current language, groups and chosen perspectives, and attaches it.
fn refresh_tray_menu(app: &AppHandle) {
    let (language, filters) = app.state::<SettingsStore>().current.lock().map(|s| (s.language.clone(), s.filters.clone())).unwrap_or_else(|_| ("system".into(), FILTER_IDS.iter().map(|id| id.to_string()).collect()));
    let groups = app.state::<TrayState>().groups.lock().map(|g| g.clone()).unwrap_or_default();
    if let Ok(menu) = build_tray_menu(app, resolve_language(&language), &groups, &filters) {
        if let Ok(mut slot) = app.state::<TrayState>().menu.lock() { *slot = Some(menu); }
        apply_tray_menu(app);
    }
}

/// The page tells the menu bar which groups exist, so the groups submenu always matches the window.
#[tauri::command]
fn set_tray_groups(app: AppHandle, groups: Vec<(String, String)>) {
    {
        let state = app.state::<TrayState>();
        let Ok(mut current) = state.groups.lock() else { return };
        if *current == groups { return; }
        *current = groups.clone();
    }
    refresh_tray_menu(&app);
}

/// Shows the window and tells the page to jump to a perspective and/or a group.
fn goto(app: &AppHandle, filter: Option<&str>, group: Option<&str>) {
    expand_main(app);
    let _ = app.emit("dotist://goto", serde_json::json!({ "filter": filter, "group": group }));
}

fn apply_language(app: &AppHandle, setting: &str) {
    let lang = resolve_language(setting);
    if let Ok(item) = app.state::<TrayState>().app_settings.lock() { if let Some(item) = item.as_ref() { let _ = item.set_text(native_text(lang, "settings")); } }
    if let Ok(item) = app.state::<TrayState>().app_views.lock() { if let Some(item) = item.as_ref() { let _ = item.set_text(native_text(lang, "views")); } }
    if let Some(window) = app.get_webview_window("views") { let _ = window.set_title(native_text(lang, "views")); }
    // The menu reads the language from the stored settings; make sure it already has the new one.
    if let Ok(mut current) = app.state::<SettingsStore>().current.lock() { current.language = setting.to_string(); }
    refresh_tray_menu(app);
    if let Some(window) = app.get_webview_window("settings") { let _ = window.set_title(native_text(lang, "settings_title")); }
}

fn apply_theme(app: &AppHandle, theme: &str) -> Result<(), String> {
    let value = match theme { "system" => None, "light" => Some(Theme::Light), "dark" => Some(Theme::Dark), _ => return Err("无效的主题".into()) };
    for label in ["main", "settings", "views"] {
        if let Some(window) = app.get_webview_window(label) { window.set_theme(value).map_err(|e| e.to_string())?; }
    }
    Ok(())
}

fn register_shortcut(app: &AppHandle, accelerator: &str, action: fn(&AppHandle)) -> Result<(), String> {
    if accelerator.is_empty() { return Ok(()); }
    let shortcut: Shortcut = accelerator.parse().map_err(|_| format!("无法识别快捷键「{accelerator}」"))?;
    // Cmd+, belongs to the menu bar item while Dotist is in front; a global grab would hijack every app's Settings key.
    if Some(shortcut) == "Command+Comma".parse::<Shortcut>().ok() { return Ok(()); }
    app.global_shortcut().on_shortcut(shortcut, move |app, _, event| { if event.state == ShortcutState::Pressed { action(app); } })
        .map_err(|e| format!("快捷键「{accelerator}」不可用，可能已被其他应用占用（{e}）"))
}
fn unregister_shortcut(app: &AppHandle, accelerator: &str) {
    if let Ok(shortcut) = accelerator.parse::<Shortcut>() { let _ = app.global_shortcut().unregister(shortcut); }
}
/// Opens (or focuses) the separate settings window. The main window carries no settings button; this is reached
/// from the menu bar item and the settings shortcut.
fn open_settings_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let (theme, language) = app.state::<SettingsStore>().current.lock().map(|s| (s.theme.clone(), s.language.clone())).unwrap_or_else(|_| ("system".into(), "system".into()));
    let builder = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("index.html?settings".into()))
        .title(native_text(resolve_language(&language), "settings_title"))
        .inner_size(740.0, 560.0)
        .min_inner_size(600.0, 420.0)
        .resizable(true)
        .transparent(true)
        .effects(EffectsBuilder::new().effect(Effect::Popover).state(EffectState::Active).build())
        .title_bar_style(TitleBarStyle::Overlay)
        .hidden_title(true)
        .center()
        .always_on_top(true);
    match builder.build() {
        Ok(window) => {
            let _ = window.set_theme(match theme.as_str() { "light" => Some(Theme::Light), "dark" => Some(Theme::Dark), _ => None });
            apply_blur_alpha(&window);
            disallow_tiling(&window);
            let _ = window.set_shadow(true);
            let _ = window.set_focus();
        }
        Err(error) => eprintln!("无法打开设置窗口：{error}"),
    }
}
/// Native drag/drop is disabled here so HTML task drags reach the webview.
fn open_views_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("views") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let (theme, language) = app.state::<SettingsStore>().current.lock().map(|s| (s.theme.clone(), s.language.clone())).unwrap_or_else(|_| ("system".into(), "system".into()));
    let builder = WebviewWindowBuilder::new(app, "views", WebviewUrl::App("index.html?views".into()))
        .title(native_text(resolve_language(&language), "views"))
        .inner_size(1000.0, 720.0).min_inner_size(680.0, 480.0)
        .resizable(true).disable_drag_drop_handler().transparent(true)
        .effects(EffectsBuilder::new().effect(Effect::Popover).state(EffectState::Active).build())
        .title_bar_style(TitleBarStyle::Overlay).hidden_title(true).center();
    match builder.build() {
        Ok(window) => {
            app.state::<ViewsPresence>().0.store(true, Ordering::SeqCst);
            if let Ok(settings) = app.state::<SettingsStore>().current.lock() { apply_presence(app, settings.show_dock, settings.show_menubar); }
            let _ = window.set_theme(match theme.as_str() { "light" => Some(Theme::Light), "dark" => Some(Theme::Dark), _ => None });
            apply_blur_alpha(&window);
            disallow_tiling(&window);
            let _ = window.set_shadow(true);
            let _ = window.set_focus();
        }
        Err(error) => eprintln!("无法打开视图窗口：{error}"),
    }
}
fn action_views(app: &AppHandle) { open_views_window(app); }
fn action_settings(app: &AppHandle) { open_settings_window(app); }
fn action_toggle(app: &AppHandle) { toggle_main(app); }
/// A small centred input, shown from anywhere: type, Enter, and the task is added. Esc or clicking away dismisses it.
fn open_quick_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("quick") {
        let _ = window.show();
        let _ = window.set_focus();
        let _ = app.emit_to("quick", "dotist://quick-show", ());
        return;
    }
    let effects = EffectsBuilder::new().effect(Effect::Popover).state(EffectState::Active).radius(18.0).build();
    let builder = WebviewWindowBuilder::new(app, "quick", WebviewUrl::App("index.html?quick".into()))
        .title("Dotist")
        .inner_size(560.0, 112.0)
        .resizable(false)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .effects(effects)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible_on_all_workspaces(true)
        .focused(true);
    match builder.build() {
        Ok(window) => {
            if let Ok(Some(monitor)) = window.primary_monitor() {
                let area = monitor.work_area();
                let size = window.outer_size().unwrap_or(PhysicalSize::new(560, 112));
                let x = area.position.x + (area.size.width as i32 - size.width as i32) / 2;
                let y = area.position.y + (area.size.height as f64 * 0.2) as i32;
                let _ = window.set_position(PhysicalPosition::new(x, y));
            }
            apply_blur_alpha(&window);
            disallow_tiling(&window);
            refresh_shadow(&window);
            let _ = window.set_focus();
        }
        Err(error) => eprintln!("无法打开快速添加窗口：{error}"),
    }
}
fn action_quick_add(app: &AppHandle) { open_quick_window(app); }

/// Hides the quick-add window; when a task was added, every window is told to reload.
#[tauri::command]
fn quick_done(app: AppHandle, added: bool) {
    if let Some(window) = app.get_webview_window("quick") { let _ = window.hide(); }
    if added { let _ = app.emit("dotist://tasks-changed", ()); }
}

/// While a shortcut is being recorded, global shortcuts and the menu bar's key equivalents are paused so every
/// combination reaches the page instead of triggering something.
#[derive(Default)]
struct Capture { menu: Mutex<Option<Menu<Wry>>> }

#[tauri::command]
fn shortcut_capture(app: AppHandle, capture: State<'_, Capture>, start: bool) -> Result<(), String> {
    if start {
        let _ = app.global_shortcut().unregister_all();
        if let Ok(mut slot) = capture.menu.lock() { if slot.is_none() { *slot = app.remove_menu().map_err(|e| e.to_string())?; } }
    } else {
        if let Ok(mut slot) = capture.menu.lock() { if let Some(menu) = slot.take() { let _ = app.set_menu(menu); } }
        let current = app.state::<SettingsStore>().current.lock().map(|s| s.clone()).map_err(|e| e.to_string())?;
        let _ = register_shortcut(&app, &current.toggle_shortcut, action_toggle);
        let _ = register_shortcut(&app, &current.quick_add_shortcut, action_quick_add);
        let _ = register_shortcut(&app, &current.settings_shortcut, action_settings);
        let _ = register_shortcut(&app, &current.views_shortcut, action_views);
    }
    Ok(())
}

fn change_shortcut(app: &AppHandle, old: &str, new: &str, action: fn(&AppHandle)) -> Result<(), String> {
    if old == new { return Ok(()); }
    unregister_shortcut(app, old);
    if let Err(error) = register_shortcut(app, new, action) {
        let _ = register_shortcut(app, old, action);
        return Err(error);
    }
    Ok(())
}

#[tauri::command]
async fn open_views(app: AppHandle) -> Result<(), String> { open_views_window(&app); Ok(()) }

#[tauri::command]
async fn open_settings(app: AppHandle) -> Result<(), String> { open_settings_window(&app); Ok(()) }

#[tauri::command]
fn get_settings(app: AppHandle) -> SettingsView { settings_view(&app) }

#[tauri::command]
fn update_settings(app: AppHandle, patch: SettingsPatch) -> Result<SettingsView, String> {
    let store = app.state::<SettingsStore>();
    let mut next = store.current.lock().map_err(|e| e.to_string())?.clone();
    let previous = next.clone();
    if let Some(theme) = patch.theme { apply_theme(&app, &theme)?; next.theme = theme; }
    if let Some(on) = patch.always_on_top {
        if let Some(window) = app.get_webview_window("main") { window.set_always_on_top(on).map_err(|e| e.to_string())?; }
        next.always_on_top = on;
    }
    if let Some(language) = patch.language {
        if !["system", "zh-CN", "zh-TW", "en", "ja"].contains(&language.as_str()) { return Err("无效的语言".into()); }
        apply_language(&app, &language);
        next.language = language;
    }
    if let Some(opacity) = patch.opacity { next.opacity = opacity.clamp(4, 95); }
    if let Some(frost) = patch.frost { next.frost = frost.min(100); set_blur_strength(&app, next.frost); }
    if let Some(on) = patch.hover_expand { next.hover_expand = on; }
    if let Some(on) = patch.show_dock { next.show_dock = on; }
    if let Some(on) = patch.show_menubar { next.show_menubar = on; }
    if patch.show_dock.is_some() || patch.show_menubar.is_some() { apply_presence(&app, next.show_dock, next.show_menubar); }
    if let Some(on) = patch.idle_fade { next.idle_fade = on; }
    if let Some(on) = patch.locked { next.locked = on; }
    if let Some(value) = patch.idle_opacity { next.idle_opacity = value.clamp(20, 95); }
    if let Some(value) = patch.idle_delay_secs { next.idle_delay_secs = value.clamp(1, 60); }
    if let Some(value) = patch.idle_fade_secs { next.idle_fade_secs = value.clamp(1, 10); }
    if let Some(id) = patch.tray_filter {
        if !FILTER_IDS.contains(&id.as_str()) { return Err("无效的筛选器".into()); }
        next.tray_filter = id;
    }
    if let Some(group) = patch.tray_group { next.tray_group = group; }
    if let Some(style) = patch.group_colors {
        if style != "dot" && style != "text" && style != "none" { return Err("无效的分组颜色样式".into()); }
        next.group_colors = style;
    }
    let mut filters_changed = false;
    if let Some(filters) = patch.filters { next.filters = clean_filters(&filters); filters_changed = true; }
    if let Some(id) = patch.default_filter {
        if !FILTER_IDS.contains(&id.as_str()) { return Err("无效的筛选器".into()); }
        next.default_filter = id;
    }
    if let Some(on) = patch.auto_check_updates { next.auto_check_updates = on; if !on { next.auto_install_updates = false; } }
    if let Some(on) = patch.auto_install_updates { next.auto_install_updates = on; if on { next.auto_check_updates = true; } }
    if let Some(version) = patch.skipped_update_version { next.skipped_update_version = version; }
    if let Some(on) = patch.auto_collapse { next.auto_collapse = on; }
    if let Some(secs) = patch.auto_collapse_secs { next.auto_collapse_secs = secs.clamp(1, 600); }
    if let Some(mode) = patch.tray_mode {
        if !TRAY_MODES.contains(&mode.as_str()) { return Err("无效的菜单栏显示方式".into()); }
        next.tray_mode = mode;
    }
    if let Some(secs) = patch.tray_rotate_secs { next.tray_rotate_secs = secs.clamp(2, 60); app.state::<TrayState>().rotate_secs.store(next.tray_rotate_secs as u32, Ordering::SeqCst); }
    let mut clicks_changed = false;
    if let Some(action) = patch.tray_left_click { if !TRAY_ACTIONS.contains(&action.as_str()) { return Err("无效的点击操作".into()); } next.tray_left_click = action; clicks_changed = true; }
    if let Some(action) = patch.tray_right_click { if !TRAY_ACTIONS.contains(&action.as_str()) { return Err("无效的点击操作".into()); } next.tray_right_click = action; clicks_changed = true; }
    if let Some(on) = patch.launch_at_login {
        let manager = app.autolaunch();
        if on { manager.enable() } else { manager.disable() }.map_err(|e| format!("无法更改开机启动：{e}"))?;
    }
    let toggle = patch.toggle_shortcut.unwrap_or_else(|| next.toggle_shortcut.clone());
    let quick = patch.quick_add_shortcut.unwrap_or_else(|| next.quick_add_shortcut.clone());
    let settings_key = patch.settings_shortcut.unwrap_or_else(|| next.settings_shortcut.clone());
    let views_key = patch.views_shortcut.unwrap_or_else(|| next.views_shortcut.clone());
    let chosen = [&toggle, &quick, &settings_key, &views_key];
    for (i, a) in chosen.iter().enumerate() {
        if !a.is_empty() && chosen.iter().enumerate().any(|(j, b)| i != j && a == b) { return Err("不同的动作不能使用同一个快捷键".into()); }
    }
    change_shortcut(&app, &previous.toggle_shortcut, &toggle, action_toggle)?;
    if let Err(error) = change_shortcut(&app, &previous.quick_add_shortcut, &quick, action_quick_add) {
        let _ = change_shortcut(&app, &toggle, &previous.toggle_shortcut, action_toggle);
        return Err(error);
    }
    if let Err(error) = change_shortcut(&app, &previous.settings_shortcut, &settings_key, action_settings) {
        let _ = change_shortcut(&app, &toggle, &previous.toggle_shortcut, action_toggle);
        let _ = change_shortcut(&app, &quick, &previous.quick_add_shortcut, action_quick_add);
        return Err(error);
    }
    if let Err(error) = change_shortcut(&app, &previous.views_shortcut, &views_key, action_views) {
        let _ = change_shortcut(&app, &toggle, &previous.toggle_shortcut, action_toggle);
        let _ = change_shortcut(&app, &quick, &previous.quick_add_shortcut, action_quick_add);
        let _ = change_shortcut(&app, &settings_key, &previous.settings_shortcut, action_settings);
        return Err(error);
    }
    next.views_shortcut = views_key;
    next.toggle_shortcut = toggle;
    next.quick_add_shortcut = quick;
    next.settings_shortcut = settings_key;
    store.save(&next)?;
    *store.current.lock().map_err(|e| e.to_string())? = next;
    if clicks_changed { apply_tray_menu(&app); }
    if filters_changed { refresh_tray_menu(&app); }
    let view = settings_view(&app);
    // Tell every window (the main one keeps pin / hover / theme in sync) what changed.
    let _ = app.emit("dotist://settings-changed", &view);
    Ok(view)
}

/// Shows a known file (the database or the MCP executable) in Finder.
#[tauri::command]
fn reveal_in_finder(path: String) -> Result<(), String> {
    if path != mcp_path() && path != db_path_string() { return Err("不能显示这个位置".into()); }
    std::process::Command::new("open").args(["-R", &path]).status().map_err(|e| e.to_string())?;
    Ok(())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .on_menu_event(|app, event| { match event.id().as_ref() { "app-settings" => open_settings_window(app), "app-views" => open_views_window(app), _ => {} } })
        .manage(updater::Pending::default())
        .manage(Bubble::default())
        .manage(Capture::default())
        .manage(TrayState::default())
        .manage(ViewsPresence::default())
        .invoke_handler(tauri::generate_handler![list_tasks, set_due_date, set_start_date, set_date_range, move_status_task, list_groups, add_group, update_group, move_group, delete_group, restore_group, reparent_task, add_task, patch_task, delete_task, restore_task, move_task, animate_bubble, bubble_target_size, set_bubble_open, set_tray_titles, set_tray_groups, reset_window_size, get_settings, update_settings, open_settings, open_views, quick_done, shortcut_capture, reveal_in_finder, updater::check_for_update, updater::install_update, updater::pending_update])
        .on_window_event(|window, event| {
            if window.label() == "views" && matches!(event, WindowEvent::Destroyed) {
                let app = window.app_handle();
                app.state::<ViewsPresence>().0.store(false, Ordering::SeqCst);
                if let Ok(settings) = app.state::<SettingsStore>().current.lock() { apply_presence(app, settings.show_dock, settings.show_menubar); }
            }
            if let WindowEvent::Resized(_) = event {
                if window.label() == "main" {
                    let bubble = window.app_handle().state::<Bubble>();
                    let generation = bubble.resize_generation.fetch_add(1, Ordering::SeqCst) + 1;
                    if !bubble.active.load(Ordering::SeqCst) && !bubble.animating.load(Ordering::SeqCst) {
                        if let Some(webview) = window.app_handle().get_webview_window("main") { remember_size(window.app_handle(), &webview, generation); }
                    }
                }
            }
            if let WindowEvent::Focused(false) = event {
                if window.label() == "quick" { let _ = window.hide(); }
            }
            if let WindowEvent::Moved(_) = event {
                if window.label() == "main" && window.app_handle().state::<Bubble>().active.load(Ordering::SeqCst) {
                    if let Some(webview) = window.app_handle().get_webview_window("main") { schedule_snap(webview); }
                }
            }
        })
        .setup(|app| {
            let store = Store::open(&database_path()?)?;
            app.manage(Mutex::new(store));
            let settings_path = database_path()?.with_file_name("settings.json");
            app.manage(SettingsStore::load(settings_path));
            updater::start(app.handle().clone());
            let startup_lang = resolve_language(&app.state::<SettingsStore>().current.lock().unwrap().language);
            // The standard macOS menu bar while Dotist is in front: Settings… on Cmd+, and working Edit commands
            // (copy / paste in the text fields). Cmd+, is therefore never registered as a global shortcut.
            let app_settings = MenuItem::with_id(app, "app-settings", native_text(startup_lang, "settings"), true, Some("CmdOrCtrl+,"))?;
            let app_views = MenuItem::with_id(app, "app-views", native_text(startup_lang, "views"), true, Some("CmdOrCtrl+Shift+V"))?;
            let app_menu = SubmenuBuilder::new(app, "Dotist").about(None).separator().item(&app_settings).item(&app_views).separator().hide().hide_others().show_all().separator().quit().build()?;
            let edit_menu = SubmenuBuilder::new(app, "Edit").undo().redo().separator().cut().copy().paste().select_all().build()?;
            let window_menu = SubmenuBuilder::new(app, "Window").minimize().close_window().build()?;
            app.set_menu(MenuBuilder::new(app).items(&[&app_menu, &edit_menu, &window_menu]).build()?)?;
            *app.state::<TrayState>().app_settings.lock().unwrap() = Some(app_settings.clone());
            *app.state::<TrayState>().app_views.lock().unwrap() = Some(app_views);
            let startup_filters = app.state::<SettingsStore>().current.lock().unwrap().filters.clone();
            let menu = build_tray_menu(app.handle(), startup_lang, &[], &startup_filters)?;
            *app.state::<TrayState>().menu.lock().unwrap() = Some(menu.clone());
            let icon = Image::from_bytes(include_bytes!("../icons/tray/menubar@2x.png"))?;
            let tray = TrayIconBuilder::new()
                .icon(icon)
                .icon_as_template(true)
                .menu(&menu)
                .show_menu_on_left_click(false)
                .tooltip("Dotist")
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button, button_state: MouseButtonState::Up, .. } = event {
                        let app = tray.app_handle();
                        let action = app.state::<SettingsStore>().current.lock().map(|s| if button == MouseButton::Right { s.tray_right_click.clone() } else { s.tray_left_click.clone() }).unwrap_or_default();
                        if button == MouseButton::Left || button == MouseButton::Right { run_tray_action(app, &action); }
                        if button == MouseButton::Right && action != "menu" { clear_tray_highlight(tray); }
                    }
                })
                .on_menu_event(move |app, event| match event.id.as_ref() {
                    "show" => expand_main(app),
                    "collapse" => { show_main(app); if !app.state::<Bubble>().active.load(Ordering::SeqCst) { let _ = app.emit("dotist://collapse", ()); } }
                    "settings" => open_settings_window(app),
                    "views" => open_views_window(app),
                    "quick" => open_quick_window(app),
                    "quit" => app.exit(0),
                    other => {
                        if let Some(id) = other.strip_prefix("filter:") { goto(app, Some(id), None); }
                        else if let Some(id) = other.strip_prefix("group:") { goto(app, None, Some(id)); }
                    }
                })
                .build(app)?;
            *app.state::<TrayState>().icon.lock().unwrap() = Some(tray);
            {
                let handle = app.handle().clone();
                let loaded = app.state::<SettingsStore>().current.lock().unwrap().clone();
                if let Err(error) = apply_theme(&handle, &loaded.theme) { eprintln!("{error}"); }
                apply_presence(&handle, loaded.show_dock, loaded.show_menubar);
                set_blur_strength(&handle, loaded.frost);
                if let Some(window) = handle.get_webview_window("main") { refresh_shadow(&window); }
                if let Some(window) = app.get_webview_window("main") { let _ = window.set_always_on_top(loaded.always_on_top); }
                handle.state::<TrayState>().rotate_secs.store(loaded.tray_rotate_secs as u32, Ordering::SeqCst);
                apply_tray_menu(&handle);
                if let Err(error) = register_shortcut(&handle, &loaded.toggle_shortcut, action_toggle) { eprintln!("{error}"); }
                if let Err(error) = register_shortcut(&handle, &loaded.quick_add_shortcut, action_quick_add) { eprintln!("{error}"); }
                if let Err(error) = register_shortcut(&handle, &loaded.settings_shortcut, action_settings) { eprintln!("{error}"); }
                if let Err(error) = register_shortcut(&handle, &loaded.views_shortcut, action_views) { eprintln!("{error}"); }
            }
            // With several titles the menu bar item cycles through them every few seconds.
            {
                let handle = app.handle().clone();
                std::thread::spawn(move || {
                    let mut waited = 0u32;
                    loop {
                        std::thread::sleep(std::time::Duration::from_secs(1));
                        let state = handle.state::<TrayState>();
                        let count = state.titles.lock().map(|t| t.len()).unwrap_or(0);
                        if count < 2 { waited = 0; continue; }
                        waited += 1;
                        if waited >= state.rotate_secs.load(Ordering::SeqCst).max(2) {
                            waited = 0;
                            state.index.store((state.index.load(Ordering::SeqCst) + 1) % count as u32, Ordering::SeqCst);
                            refresh_tray_title(&state);
                        }
                    }
                });
            }
            // The webview gets no hover events while the app is not frontmost, so the pointer is tracked natively:
            // whether it is over the main window (or the bubble) is pushed to the page whenever it changes.
            {
                let handle = app.handle().clone();
                std::thread::spawn(move || {
                    let mut last: Option<bool> = None;
                    let mut alpha = 1.0_f64;
                    let mut in_use_at = std::time::Instant::now();
                    let mut last_pos: Option<(i32, i32)> = None;
                    let mut still_since = std::time::Instant::now();
                    let mut strays_checked = false;
                    loop {
                        std::thread::sleep(std::time::Duration::from_millis(60));
                        let Some(window) = handle.get_webview_window("main") else { continue };
                        if !window.is_visible().unwrap_or(false) { last = None; continue; }
                        let (Ok(cursor), Ok(pos), Ok(size)) = (window.cursor_position(), window.outer_position(), window.outer_size()) else { continue };
                        let inside = cursor.x >= pos.x as f64 && cursor.x < pos.x as f64 + size.width as f64 && cursor.y >= pos.y as f64 && cursor.y < pos.y as f64 + size.height as f64;
                        if last != Some(inside) { last = Some(inside); let _ = handle.emit("dotist://pointer", inside); }
                        {
                            // Safety net: a bubble that ends up partly off screen is pulled back once it stops moving.
                            let bubble = handle.state::<Bubble>();
                            if bubble.active.load(Ordering::SeqCst) && !bubble.animating.load(Ordering::SeqCst) {
                                if last_pos != Some((pos.x, pos.y)) { last_pos = Some((pos.x, pos.y)); still_since = std::time::Instant::now(); strays_checked = false; }
                                if still_since.elapsed() > std::time::Duration::from_millis(700) && !strays_checked {
                                    strays_checked = true;
                                    if let Ok((ap, asz, _)) = work_area(&window) {
                                        let off = pos.x < ap.x || pos.y < ap.y || pos.x + size.width as i32 > ap.x + asz.width as i32 || pos.y + size.height as i32 > ap.y + asz.height as i32;
                                        if off { schedule_snap(window.clone()); }
                                    }
                                }
                            }
                        }
                        // Idle fade: after a moment without the pointer or focus the window recedes; it returns at once when used.
                        let (fade, idle, delay, secs) = handle.state::<SettingsStore>().current.lock().map(|s| (s.idle_fade && !s.locked, s.idle_opacity as f64 / 100.0, s.idle_delay_secs as u64, s.idle_fade_secs as f64)).unwrap_or((false, 1.0, 5, 2.0));
                        // The floating bubble never fades: it is small and must stay easy to find.
                        let busy = inside || window.is_focused().unwrap_or(false) || handle.state::<Bubble>().animating.load(Ordering::SeqCst) || handle.state::<Bubble>().active.load(Ordering::SeqCst);
                        if busy { in_use_at = std::time::Instant::now(); }
                        let target = if fade && !busy && in_use_at.elapsed() > std::time::Duration::from_secs(delay) { idle } else { 1.0 };
                        if (alpha - target).abs() > 0.004 {
                            // Fading out takes the configured time; coming back is quick.
                            let step_out = ((1.0 - idle).max(0.05) * 0.06 / secs.max(1.0)).max(0.0005);
                            alpha += (target - alpha).clamp(-step_out, 0.16);
                            set_window_alpha(&window, alpha);
                            if let Some(shadow) = handle.get_webview_window("shadow") { set_window_alpha(&shadow, alpha); }
                        }
                    }
                });
            }
            if let Some(window) = app.get_webview_window("main") {
                let (width, height) = persisted_size(app.handle());
                if (width, height) != DEFAULT_SIZE { let _ = window.set_size(LogicalSize::new(width, height)); }
                refresh_shadow(&window);
                disallow_tiling(&window);
                if let Some(monitor) = window.primary_monitor()? {
                    let area = monitor.work_area();
                    // The size just set may not be reported back yet, so place by the size it was set to.
                    let scale = monitor.scale_factor();
                    let size = PhysicalSize::new((width * scale).round() as u32, (height * scale).round() as u32);
                    let inset = (16.0 * scale) as i32;
                    let x = area.position.x + (area.size.width as i32 - size.width as i32 - inset).max(0);
                    let y = area.position.y + inset;
                    window.set_position(PhysicalPosition::new(x, y))?;
                }
            }
            create_shadow_window(app.handle());
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("启动 Dotist 失败")
        .run(|app, event| {
            if matches!(event, tauri::RunEvent::Exit) { updater::install_on_exit(app); }
            #[cfg(target_os = "macos")]
            // Clicking the Dock icon must not disturb what is already on screen (bubble, capsule, window, quick add);
            // it only brings the window back when it was hidden.
            if let tauri::RunEvent::Reopen { .. } = event {
                if app.get_webview_window("main").map(|w| !w.is_visible().unwrap_or(true)).unwrap_or(false) { show_main(app); }
            }
            #[cfg(not(target_os = "macos"))]
            let _ = (app, event);
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn views_window_forces_dock_until_destroyed() {
        assert!(!effective_dock(false, false));
        assert!(effective_dock(false, true));
        assert!(effective_dock(true, false));
        assert!(effective_dock(true, true));
    }

    #[test]
    fn cmd_comma_is_recognised_however_it_is_spelled() {
        let builtin: Shortcut = "Command+Comma".parse().unwrap();
        for spelling in ["Command+Comma", "CommandOrControl+Comma", "Cmd+Comma", "Super+Comma"] {
            let parsed: Shortcut = spelling.parse().unwrap();
            assert_eq!(Some(parsed), Some(builtin), "{spelling}");
        }
        assert_ne!("Command+Alt+Comma".parse::<Shortcut>().unwrap(), builtin);
    }

    #[test]
    fn language_resolution_follows_the_setting_and_maps_chinese_variants() {
        assert_eq!(resolve_language("en"), "en");
        assert_eq!(resolve_language("zh-TW"), "zh-TW");
        assert_eq!(resolve_language("zh-CN"), "zh-CN");
        assert_eq!(resolve_language("ja"), "ja");
        assert_eq!(native_text("en", "quit"), "Quit Dotist");
        assert_eq!(native_text("ja", "settings"), "設定…");
        assert_eq!(native_text("zh-CN", "show"), "显示窗口");
    }
}
