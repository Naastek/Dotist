import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import type { LangSetting } from './i18n';
import { isDemo } from './taskApi';

export type Theme = 'system' | 'light' | 'dark';
export type GroupColors = 'dot' | 'text' | 'none';
export type TrayMode = 'icon' | 'count' | 'next' | 'next_date' | 'rotate';
export type TrayAction = 'toggle' | 'bubble' | 'quick' | 'settings' | 'show' | 'menu' | 'none';
export type FilterId = 'today' | 'all' | 'tomorrow' | 'week' | 'nextweek' | 'next7' | 'overdue' | 'undated' | 'done';
export const FILTER_LABELS: Record<FilterId, string> = { today: '今天', all: '全部', tomorrow: '明天', week: '本周', nextweek: '下周', next7: '未来 7 天', overdue: '已逾期', undated: '无日期', done: '已完成' };
export const ALL_FILTERS: FilterId[] = ['today', 'all', 'tomorrow', 'week', 'nextweek', 'next7', 'overdue', 'undated', 'done'];
export interface SettingsView {
  theme: Theme;
  language: LangSetting;
  opacity: number;
  frost: number;
  toggle_shortcut: string;
  quick_add_shortcut: string;
  settings_shortcut: string;
  views_shortcut: string;
  tray_mode: TrayMode;
  tray_rotate_secs: number;
  tray_left_click: TrayAction;
  tray_right_click: TrayAction;
  idle_fade: boolean;
  locked: boolean;
  idle_opacity: number;
  idle_delay_secs: number;
  idle_fade_secs: number;
  tray_filter: FilterId;
  tray_group: string;
  group_colors: GroupColors;
  filters: FilterId[];
  default_filter: FilterId;
  always_on_top: boolean;
  hover_expand: boolean;
  show_dock: boolean;
  show_menubar: boolean;
  auto_collapse: boolean;
  auto_collapse_secs: number;
  auto_check_updates: boolean;
  auto_install_updates: boolean;
  skipped_update_version: string;
  last_update_error: string;
  launch_at_login: boolean;
  mcp_path: string;
  db_path: string;
  version: string;
}
export type SettingsPatch = Partial<Omit<SettingsView, 'mcp_path' | 'db_path' | 'version' | 'last_update_error'>>;

export type UpdateResult = { status: 'unconfigured' | 'up_to_date' | 'available' | 'downloaded' | 'error'; version?: string; notes?: string; message?: string };
export type UpdateProgress = { downloaded: number; total?: number | null };

interface SettingsApi {
  get(): Promise<SettingsView>;
  update(patch: SettingsPatch): Promise<SettingsView>;
  reveal(path: string): Promise<void>;
  checkUpdate(): Promise<UpdateResult>;
  installUpdate(): Promise<void>;
  pendingUpdate(): Promise<UpdateResult | null>;
  onUpdate(handler: (update: UpdateResult) => void): Promise<() => void>;
  onProgress(handler: (progress: UpdateProgress) => void): Promise<() => void>;
}

const localApi: SettingsApi = {
  get: () => invoke('get_settings'),
  update: patch => invoke('update_settings', { patch }),
  reveal: async path => { await invoke('reveal_in_finder', { path }); },
  checkUpdate: () => invoke('check_for_update'),
  installUpdate: () => invoke('install_update'),
  pendingUpdate: () => invoke('pending_update'),
  onUpdate: handler => listen<UpdateResult>('update-available', event => handler(event.payload)),
  onProgress: handler => listen<UpdateProgress>('update-progress', event => handler(event.payload)),
};

