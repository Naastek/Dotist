import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';

let App: typeof import('../src/App').App;
let SettingsWindow: typeof import('../src/Settings').SettingsWindow;
let settingsApi: typeof import('../src/settingsApi').settingsApi;

beforeEach(async () => {
  vi.resetModules();
  window.history.pushState({}, '', '/?demo');
  const root = document.documentElement;
  root.removeAttribute('data-theme'); root.removeAttribute('data-glass');
  root.style.removeProperty('--tint-alpha'); root.style.removeProperty('--frost');
  ({ App } = await import('../src/App'));
  ({ SettingsWindow } = await import('../src/Settings'));
  ({ settingsApi } = await import('../src/settingsApi'));
  const { setLanguage } = await import('../src/i18n');
  setLanguage('zh-CN');
});
afterEach(cleanup);

async function openSettings() {
  render(<SettingsWindow />);
  await screen.findByRole('radiogroup', { name: '主题' });
}

it('is one scrolling page: every section is there at once, the sidebar jumps to a section and follows the scroll', async () => {
  await openSettings();
  const tabs = screen.getByRole('tablist', { name: '设置' });
  expect(within(tabs).getAllByRole('tab').map(tab => tab.textContent)).toEqual(['外观', '通用', '筛选器', '菜单栏', '快捷键', 'MCP', '数据与关于']);
  expect(within(tabs).queryByRole('tab', { name: '全部' })).toBeNull();
  for (const title of ['外观', '通用', '筛选器', '菜单栏', '快捷键', 'MCP', '数据与关于']) expect(screen.getByRole('region', { name: title })).toBeTruthy();
  const jump = vi.fn();
  Element.prototype.scrollIntoView = jump;
  fireEvent.click(within(tabs).getByRole('tab', { name: '快捷键' }));
  expect(jump).toHaveBeenCalled();
  expect(within(tabs).getByRole('tab', { name: '快捷键' }).getAttribute('aria-selected')).toBe('true');
  expect(screen.getByRole('button', { name: '打开设置快捷键' })).toBeTruthy();
});

it('the main window has no settings button; Cmd+comma asks the app to open the settings window', async () => {
  const { windowApi } = await import('../src/windowApi');
  const open = vi.spyOn(windowApi, 'openSettings').mockResolvedValue();
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  expect(screen.queryByRole('button', { name: '设置' })).toBeNull();
  fireEvent.keyDown(window, { key: ',', metaKey: true });
  expect(open).toHaveBeenCalledTimes(1);
});

it('switches the theme and applies it to the document', async () => {
  await openSettings();
  fireEvent.click(screen.getByRole('radio', { name: '深色' }));
  await waitFor(() => expect(document.documentElement.getAttribute('data-theme')).toBe('dark'));
  await waitFor(async () => expect((await settingsApi.get()).theme).toBe('dark'));
  fireEvent.click(within(screen.getByRole('radiogroup', { name: '主题' })).getByRole('radio', { name: '跟随系统' }));
  await waitFor(() => expect(document.documentElement.hasAttribute('data-theme')).toBe(false));
});

it('glass sliders cover the full range and never go fully clear: 100% transparency still keeps a tint', async () => {
  await openSettings();
  const transparency = screen.getByRole('slider', { name: '透明程度' });
  fireEvent.change(transparency, { target: { value: '100' } });
  await waitFor(() => expect(document.documentElement.style.getPropertyValue('--tint-alpha')).toBe('0.04'));
  expect(document.documentElement.getAttribute('data-glass')).toBe('clear');
  fireEvent.change(transparency, { target: { value: '0' } });
  await waitFor(() => expect(document.documentElement.style.getPropertyValue('--tint-alpha')).toBe('0.95'));
  expect(document.documentElement.hasAttribute('data-glass')).toBe(false);
  const frost = screen.getByRole('slider', { name: '磨砂程度' });
  fireEvent.change(frost, { target: { value: '100' } });
  await waitFor(() => expect(document.documentElement.style.getPropertyValue('--frost')).toBe('1'));
  fireEvent.change(frost, { target: { value: '0' } });
  await waitFor(() => expect(document.documentElement.style.getPropertyValue('--frost')).toBe('0'));
  await waitFor(async () => expect(await settingsApi.get()).toMatchObject({ opacity: 95, frost: 0 }));
});

