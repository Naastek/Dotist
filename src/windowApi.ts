import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { isDemo } from './taskApi';

/** `?demo&bubble` starts the browser preview directly in the floating-bubble state. */
export const startInBubble = isDemo && new URLSearchParams(window.location.search).has('bubble');

/** Old movement-idle notifications are not proof that the button was released. */
export function isDragRelease(payload: unknown): boolean {
  return typeof payload === 'object' && payload !== null && 'released' in payload && payload.released === true;
}

export type ResizeDirection = 'North' | 'South' | 'East' | 'West' | 'NorthEast' | 'NorthWest' | 'SouthEast' | 'SouthWest';

export const windowApi = {
  /** Animates the native window (with its glass) into / out of the bubble, anchored at the collapse button. */
  async animateBubble(bubble: boolean, durationMs: number) {
    if (isDemo) await new Promise(resolve => setTimeout(resolve, durationMs));
    else await invoke('animate_bubble', { bubbleMode: bubble, durationMs });
  },
  /** Logical size the window grows back to (default 364x620). */
  async bubbleTargetSize(): Promise<[number, number]> { return isDemo ? [364, 620] : invoke<[number, number]>('bubble_target_size'); },
  async setBubbleOpen(open: boolean, width?: number, durationMs?: number) { if (!isDemo) await invoke('set_bubble_open', { open, width, durationMs }); },
  /** Opens the separate settings window (the main window has no settings button). */
  async openSettings() { if (!isDemo) await invoke('open_settings'); },
  async openViews() { if (!isDemo) await invoke('open_views'); },
  /** What the menu bar item says; several entries cycle every few seconds. */
  async setTrayTitles(titles: string[]) { if (!isDemo) await invoke('set_tray_titles', { titles }); },
  /** The groups listed in the menu bar menu's groups submenu. */
  async setTrayGroups(groups: [string, string][]) { if (!isDemo) await invoke('set_tray_groups', { groups }); },
  /** Starts a native edge/corner resize of the main window (the window has no frame, so the page draws the handles). */
  async startResize(direction: ResizeDirection) { if (!isDemo) await getCurrentWindow().startResizeDragging(direction); },
  async resetWindowSize() { if (!isDemo) await invoke('reset_window_size'); },
  /** Pauses global shortcuts and the menu bar's key equivalents while a shortcut is being recorded. */
  async captureShortcuts(start: boolean) { if (!isDemo) await invoke('shortcut_capture', { start }); },
  async quickDone(added: boolean) { if (!isDemo) await invoke('quick_done', { added }); },
  async startDragging() {
    if (isDemo) return;
    await invoke('start_window_drag');
  },
  async dragPointer(pressed: boolean) { if (!isDemo) await invoke('window_drag_pointer', { pressed }); },
  async on<T = undefined>(event: 'collapse' | 'expand' | 'focus-composer' | 'settings-changed' | 'pointer' | 'drag-start' | 'drag-end' | 'shadow-radius' | 'tasks-changed' | 'quick-show' | 'goto', handler: (payload: T) => void): Promise<() => void> {
    if (isDemo) return () => {};
    return listen<T>(`dotist://${event}`, message => handler(message.payload));
  },
};