function createDemoApi(): SettingsApi {
  let state: SettingsView = { theme: 'system', language: 'zh-CN', opacity: 56, frost: 35, toggle_shortcut: 'CommandOrControl+Alt+D', quick_add_shortcut: 'CommandOrControl+Alt+N', settings_shortcut: 'CommandOrControl+Alt+Comma', views_shortcut: '', tray_mode: 'icon', tray_rotate_secs: 4, tray_left_click: 'toggle', tray_right_click: 'menu', idle_fade: true, locked: false, idle_opacity: 55, idle_delay_secs: 5, idle_fade_secs: 2, tray_filter: 'all', tray_group: 'all', group_colors: 'dot', filters: [...ALL_FILTERS], default_filter: 'all', always_on_top: true, hover_expand: true, show_dock: true, show_menubar: true, auto_collapse: true, auto_collapse_secs: 20, auto_check_updates: true, auto_install_updates: false, skipped_update_version: '', last_update_error: '', launch_at_login: false,
    mcp_path: '/Applications/Dotist.app/Contents/MacOS/dotist-mcp', db_path: '~/Library/Application Support/com.dotist.app/tasks.sqlite', version: '0.1.0' };
  return { get: async () => ({ ...state }), update: async patch => { state = { ...state, ...patch }; return { ...state }; }, reveal: async () => {}, checkUpdate: async () => { const mode = new URLSearchParams(window.location.search).get('update'); return mode === 'available' ? { status: 'available', version: '0.2.0', notes: 'Bug fixes and improvements.' } : { status: mode === 'unconfigured' ? 'unconfigured' : 'up_to_date' }; }, installUpdate: async () => { throw new Error('Demo'); }, pendingUpdate: async () => { const mode = new URLSearchParams(window.location.search).get('update'); return mode === 'available' ? { status: 'available', version: '0.2.0', notes: 'Bug fixes and improvements.' } : mode === 'unconfigured' ? { status: 'unconfigured' } : null; }, onUpdate: async () => () => {}, onProgress: async () => () => {} };
}

export const settingsApi: SettingsApi = isDemo ? createDemoApi() : localApi;

/** "system" removes the override so prefers-color-scheme decides; light/dark force the token set. */
export function applyTheme(theme: Theme) {
  if (theme === 'system') document.documentElement.removeAttribute('data-theme');
  else document.documentElement.setAttribute('data-theme', theme);
}

export const MIN_OPACITY = 4;
export const MAX_OPACITY = 95;

/**
 * Tint strength and frosted haze, 0-100 each. The tint never goes below 10% (never fully clear) or above 95%.
 * A low tint switches on the clear-glass rim and sheen.
 */
export function applyGlass(opacityIn: number, frostIn: number) {
  const root = document.documentElement;
  const opacity = Math.min(MAX_OPACITY, Math.max(MIN_OPACITY, opacityIn));
  const frost = Math.min(100, Math.max(0, frostIn));
  const alpha = opacity / 100;
  root.style.setProperty('--tint-alpha', String(alpha));
  root.style.setProperty('--frost', String(frost / 100));
  // How much help the content needs: the less tint and haze sit behind it, the more the text, icons and controls
  // are reinforced (halo, firmer surfaces, darker secondary text).
  // The system blur is always at full strength; tint and haze are what hide the desktop.
  const covered = alpha + (1 - alpha) * (0.2 + 0.25 * (frost / 100));
  const need = Math.min(1, Math.max(0, 1 - covered));
  root.style.setProperty('--lg', need.toFixed(3));
  root.setAttribute('data-lg', need > 0.7 ? 'high' : need > 0.45 ? 'mid' : 'low');
  if (opacity <= 35) root.setAttribute('data-glass', 'clear'); else root.removeAttribute('data-glass');
}

/**
 * The slider shows transparency, curved so the first half of the travel changes the glass gently and only the far end
 * gets really clear: 0% is the most opaque tint, 100% the most see-through that is still glass.
 */
const CURVE = 1.5;
export const transparencyOf = (opacity: number) => Math.round(100 * Math.pow(Math.min(1, Math.max(0, (MAX_OPACITY - opacity) / (MAX_OPACITY - MIN_OPACITY))), 1 / CURVE));
export const opacityFromTransparency = (transparency: number) => Math.round(MAX_OPACITY - (MAX_OPACITY - MIN_OPACITY) * Math.pow(transparency / 100, CURVE));

export const GLASS_PRESETS = { standard: { opacity: 60, frost: 40 }, clear: { opacity: 38, frost: 22 }, crystal: { opacity: 8, frost: 4 } } as const;

/** How a group's colour is shown: a small dot (default), the coloured name, or nothing. */
export function applyGroupColors(style: GroupColors) { document.documentElement.setAttribute('data-group-colors', style); }