it('old saved extremes (tint 0, frost 0) are clamped when applied, so the window is never fully clear', async () => {
  const { applyGlass } = await import('../src/settingsApi');
  applyGlass(0, 0);
  expect(document.documentElement.style.getPropertyValue('--tint-alpha')).toBe('0.04');
  applyGlass(500, 900);
  expect(document.documentElement.style.getPropertyValue('--tint-alpha')).toBe('0.95');
  expect(document.documentElement.style.getPropertyValue('--frost')).toBe('1');
});

it('dragging a slider quickly ends on the value it shows (updates are merged, none dropped)', async () => {
  await openSettings();
  const frost = screen.getByRole('slider', { name: '磨砂程度' });
  for (const value of ['10', '30', '55', '80', '100']) fireEvent.change(frost, { target: { value } });
  await waitFor(async () => expect((await settingsApi.get()).frost).toBe(100));
  expect((screen.getByRole('slider', { name: '磨砂程度' }) as HTMLInputElement).value).toBe('100');
});

it('legibility help grows as the window gets more see-through, and eases off when it is solid', async () => {
  await openSettings();
  const lg = () => Number(document.documentElement.style.getPropertyValue('--lg'));
  const tier = () => document.documentElement.getAttribute('data-lg');
  fireEvent.change(screen.getByRole('slider', { name: '磨砂程度' }), { target: { value: '0' } });
  fireEvent.change(screen.getByRole('slider', { name: '透明程度' }), { target: { value: '100' } });
  await waitFor(() => expect(tier()).toBe('high'));
  const clear = lg();
  expect(clear).toBeGreaterThan(0.7);
  fireEvent.change(screen.getByRole('slider', { name: '磨砂程度' }), { target: { value: '100' } });
  await waitFor(() => expect(lg()).toBeLessThan(clear));
  fireEvent.change(screen.getByRole('slider', { name: '透明程度' }), { target: { value: '50' } });
  await waitFor(() => expect(tier()).toBe('low'));
  fireEvent.change(screen.getByRole('slider', { name: '透明程度' }), { target: { value: '0' } });
  await waitFor(() => expect(lg()).toBeLessThan(0.1));
});

it('filters: choose which show, drag to reorder, and pick the one opened at launch', async () => {
  await openSettings();
  const list = screen.getByRole('list', { name: '筛选器' });
  const names = () => within(list).getAllByRole('listitem').map(row => row.querySelector('.dt-filter-name')?.textContent);
  expect(names().slice(0, 3)).toEqual(['今天', '全部', '明天']);
  // jsdom has no layout: the list starts at y = 100 and rows are 40px tall.
  list.getBoundingClientRect = () => ({ top: 100, left: 0, right: 200, bottom: 460, width: 200, height: 360, x: 0, y: 100, toJSON() {} }) as DOMRect;
  const grip = within(list).getByRole('button', { name: '拖动排序 今天' });
  fireEvent.pointerDown(grip, { clientY: 120, pointerId: 1, button: 0 });
  fireEvent.pointerMove(grip, { clientY: 200, pointerId: 1 });
  expect(names().slice(0, 3)).toEqual(['全部', '明天', '今天']);
  expect(within(list).getAllByRole('listitem')[2].className).toContain('is-dragging');
  fireEvent.pointerUp(grip, { clientY: 200, pointerId: 1 });
  await waitFor(async () => expect((await settingsApi.get()).filters.slice(0, 3)).toEqual(['all', 'tomorrow', 'today']));
  fireEvent.pointerDown(within(list).getByRole('button', { name: '拖动排序 今天' }), { clientY: 220, pointerId: 1, button: 0 });
  fireEvent.pointerMove(within(list).getByRole('button', { name: '拖动排序 今天' }), { clientY: 20, pointerId: 1 });
  expect(names()[0]).toBe('今天');
  fireEvent.pointerCancel(within(list).getByRole('button', { name: '拖动排序 今天' }), { pointerId: 1 });
  expect(names().slice(0, 3)).toEqual(['全部', '明天', '今天']);
  fireEvent.keyDown(within(list).getByRole('button', { name: '拖动排序 今天' }), { key: 'ArrowUp' });
  await waitFor(() => expect(names().slice(0, 3)).toEqual(['全部', '今天', '明天']));
  fireEvent.click(within(list).getByRole('switch', { name: '显示 明天' }));
  await waitFor(async () => expect((await settingsApi.get()).filters).not.toContain('tomorrow'));
  expect(names()[names().length - 1]).toBe('明天');
  fireEvent.click(within(list).getByRole('switch', { name: '显示 明天' }));
  await waitFor(async () => expect((await settingsApi.get()).filters.at(-1)).toBe('tomorrow'));
  fireEvent.click(screen.getByRole('button', { name: '启动时打开' }));
  fireEvent.click(screen.getByRole('menuitem', { name: '已逾期' }));
  await waitFor(async () => expect((await settingsApi.get()).default_filter).toBe('overdue'));
});

