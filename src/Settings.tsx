import { ChevronDown, Eye, GripVertical, Info, Keyboard, LayoutList, Palette, Plug, SlidersHorizontal, X } from 'lucide-react';
import { useEffect, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import { LANGS, setLanguage, t, tError, type LangSetting } from './i18n';
import { Menu, type MenuState } from './Menu';
import { taskApi } from './taskApi';
import type { GroupInfo } from './types';
import { ALL_FILTERS, FILTER_LABELS, GLASS_PRESETS, applyGlass, applyGroupColors, applyTheme, opacityFromTransparency, settingsApi, transparencyOf, type FilterId, type GroupColors, type SettingsPatch, type SettingsView, type Theme, type TrayAction, type TrayMode, type UpdateResult, type UpdateProgress } from './settingsApi';
import { acceleratorFromEvent, formatAccelerator } from './shortcut';
import { windowApi } from './windowApi';

type Tab = 'appearance' | 'general' | 'views' | 'menubar' | 'shortcuts' | 'mcp' | 'about';
const TABS: { id: Tab; label: string; icon: typeof Palette }[] = [
  { id: 'appearance', label: '外观', icon: Palette }, { id: 'general', label: '通用', icon: SlidersHorizontal }, { id: 'views', label: '筛选器', icon: LayoutList },
  { id: 'menubar', label: '菜单栏', icon: Eye }, { id: 'shortcuts', label: '快捷键', icon: Keyboard }, { id: 'mcp', label: 'MCP', icon: Plug }, { id: 'about', label: '数据与关于', icon: Info },
];
const THEMES: { id: Theme; label: string }[] = [{ id: 'system', label: '跟随系统' }, { id: 'light', label: '浅色' }, { id: 'dark', label: '深色' }];
const GROUP_COLOR_STYLES: { id: GroupColors; label: string }[] = [{ id: 'dot', label: '小圆点' }, { id: 'text', label: '彩色名称' }, { id: 'none', label: '不显示颜色' }];
const TRAY_MODES: { id: TrayMode; label: string }[] = [
  { id: 'icon', label: '仅图标' }, { id: 'count', label: '剩余数字' }, { id: 'next', label: '下一个任务' }, { id: 'next_date', label: '下一个任务与日期' }, { id: 'rotate', label: '轮播：数字与最近的任务' },
];
const TRAY_ACTIONS: { id: TrayAction; label: string }[] = [
  { id: 'toggle', label: '显示 / 收起窗口' }, { id: 'bubble', label: '展开 / 收起悬浮球' }, { id: 'quick', label: '快速添加' }, { id: 'settings', label: '打开设置' },
  { id: 'show', label: '显示窗口' }, { id: 'menu', label: '打开菜单' }, { id: 'none', label: '无操作' },
];
const FILTER_ROW = 40; // px; matches .dt-filter-row
const TOOLS = 'list_tasks, add_task, update_task, complete_task, delete_task, restore_task, move_task, set_due_date, set_start_date, set_task_status, set_task_parent, list_groups, add_group, update_group, delete_group, restore_group';
// Survives the remount that a language change causes.
let lastTab: Tab = 'appearance';

function Row({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return <div className="dt-set-row"><div className="dt-set-label">{label}{hint && <small>{hint}</small>}</div><div className="dt-set-control">{children}</div></div>;
}

function Switch({ label, checked, disabled, onChange }: { label: string; checked: boolean; disabled?: boolean; onChange: (next: boolean) => void }) {
  return <button type="button" role="switch" aria-checked={checked} aria-label={label} disabled={disabled} className={`dt-switch ${checked ? 'is-on' : ''}`} onClick={() => onChange(!checked)}><span /></button>;
}

function Slider({ label, value, onChange, min = 0, max = 100, unit = '' }: { label: string; value: number; onChange: (next: number) => void; min?: number; max?: number; unit?: string }) {
  return <Row label={label}>
    <span className="dt-slider"><input type="range" min={min} max={max} step={1} aria-label={label} value={value} onChange={event => onChange(Number(event.target.value))} /><output>{value}{unit}</output></span>
  </Row>;
}

/** A dropdown built from the same floating menu as everything else. */
function Select<T extends string>({ label, value, options, disabled, onChange }: { label: string; value: T; options: { id: T; label: string }[]; disabled?: boolean; onChange: (next: T) => void }) {
  const [menu, setMenu] = useState<MenuState | null>(null);
  const current = options.find(option => option.id === value)?.label ?? '';
  return <>
    <button type="button" className="dt-select" aria-haspopup="menu" aria-expanded={menu !== null} aria-label={label} disabled={disabled} onClick={event => {
      const box = event.currentTarget.getBoundingClientRect();
      setMenu({ x: box.left, y: box.bottom + 4, items: options.map(option => ({ label: option.label, checked: option.id === value, onSelect: () => onChange(option.id) })) });
    }}>{current}<ChevronDown className="dt-svg" strokeWidth={1.5} /></button>
    {menu && <Menu state={menu} onClose={() => setMenu(null)} />}
  </>;
}

function ShortcutField({ label, value, onChange }: { label: string; value: string; onChange: (next: string) => void }) {
  const [recording, setRecording] = useState(false);
  const live = useRef(false);
  const begin = () => { live.current = true; setRecording(true); void windowApi.captureShortcuts(true); };
  // Global shortcuts and the menu bar's key equivalents stay paused until recording ends, so every combination arrives here.
  const finish = (accelerator?: string) => {
    if (!live.current) return;
    live.current = false;
    setRecording(false);
    void windowApi.captureShortcuts(false).then(() => { if (accelerator !== undefined) onChange(accelerator); });
  };
  useEffect(() => () => { if (live.current) void windowApi.captureShortcuts(false); }, []);
  const onKeyDown = (event: KeyboardEvent<HTMLButtonElement>) => {
    if (!recording) return;
    event.preventDefault();
    if (event.key === 'Escape') { finish(); return; }
    const accelerator = acceleratorFromEvent(event);
    if (accelerator) finish(accelerator);
  };
  return <span className="dt-shortcut">
    <button type="button" className={`dt-shortcut-key ${recording ? 'is-recording' : ''}`} aria-label={t('{label}快捷键', { label })} onClick={begin} onKeyDown={onKeyDown} onBlur={() => finish()}>
      {recording ? t('按下新的快捷键…') : formatAccelerator(value)}
    </button>
    {value && !recording && <button type="button" className="dt-icon" aria-label={t('清除{label}快捷键', { label })} title={t('清除')} onClick={() => onChange('')}><X className="dt-svg" strokeWidth={1.5} /></button>}
  </span>;
}

function CopyButton({ text, label }: { text: string; label: string }) {
  const [done, setDone] = useState(false);
  return <button type="button" className="dt-link" aria-label={label} onClick={() => { void navigator.clipboard?.writeText(text).then(() => { setDone(true); setTimeout(() => setDone(false), 1500); }, () => {}); }}>{done ? t('已复制') : t('复制')}</button>;
}

/** The settings window: a tab list on the left that follows one long scrolling page on the right. */
export function SettingsWindow() {
  const [settings, setSettings] = useState<SettingsView | null>(null);
  const [error, setError] = useState('');
  const [updateResult, setUpdateResult] = useState<UpdateResult | null>(null);
  const [updateBusy, setUpdateBusy] = useState(false);
  const [progress, setProgress] = useState<UpdateProgress | null>(null);
  const [installError, setInstallError] = useState('');
  const [tab, setTabState] = useState<Tab>(lastTab);
  const setTab = (next: Tab) => { lastTab = next; setTabState(next); };
  const pane = useRef<HTMLDivElement>(null);
  const [groups, setGroups] = useState<GroupInfo[]>([]);
  useEffect(() => { void taskApi.groups().then(setGroups, () => {}); }, []);
  const queued = useRef<SettingsPatch>({});
  // Reordering filters by dragging the handle: the order follows the pointer live and is saved on release.
  const listRef = useRef<HTMLUListElement>(null);
  const [drag, setDrag] = useState<{ id: FilterId; order: FilterId[]; dy: number } | null>(null);
  const grab = useRef({ offset: 0 });

  const inFlight = useRef(false);

  useEffect(() => { void settingsApi.get().then(next => { setSettings(next); applyTheme(next.theme); setLanguage(next.language); }, reason => setError(String(reason))); }, []);
  useEffect(() => {
    const off = windowApi.on<SettingsView>('settings-changed', next => { setSettings(next); applyTheme(next.theme); setLanguage(next.language); });
    return () => { void off.then(stop => stop()); };
  }, []);

  useEffect(() => {
    let alive = true;
    void settingsApi.pendingUpdate().then(value => { if (alive && value) setUpdateResult(value); });
    const updateOff = settingsApi.onUpdate(value => { if (alive) setUpdateResult(value); });
    const progressOff = settingsApi.onProgress(value => { if (alive) setProgress(value); });
    return () => { alive = false; void updateOff.then(stop => stop()); void progressOff.then(stop => stop()); };
  }, []);
  async function checkUpdate() {
    setUpdateBusy(true); setInstallError(''); setProgress(null);
    try { setUpdateResult(await settingsApi.checkUpdate()); }
    catch (reason) { setUpdateResult({ status: 'error', message: String(reason) }); }
    finally { setUpdateBusy(false); }
  }
  async function installUpdate() {
    setUpdateBusy(true); setInstallError(''); setProgress(null);
    try { await settingsApi.installUpdate(); }
    catch (reason) { setInstallError(String(reason)); }
    finally { setUpdateBusy(false); }
  }

  // Changes show at once and are sent in order; while one is in flight later ones are merged, so dragging a slider
  // to its limit always ends on the value the slider shows.
  async function drain() {
    inFlight.current = true;
    while (Object.keys(queued.current).length) {
      const patch = queued.current;
      queued.current = {};
      try {
        const next = await settingsApi.update(patch);
        if (!Object.keys(queued.current).length) setSettings(next);
        setError('');
      } catch (reason) {
        setError(tError(typeof reason === 'string' ? reason : reason instanceof Error ? reason.message : '设置失败，请重试。'));
        queued.current = {};
        const fresh = await settingsApi.get().catch(() => null);
        if (fresh) { setSettings(fresh); applyTheme(fresh.theme); applyGlass(fresh.opacity, fresh.frost); setLanguage(fresh.language); }
      }
    }
    inFlight.current = false;
  }
  function update(patch: SettingsPatch) {
    setSettings(previous => {
      if (!previous) return previous;
      const next = { ...previous, ...patch };
      if (patch.theme) applyTheme(patch.theme);
      if (patch.group_colors) applyGroupColors(patch.group_colors);
      if (patch.opacity !== undefined || patch.frost !== undefined) applyGlass(next.opacity, next.frost);
      return next;
    });
    if (patch.language) setLanguage(patch.language);
    queued.current = { ...queued.current, ...patch };
    if (!inFlight.current) void drain();
  }

  if (!settings) return <div className="dt-settings-window"><div className="dt-set-drag" data-tauri-drag-region /><p className="dt-set-note">{error}</p></div>;

  const mcpConfig = JSON.stringify({ mcpServers: { dotist: { command: settings.mcp_path } } }, null, 2);
  const mcpCommand = `claude mcp add dotist -- "${settings.mcp_path}"`;
  const section = (id: Tab, title: string, body: ReactNode) => <section className="dt-set-group" id={`set-${id}`} aria-label={title}><h2 className="dt-set-title">{title}</h2><div className="dt-set-body">{body}</div></section>;
  const jump = (id: Tab) => { setTab(id); pane.current?.querySelector(`#set-${id}`)?.scrollIntoView?.({ behavior: 'smooth', block: 'start' }); };
  // The page scrolls through all sections; the sidebar follows where you are.
  const spy = () => {
    const box = pane.current;
    if (!box) return;
    let current: Tab = TABS[0].id;
    if (box.scrollTop + box.clientHeight >= box.scrollHeight - 4) current = TABS[TABS.length - 1].id;
    else for (const item of TABS) { const el = box.querySelector<HTMLElement>(`#set-${item.id}`); if (el && el.offsetTop - box.offsetTop - box.scrollTop <= 48) current = item.id; }
    if (current !== lastTab) setTab(current);
  };

  const enabled = settings.filters;
  const disabled = ALL_FILTERS.filter(id => !enabled.includes(id));
  const setFilters = (next: FilterId[]) => update({ filters: next, ...(next.includes(settings.default_filter) ? {} : { default_filter: next[0] }) });
  const move = (id: FilterId, delta: -1 | 1) => {
    const index = enabled.indexOf(id);
    const target = index + delta;
    if (target < 0 || target >= enabled.length) return;
    const next = [...enabled];
    [next[index], next[target]] = [next[target], next[index]];
    setFilters(next);
  };
  const shown = drag?.order ?? enabled;
  const startDrag = (event: React.PointerEvent<HTMLButtonElement>, id: FilterId) => {
    if (event.button !== 0) return;
    const top = listRef.current?.getBoundingClientRect().top ?? 0;
    grab.current.offset = event.clientY - (top + enabled.indexOf(id) * FILTER_ROW);
    event.currentTarget.setPointerCapture?.(event.pointerId);
    setDrag({ id, order: enabled, dy: 0 });
  };
  const moveDrag = (event: React.PointerEvent<HTMLButtonElement>) => {
    if (!drag) return;
    const top = listRef.current?.getBoundingClientRect().top ?? 0;
    const pointerTop = event.clientY - grab.current.offset;
    const index = Math.min(enabled.length - 1, Math.max(0, Math.round((pointerTop - top) / FILTER_ROW)));
    const order = enabled.filter(other => other !== drag.id);
    order.splice(index, 0, drag.id);
    setDrag({ id: drag.id, order, dy: pointerTop - (top + index * FILTER_ROW) });
  };
  const endDrag = (commit: boolean) => {
    if (drag && commit && drag.order.some((id, index) => id !== enabled[index])) setFilters(drag.order);
    setDrag(null);
  };
  const noMenu = settings.tray_left_click !== 'menu' && settings.tray_right_click !== 'menu';

  return <div className="dt-settings-window">
    <div className="dt-set-drag" data-tauri-drag-region />
    <nav className="dt-set-nav" role="tablist" aria-orientation="vertical" aria-label={t('设置')}>
      {TABS.map(item => <button key={item.id} type="button" role="tab" aria-selected={tab === item.id} className={`dt-set-tab ${tab === item.id ? 'is-on' : ''}`} onClick={() => jump(item.id)}><item.icon className="dt-svg" strokeWidth={1.5} />{t(item.label)}</button>)}
    </nav>
    <div className="dt-set-pane" role="tabpanel" ref={pane} onScroll={spy}>
      {error && <div className="dt-error" role="alert">{error}</div>}
      {section('appearance', t('外观'), <>
        <Row label={t('主题')}>
          <div className="dt-segment" role="radiogroup" aria-label={t('主题')}>
            {THEMES.map(theme => <button key={theme.id} type="button" role="radio" aria-checked={settings.theme === theme.id} className={settings.theme === theme.id ? 'is-on' : ''} onClick={() => update({ theme: theme.id })}>{t(theme.label)}</button>)}
          </div>
        </Row>
        <Row label={t('玻璃预设')}>
          <div className="dt-segment" role="group" aria-label={t('玻璃预设')}>
            <button type="button" onClick={() => update(GLASS_PRESETS.standard)}>{t('标准')}</button>
            <button type="button" onClick={() => update(GLASS_PRESETS.clear)}>{t('透明玻璃')}</button>
            <button type="button" onClick={() => update(GLASS_PRESETS.crystal)}>{t('极致通透')}</button>
          </div>
        </Row>
        <Slider label={t('透明程度')} unit="%" value={transparencyOf(settings.opacity)} onChange={next => update({ opacity: opacityFromTransparency(next) })} />
        <Slider label={t('磨砂程度')} unit="%" value={settings.frost} onChange={next => update({ frost: next })} />
        <Row label={t('分组颜色')}><Select label={t('分组颜色')} value={settings.group_colors} options={GROUP_COLOR_STYLES.map(style => ({ id: style.id, label: t(style.label) }))} onChange={next => update({ group_colors: next })} /></Row>
        <Row label={t('失焦淡出')}><Switch label={t('失焦淡出')} checked={settings.idle_fade} onChange={next => update({ idle_fade: next })} /></Row>
        {settings.idle_fade && <Slider label={t('淡出前等待')} min={1} max={60} unit={t(' 秒')} value={settings.idle_delay_secs} onChange={next => update({ idle_delay_secs: next })} />}
        {settings.idle_fade && <Slider label={t('淡出用时')} min={1} max={10} unit={t(' 秒')} value={settings.idle_fade_secs} onChange={next => update({ idle_fade_secs: next })} />}
        {settings.idle_fade && <Slider label={t('淡出后的不透明度')} min={20} max={95} unit="%" value={settings.idle_opacity} onChange={next => update({ idle_opacity: next })} />}
      </>)}
      {section('general', t('通用'), <>
        <Row label={t('语言')}><Select label={t('语言')} value={settings.language} options={[{ id: 'system' as LangSetting, label: t('跟随系统') }, ...LANGS.map(lang => ({ id: lang.id as LangSetting, label: lang.label }))]} onChange={next => update({ language: next })} /></Row>
        <Row label={t('显示在 Dock')}><Switch label={t('显示在 Dock')} checked={settings.show_dock} onChange={next => update({ show_dock: next })} /></Row>
        <Row label={t('显示在菜单栏')} hint={settings.show_dock || settings.show_menubar ? undefined : t('两处都关闭后，只能用快捷键或悬浮球打开 Dotist')}><Switch label={t('显示在菜单栏')} checked={settings.show_menubar} onChange={next => update({ show_menubar: next })} /></Row>
        <Row label={t('开机启动')}><Switch label={t('开机启动')} checked={settings.launch_at_login} onChange={next => update({ launch_at_login: next })} /></Row>
        <Row label={t('悬停显示详情')}><Switch label={t('悬停显示详情')} checked={settings.hover_expand} onChange={next => update({ hover_expand: next })} /></Row>
        <Row label={t('窗口大小')}><button type="button" className="dt-link" onClick={() => void windowApi.resetWindowSize()}>{t('恢复默认')}</button></Row>
        <Row label={t('固定窗口')}><Switch label={t('固定窗口')} checked={settings.locked} onChange={next => update({ locked: next })} /></Row>
        <Row label={t('自动收起')}><Switch label={t('自动收起')} checked={settings.auto_collapse} onChange={next => update({ auto_collapse: next })} /></Row>
        {settings.auto_collapse && <Slider label={t('收起等待时间')} min={5} max={120} unit={t(' 秒')} value={settings.auto_collapse_secs} onChange={next => update({ auto_collapse_secs: next })} />}
        <Row label={t('窗口置顶')}><Switch label={t('窗口置顶')} checked={settings.always_on_top} onChange={next => update({ always_on_top: next })} /></Row>
      </>)}
      {section('views', t('筛选器'), <>
        <p className="dt-set-note">{t('主窗口顶部的筛选条可以左右滑动。在这里选择显示哪些，拖动手柄调整顺序。')}</p>
        <Row label={t('启动时打开')}><Select label={t('启动时打开')} value={settings.default_filter} options={enabled.map(id => ({ id, label: t(FILTER_LABELS[id]) }))} onChange={next => update({ default_filter: next })} /></Row>
        <ul className="dt-filter-list" aria-label={t('筛选器')} ref={listRef}>
          {shown.map(id => <li key={id} className={`dt-filter-row ${drag?.id === id ? 'is-dragging' : ''}`} style={drag?.id === id ? { transform: `translateY(${drag.dy}px)` } : undefined}>
            <button type="button" className="dt-grip" aria-label={t('拖动排序 {name}', { name: t(FILTER_LABELS[id]) })} title={t('拖动调整顺序')}
              onPointerDown={event => startDrag(event, id)} onPointerMove={moveDrag} onPointerUp={() => endDrag(true)} onPointerCancel={() => endDrag(false)}
              onKeyDown={event => { if (event.key === 'ArrowUp' || event.key === 'ArrowDown') { event.preventDefault(); move(id, event.key === 'ArrowUp' ? -1 : 1); } }}><GripVertical className="dt-svg" strokeWidth={1.5} /></button>
            <span className="dt-filter-name">{t(FILTER_LABELS[id])}</span>
            <Switch label={t('显示 {name}', { name: t(FILTER_LABELS[id]) })} checked disabled={enabled.length === 1} onChange={() => setFilters(enabled.filter(other => other !== id))} />
          </li>)}
          {disabled.map(id => <li key={id} className="dt-filter-row is-off">
            <span className="dt-grip-space" aria-hidden="true" />
            <span className="dt-filter-name">{t(FILTER_LABELS[id])}</span>
            <Switch label={t('显示 {name}', { name: t(FILTER_LABELS[id]) })} checked={false} onChange={() => setFilters([...enabled, id])} />
          </li>)}
        </ul>
      </>)}
      {section('menubar', t('菜单栏'), <>
        <Row label={t('显示内容')}><Select label={t('显示内容')} value={settings.tray_mode} options={TRAY_MODES.map(mode => ({ id: mode.id, label: t(mode.label) }))} onChange={next => update({ tray_mode: next })} /></Row>
        {settings.tray_mode !== 'icon' && <Row label={t('日期透视')}><Select label={t('日期透视')} value={settings.tray_filter} options={ALL_FILTERS.map(id => ({ id, label: t(FILTER_LABELS[id]) }))} onChange={next => update({ tray_filter: next })} /></Row>}
        {settings.tray_mode !== 'icon' && <Row label={t('分组')}><Select label={t('分组')} value={groups.some(group => group.id === settings.tray_group) ? settings.tray_group : 'all'} options={[{ id: 'all', label: t('全部分组') }, ...groups.map(group => ({ id: group.id, label: group.name }))]} onChange={next => update({ tray_group: next })} /></Row>}
        {settings.tray_mode === 'rotate' && <Slider label={t('轮播间隔')} min={2} max={30} unit={t(' 秒')} value={settings.tray_rotate_secs} onChange={next => update({ tray_rotate_secs: next })} />}
        <Row label={t('左键点击')}><Select label={t('左键点击')} value={settings.tray_left_click} options={TRAY_ACTIONS.map(action => ({ id: action.id, label: t(action.label) }))} onChange={next => update({ tray_left_click: next })} /></Row>
        <Row label={t('右键点击')} hint={noMenu ? t('没有一键打开菜单时，可用 Dock 图标或 ⌘Q 退出 Dotist') : undefined}><Select label={t('右键点击')} value={settings.tray_right_click} options={TRAY_ACTIONS.map(action => ({ id: action.id, label: t(action.label) }))} onChange={next => update({ tray_right_click: next })} /></Row>
      </>)}
      {section('shortcuts', t('快捷键'), <>
        <Row label={t('显示 / 收起窗口')}><ShortcutField label={t('显示或收起窗口')} value={settings.toggle_shortcut} onChange={next => update({ toggle_shortcut: next })} /></Row>
        <Row label={t('打开设置')}><ShortcutField label={t('打开设置')} value={settings.settings_shortcut} onChange={next => update({ settings_shortcut: next })} /></Row>
        <Row label={t('打开任务视图')}><ShortcutField label={t('打开任务视图')} value={settings.views_shortcut} onChange={next => update({ views_shortcut: next })} /></Row>
        <Row label={t('快速添加')}><ShortcutField label={t('快速添加')} value={settings.quick_add_shortcut} onChange={next => update({ quick_add_shortcut: next })} /></Row>
      </>)}
      {section('mcp', 'MCP', <>
        <p className="dt-set-note">{t('Dotist 自带本地 MCP 服务器（stdio），与窗口共用同一个数据库。它不会自动连接任何客户端，由你在客户端里添加；添加后该客户端就能读取和修改你的任务。')}</p>
        <Row label={t('可执行文件')}><button type="button" className="dt-link" onClick={() => void settingsApi.reveal(settings.mcp_path)}>{t('在 Finder 中显示')}</button></Row>
        <div className="dt-code"><code>{settings.mcp_path}</code><CopyButton text={settings.mcp_path} label={t('复制 MCP 路径')} /></div>
        <Row label="Claude Code"><CopyButton text={mcpCommand} label={t('复制 Claude Code 添加命令')} /></Row>
        <Row label={t('其他客户端配置（JSON）')}><CopyButton text={mcpConfig} label={t('复制 MCP JSON 配置')} /></Row>
        <p className="dt-set-note">{t('工具：{tools}。', { tools: TOOLS })}</p>
      </>)}
      {section('about', t('数据与关于'), <>
        <Row label={t('任务数据库')}><button type="button" className="dt-link" onClick={() => void settingsApi.reveal(settings.db_path)}>{t('在 Finder 中显示')}</button></Row>
        <Row label={t('版本')}><span className="dt-set-value">{settings.version}</span></Row>
        <Row label={t('更新')}><button type="button" className="dt-link" disabled={updateBusy} onClick={() => void checkUpdate()}>{t('检查更新')}</button></Row>
        <Row label={t('自动检查更新')}><Switch label={t('自动检查更新')} checked={settings.auto_check_updates} onChange={next => update({ auto_check_updates: next })} /></Row>
        {updateBusy && !progress && <p className="dt-set-note" role="status">{t('正在处理更新…')}</p>}
        {updateResult?.status === 'unconfigured' && <p className="dt-set-note" role="status">{t('更新尚未配置。')}</p>}
        {updateResult?.status === 'up_to_date' && <p className="dt-set-note" role="status">{t('已是最新版本。')}</p>}
        {updateResult?.status === 'error' && <p className="dt-set-note" role="alert">{t('检查更新失败：{message}', { message: updateResult.message ?? '' })}</p>}
        {updateResult?.status === 'available' && <div>
          <p className="dt-set-note">{t('发现新版本 {version}', { version: updateResult.version ?? '' })}</p>
          {updateResult.notes && <p className="dt-set-note" style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{updateResult.notes.slice(0, 500)}</p>}
          <button type="button" className="dt-link" disabled={updateBusy} onClick={() => void installUpdate()}>{t('立即更新')}</button>
          <button type="button" className="dt-link" disabled={updateBusy} onClick={() => { update({ skipped_update_version: updateResult.version ?? '' }); setUpdateResult(null); }}>{t('跳过此版本')}</button>
        </div>}
        {progress && <p className="dt-set-note" role="status">{progress.total ? t('已下载 {downloaded} / {total} 字节', { downloaded: progress.downloaded, total: progress.total }) : t('已下载 {downloaded} 字节', { downloaded: progress.downloaded })}</p>}
        {installError && <p className="dt-set-note" role="alert">{t('安装更新失败：{message}', { message: installError })}</p>}
      </>)}
    </div>
  </div>;
}