it('menu bar: what it shows, the rotation interval, and independent left / right click actions', async () => {
  await openSettings();
  expect(screen.queryByRole('slider', { name: '轮播间隔' })).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: '显示内容' }));
  fireEvent.click(screen.getByRole('menuitem', { name: /轮播/ }));
  await screen.findByRole('slider', { name: '轮播间隔' });
  fireEvent.change(screen.getByRole('slider', { name: '轮播间隔' }), { target: { value: '9' } });
  await waitFor(async () => expect(await settingsApi.get()).toMatchObject({ tray_mode: 'rotate', tray_rotate_secs: 9 }));
  fireEvent.click(screen.getByRole('button', { name: '日期透视' }));
  fireEvent.click(screen.getByRole('menuitem', { name: '已逾期' }));
  fireEvent.click(await screen.findByRole('button', { name: '分组' }));
  fireEvent.click(screen.getByRole('menuitem', { name: '生活' }));
  await waitFor(async () => expect(await settingsApi.get()).toMatchObject({ tray_filter: 'overdue', tray_group: 'life' }));
  fireEvent.click(screen.getByRole('button', { name: '左键点击' }));
  fireEvent.click(screen.getByRole('menuitem', { name: '快速添加' }));
  fireEvent.click(screen.getByRole('button', { name: '右键点击' }));
  fireEvent.click(screen.getByRole('menuitem', { name: '打开设置' }));
  await waitFor(async () => expect(await settingsApi.get()).toMatchObject({ tray_left_click: 'quick', tray_right_click: 'settings' }));
  expect(screen.getByText('没有一键打开菜单时，可用 Dock 图标或 ⌘Q 退出 Dotist')).toBeTruthy();
  // Left and right are independent: even with the menu on the left, the right click can be set to something else.
  fireEvent.click(screen.getByRole('button', { name: '左键点击' }));
  fireEvent.click(screen.getByRole('menuitem', { name: '打开菜单' }));
  await waitFor(async () => expect((await settingsApi.get()).tray_left_click).toBe('menu'));
  const right = screen.getByRole('button', { name: '右键点击' }) as HTMLButtonElement;
  expect(right.disabled).toBe(false);
  expect(right.textContent).toBe('打开设置');
  fireEvent.click(right);
  fireEvent.click(screen.getByRole('menuitem', { name: '快速添加' }));
  await waitFor(async () => expect(await settingsApi.get()).toMatchObject({ tray_left_click: 'menu', tray_right_click: 'quick' }));
  fireEvent.click(screen.getByRole('button', { name: '右键点击' }));
  fireEvent.click(screen.getByRole('menuitem', { name: '打开菜单' }));
  await waitFor(async () => expect(await settingsApi.get()).toMatchObject({ tray_left_click: 'menu', tray_right_click: 'menu' }));
});

it('the transparency slider is curved: the first half changes the glass gently, the far end gets clear', async () => {
  const { opacityFromTransparency, transparencyOf } = await import('../src/settingsApi');
  expect(opacityFromTransparency(0)).toBe(95);
  expect(opacityFromTransparency(100)).toBe(4);
  expect(opacityFromTransparency(50)).toBeGreaterThan(60);
  expect(95 - opacityFromTransparency(50)).toBeLessThan((95 - 4) / 2);
  for (const t of [0, 10, 25, 50, 75, 90, 100]) expect(Math.abs(transparencyOf(opacityFromTransparency(t)) - t)).toBeLessThanOrEqual(2);
  const steps = Array.from({ length: 11 }, (_, i) => opacityFromTransparency(i * 10));
  expect(steps).toEqual([...steps].sort((a, b) => b - a));
});

it('the group color style is a setting: dot by default, coloured names or none', async () => {
  const { applyGroupColors } = await import('../src/settingsApi');
  applyGroupColors('dot');
  expect(document.documentElement.getAttribute('data-group-colors')).toBe('dot');
  await openSettings();
  fireEvent.click(screen.getByRole('button', { name: '分组颜色' }));
  fireEvent.click(screen.getByRole('menuitem', { name: '彩色名称' }));
  await waitFor(() => expect(document.documentElement.getAttribute('data-group-colors')).toBe('text'));
  await waitFor(async () => expect((await settingsApi.get()).group_colors).toBe('text'));
});

it('idle fade: delay and duration are settings, so it does not start the instant the pointer leaves', async () => {
  await openSettings();
  const delay = screen.getByRole('slider', { name: '淡出前等待' }) as HTMLInputElement;
  expect([delay.min, delay.max, delay.value]).toEqual(['1', '60', '5']);
  fireEvent.change(delay, { target: { value: '20' } });
  fireEvent.change(screen.getByRole('slider', { name: '淡出用时' }), { target: { value: '6' } });
  await waitFor(async () => expect(await settingsApi.get()).toMatchObject({ idle_delay_secs: 20, idle_fade_secs: 6 }));
  fireEvent.click(screen.getByRole('switch', { name: '失焦淡出' }));
  await waitFor(() => expect(screen.queryByRole('slider', { name: '淡出前等待' })).toBeNull());
});

it('idle fade: a switch and an opacity slider that only shows while it is on', async () => {
  await openSettings();
  expect(screen.getByRole('switch', { name: '失焦淡出' }).getAttribute('aria-checked')).toBe('true');
  const slider = screen.getByRole('slider', { name: '淡出后的不透明度' }) as HTMLInputElement;
  expect(slider.min).toBe('20');
  fireEvent.change(slider, { target: { value: '30' } });
  await waitFor(async () => expect((await settingsApi.get()).idle_opacity).toBe(30));
  fireEvent.click(screen.getByRole('switch', { name: '失焦淡出' }));
  await waitFor(() => expect(screen.queryByRole('slider', { name: '淡出后的不透明度' })).toBeNull());
  await waitFor(async () => expect((await settingsApi.get()).idle_fade).toBe(false));
});

it('presets set both sliders', async () => {
  await openSettings();
  fireEvent.click(screen.getByRole('button', { name: '极致通透' }));
  await waitFor(async () => expect(await settingsApi.get()).toMatchObject({ opacity: 8, frost: 4 }));
  expect(document.documentElement.style.getPropertyValue('--tint-alpha')).toBe('0.08');
  fireEvent.click(screen.getByRole('button', { name: '标准' }));
  await waitFor(() => expect(document.documentElement.style.getPropertyValue('--tint-alpha')).toBe('0.6'));
});

it('the language is a dropdown; switching it re-labels everything and the choice is saved', async () => {
  await openSettings();
  expect(screen.queryByRole('radio', { name: 'English' })).toBeNull();
  const pick = async (current: string, option: string) => { fireEvent.click(screen.getByRole('button', { name: current })); fireEvent.click(screen.getByRole('menuitem', { name: option })); };
  await pick('语言', 'English');
  await screen.findByRole('radiogroup', { name: 'Theme' });
  expect(document.documentElement.lang).toBe('en');
  expect(screen.getByRole('tab', { name: 'Appearance' })).toBeTruthy();
  expect(screen.getByRole('slider', { name: 'Transparency' })).toBeTruthy();
  await waitFor(async () => expect((await settingsApi.get()).language).toBe('en'));
  await pick('Language', '日本語');
  await screen.findByRole('radiogroup', { name: 'テーマ' });
  await pick('言語', '繁體中文');
  await screen.findByRole('tab', { name: '外觀' });
});

it('the window size can be reset to the default', async () => {
  const { windowApi } = await import('../src/windowApi');
  const reset = vi.spyOn(windowApi, 'resetWindowSize').mockResolvedValue();
  await openSettings();
  fireEvent.click(screen.getByRole('button', { name: '恢复默认' }));
  expect(reset).toHaveBeenCalledTimes(1);
});

it('the lock is a setting too', async () => {
  await openSettings();
  fireEvent.click(screen.getByRole('switch', { name: '固定窗口' }));
  await waitFor(async () => expect((await settingsApi.get()).locked).toBe(true));
});

it('toggles launch at login, always on top and where the app shows (Dock, menu bar)', async () => {
  await openSettings();
  fireEvent.click(screen.getByRole('switch', { name: '开机启动' }));
  await waitFor(() => expect(screen.getByRole('switch', { name: '开机启动' }).getAttribute('aria-checked')).toBe('true'));
  fireEvent.click(screen.getByRole('switch', { name: '窗口置顶' }));
  await waitFor(() => expect(screen.getByRole('switch', { name: '窗口置顶' }).getAttribute('aria-checked')).toBe('false'));
  fireEvent.click(screen.getByRole('switch', { name: '显示在 Dock' }));
  fireEvent.click(screen.getByRole('switch', { name: '显示在菜单栏' }));
  await waitFor(async () => expect(await settingsApi.get()).toMatchObject({ launch_at_login: true, always_on_top: false, show_dock: false, show_menubar: false }));
  expect(screen.getByText('两处都关闭后，只能用快捷键或悬浮球打开 Dotist')).toBeTruthy();
});

it('records a new shortcut, ignores bare keys, cancels with Escape and clears', async () => {
  await openSettings();
  const field = screen.getByRole('button', { name: '快速添加快捷键' });
  expect(field.textContent).toBe('⌘ ⌥ N');
  fireEvent.click(field);
  fireEvent.keyDown(field, { code: 'KeyK', key: 'k' });
  expect(field.textContent).toContain('按下新的快捷键');
  fireEvent.keyDown(field, { code: 'KeyK', key: 'k', metaKey: true, shiftKey: true });
  await waitFor(() => expect(screen.getByRole('button', { name: '快速添加快捷键' }).textContent).toBe('⌘ ⇧ K'));
  fireEvent.click(screen.getByRole('button', { name: '快速添加快捷键' }));
  fireEvent.keyDown(screen.getByRole('button', { name: '快速添加快捷键' }), { key: 'Escape' });
  expect(screen.getByRole('button', { name: '快速添加快捷键' }).textContent).toBe('⌘ ⇧ K');
  fireEvent.click(screen.getByRole('button', { name: '清除快速添加快捷键' }));
  await waitFor(() => expect(screen.getByRole('button', { name: '快速添加快捷键' }).textContent).toBe('未设置'));
});

it('shows the MCP path, copies the client config and surfaces (translated) update errors, then restores the value', async () => {
  const writeText = vi.fn(async () => {});
  Object.assign(navigator, { clipboard: { writeText } });
  await openSettings();
  expect(screen.getByText(/dotist-mcp/)).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: '复制 Claude Code 添加命令' }));
  await waitFor(() => expect(writeText).toHaveBeenCalledWith(expect.stringMatching(/^claude mcp add dotist -- ".*dotist-mcp"$/)));
  fireEvent.click(screen.getByRole('button', { name: '复制 MCP JSON 配置' }));
  await waitFor(() => expect(JSON.parse((writeText.mock.calls.at(-1) as unknown as string[])[0]).mcpServers.dotist.command).toContain('dotist-mcp'));
  vi.spyOn(settingsApi, 'update').mockRejectedValueOnce('不同的动作不能使用同一个快捷键');
  fireEvent.click(screen.getByRole('switch', { name: '窗口置顶' }));
  await waitFor(() => expect(screen.getByRole('alert').textContent).toContain('不能使用同一个快捷键'));
  await waitFor(() => expect(screen.getByRole('switch', { name: '窗口置顶' }).getAttribute('aria-checked')).toBe('true'));
});


it('records and clears the task views shortcut', async () => {
  const { windowApi } = await import('../src/windowApi');
  const capture = vi.spyOn(windowApi, 'captureShortcuts').mockResolvedValue();
  await openSettings();
  const field = screen.getByRole('button', { name: '打开任务视图快捷键' });
  expect(field.textContent).toBe('未设置');
  fireEvent.click(field);
  fireEvent.keyDown(field, { code: 'KeyK', key: 'k', metaKey: true, shiftKey: true });
  await waitFor(async () => expect((await settingsApi.get()).views_shortcut).toBe('Command+Shift+K'));
  expect(capture.mock.calls.map(call => call[0])).toEqual([true, false]);
  fireEvent.click(screen.getByRole('button', { name: '清除打开任务视图快捷键' }));
  await waitFor(async () => expect((await settingsApi.get()).views_shortcut).toBe(''));
});

it('shows an unconfigured update status', async () => {
  vi.spyOn(settingsApi, 'checkUpdate').mockResolvedValue({ status: 'unconfigured' });
  await openSettings();
  fireEvent.click(screen.getByRole('button', { name: '检查更新' }));
  expect(await screen.findByText('更新尚未配置。')).toBeTruthy();
});

it('shows an available update and allows skipping it, while manual checks still find it', async () => {
  vi.spyOn(settingsApi, 'checkUpdate').mockResolvedValue({ status: 'available', version: '1.2.3', notes: 'Release notes' });
  await openSettings();
  fireEvent.click(screen.getByRole('button', { name: '检查更新' }));
  expect(await screen.findByText('发现新版本 1.2.3')).toBeTruthy();
  expect(screen.getByText('Release notes')).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: '跳过此版本' }));
  await waitFor(async () => expect((await settingsApi.get()).skipped_update_version).toBe('1.2.3'));
  fireEvent.click(screen.getByRole('button', { name: '检查更新' }));
  expect(await screen.findByText('发现新版本 1.2.3')).toBeTruthy();
});

it('reports installation failures and allows changing automatic checks', async () => {
  vi.spyOn(settingsApi, 'checkUpdate').mockResolvedValue({ status: 'available', version: '1.2.3' });
  vi.spyOn(settingsApi, 'installUpdate').mockRejectedValue('download failed');
  await openSettings();
  fireEvent.click(screen.getByRole('switch', { name: '自动检查更新' }));
  await waitFor(async () => expect((await settingsApi.get()).auto_check_updates).toBe(false));
  fireEvent.click(screen.getByRole('button', { name: '检查更新' }));
  fireEvent.click(await screen.findByRole('button', { name: '立即更新' }));
  expect(await screen.findByText('安装更新失败：download failed')).toBeTruthy();
});

it('lets the user opt in to automatic installation and explains when it takes effect', async () => {
  await openSettings();
  const install = screen.getByRole('switch', { name: '自动安装更新' });
  expect(install.getAttribute('aria-checked')).toBe('false');
  expect(screen.getByText('新版本在退出 Dotist 时安装，重新打开后生效')).toBeTruthy();
  fireEvent.click(install);
  await waitFor(async () => expect(await settingsApi.get()).toMatchObject({ auto_install_updates: true, auto_check_updates: true }));
  fireEvent.click(screen.getByRole('switch', { name: '自动检查更新' }));
  await waitFor(async () => expect(await settingsApi.get()).toMatchObject({ auto_install_updates: false, auto_check_updates: false }));
  fireEvent.click(screen.getByRole('switch', { name: '自动安装更新' }));
  await waitFor(async () => expect(await settingsApi.get()).toMatchObject({ auto_install_updates: true, auto_check_updates: true }));
});

it('shows the previous automatic installation failure after reopening settings', async () => {
  const saved = await settingsApi.get();
  vi.spyOn(settingsApi, 'get').mockResolvedValue({ ...saved, last_update_error: 'disk full' });
  await openSettings();
  expect(screen.getByRole('alert').textContent).toBe('上次自动安装失败：disk full');
});
