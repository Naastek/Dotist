import { useCallback, useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent } from 'react';
import { CalendarDays, Columns3, ChevronDown, ChevronLeft, Lock, LockOpen, ChevronRight, ChevronUp, Check, Minimize2, Plus, Trash2 } from 'lucide-react';
import { GroupManager } from './GroupManager';
import { Menu, type MenuEntry, type MenuState, type OpenMenu } from './Menu';
import { TagManager } from './TagManager';
import { TagContext, TitleText, collectTags, filterByTag } from './tags';
import { ALL_FILTERS, FILTER_LABELS, applyGlass, applyGroupColors, applyTheme, settingsApi, type FilterId, type SettingsView, type TrayMode, type UpdateResult } from './settingsApi';
import { trayTitles } from './trayTitles';
import { Bubble } from './Bubble';
import { TaskComposer, isImeEvent } from './TaskComposer';
import { taskApi, isDemo } from './taskApi';
import { Calendar } from './Calendar';
import { addDays, dueInfo, inRange, localDate, monthDay, parseDate, quickDates, quickRanges, rangeLabel, weekdayShort, type DateRange } from './dates';
import { setLanguage, t, tError } from './i18n';
import { buildGroups, remainingCount, type TaskNode } from './taskTree';
import { UPCOMING_DAYS, buildLists, buildToday, type Lists } from './todayView';
import { groupColor, groupName, nextColor, type Category, type GroupInfo, type TodoTask } from './types';
import { startInBubble, windowApi, type ResizeDirection } from './windowApi';

const UNDO_MS = 5000;
const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));
const reducedMotion = () => typeof window.matchMedia === 'function' && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
function message(error: unknown) { return tError(typeof error === 'string' ? error : error instanceof Error ? error.message : '操作失败，请重试。'); }
type Run = (action: () => Promise<void>) => Promise<boolean>;
type Scope = 'today' | 'all' | 'overdue' | 'undated' | 'done';
/** The filters in the header strip, in order; it scrolls sideways (two-finger swipe) to reach all of them. */
const RANGE_FILTERS: { id: FilterId; index: number }[] = [{ id: 'tomorrow', index: 1 }, { id: 'week', index: 2 }, { id: 'nextweek', index: 3 }, { id: 'next7', index: 4 }];
const GRIPS: ResizeDirection[] = ['North', 'South', 'East', 'West', 'NorthEast', 'NorthWest', 'SouthEast', 'SouthWest'];
/** Invisible handles along the edges and corners; dragging one resizes the frameless window natively. */
function ResizeGrips() {
  return <>{GRIPS.map(direction => <div key={direction} className="dt-edge" data-dir={direction} aria-hidden="true" onPointerDown={event => { if (event.button !== 0) return; event.preventDefault(); void windowApi.startResize(direction); }} />)}</>;
}

interface Undo { kind: 'task' | 'group'; id: string; title: string }

export function App() {
  const [tag, setTag] = useState<string | null>(null);
  const tabOrigin = useRef<{ x: number; y: number } | null>(null);
  const tabDragged = useRef(false);
  const [tasks, setTasks] = useState<TodoTask[]>([]);
  const [groups, setGroups] = useState<GroupInfo[]>([]);
  const [error, setError] = useState('');
  const [loadError, setLoadError] = useState('');
  const [mutating, setMutating] = useState(false);
  const mutationLock = useRef(false);
  const sequence = useRef(0);
  const [editing, setEditing] = useState<string | null>(null);
  const [addingSub, setAddingSub] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [foldedOpen, setFoldedOpen] = useState<Set<Category>>(new Set());
  const [undo, setUndo] = useState<Undo | null>(null);
  const undoTimer = useRef<number | undefined>(undefined);
  const [mode, setMode] = useState<'open' | 'bubble'>(startInBubble ? 'bubble' : 'open');
  const [folded, setFolded] = useState(false);
  const [moving, setMoving] = useState(false);
  const [view, setView] = useState<'tasks' | 'groups' | 'tags'>('tasks');
  const [scope, setScopeState] = useState<Scope>(() => { try { return localStorage.getItem('dotist.scope') === 'today' ? 'today' : 'all'; } catch { return 'all'; } });
  const setScope = (next: Scope) => { setScopeState(next); try { if (next === 'today' || next === 'all') localStorage.setItem('dotist.scope', next); } catch { /* the choice just isn't remembered */ } };
  const [upcomingOpen, setUpcomingOpen] = useState(false);
  const [range, setRange] = useState<DateRange | null>(null);
  const [dayOpen, setDayOpen] = useState(false);
  const strip = useRef<HTMLDivElement>(null);
  const startFilter = useRef<(id: FilterId) => void>(() => {});
  // The menu bar's groups / perspectives submenus jump here: show the perspective, or scroll to the group and flash it.
  const [flash, setFlash] = useState<string | null>(null);
  const pendingGoto = useRef<{ filter: FilterId | null; group: string | null } | null>(null);
  const runGoto = useCallback(() => {
    const target = pendingGoto.current;
    if (!target || modeRef.current !== 'open') return;
    pendingGoto.current = null;
    if (target.filter) { startFilter.current(target.filter); return; }
    startFilter.current('all');
    if (target.group && target.group !== 'all') {
      setFlash(target.group);
      window.setTimeout(() => setFlash(null), 1600);
      setTimeout(() => document.getElementById(`group-${target.group}`)?.closest('section')?.scrollIntoView?.({ behavior: 'smooth', block: 'start' }), 120);
    } else document.querySelector('.dt-scroll')?.scrollTo?.({ top: 0, behavior: 'smooth' });
  }, []);
  const [menu, setMenu] = useState<MenuState | null>(null);
  const closeMenu = useCallback(() => setMenu(null), []);
  const openMenu: OpenMenu = (event, items) => { event.preventDefault(); event.stopPropagation(); setMenu({ x: event.clientX, y: event.clientY, items }); };
  const [adding, setAdding] = useState<string | null>(null);
  const [managerIntent, setManagerIntent] = useState<{ rename?: string; add?: boolean }>({});
  const openManager = (intent: { rename?: string; add?: boolean } = {}) => { setManagerIntent(intent); setView('groups'); };
  const [prefs, setPrefs] = useState<{ hoverExpand: boolean; onTop: boolean; autoCollapse: boolean; collapseSecs: number; locked: boolean; trayMode: TrayMode; trayFilter: FilterId; trayGroup: string; filters: FilterId[] }>({ hoverExpand: true, onTop: true, autoCollapse: true, collapseSecs: 20, locked: false, trayMode: 'icon', trayFilter: 'all', trayGroup: 'all', filters: ALL_FILTERS });
  const prefsRef = useRef(prefs);
  prefsRef.current = prefs;
  const viewRef = useRef(view);
  viewRef.current = view;
  const [availableUpdate, setAvailableUpdate] = useState<UpdateResult | null>(null);
  useEffect(() => {
    const subscription = settingsApi.onUpdate(setAvailableUpdate);
    return () => { void subscription.then(stop => stop()); };
  }, []);
  const modeRef = useRef(mode);
  const animating = useRef(false);

  const load = useCallback(async () => {
    const request = ++sequence.current;
    try {
      const [next, nextGroups] = await Promise.all([taskApi.list(), taskApi.groups()]);
      if (request === sequence.current) { setTasks(next); setGroups(nextGroups); setLoadError(''); }
    } catch (reason) { if (request === sequence.current) setLoadError(message(reason)); }
  }, []);
  useEffect(() => {
    void load();
    const timer = window.setInterval(() => void load(), 2500);
    const refresh = () => void load();
    window.addEventListener('focus', refresh);
    return () => { clearInterval(timer); window.removeEventListener('focus', refresh); };
  }, [load]);

  const run: Run = async action => {
    if (mutationLock.current) return false;
    mutationLock.current = true;
    setMutating(true);
    try { await action(); setError(''); await load(); return true; }
    catch (reason) { setError(message(reason)); return false; }
    finally { mutationLock.current = false; setMutating(false); }
  };

  // While the native window changes size the page keeps its content laid out at a fixed size, anchored at the
  // top-right (where the collapse button is), so the window simply reveals it instead of re-flowing every frame.
  const holdLayout = (width: number, height: number) => {
    const root = document.documentElement;
    root.style.setProperty('--full-w', `${width}px`);
    root.style.setProperty('--full-h', `${height}px`);
    root.setAttribute('data-moving', '');
    setMoving(true);
  };
  const releaseLayout = () => { document.documentElement.removeAttribute('data-moving'); setMoving(false); };
  const collapse = useCallback(async () => {
    if (animating.current || modeRef.current !== 'open') return;
    animating.current = true;
    holdLayout(window.innerWidth, window.innerHeight);
    setFolded(true);
    await sleep(reducedMotion() ? 0 : 110);
    try { await windowApi.animateBubble(true, reducedMotion() ? 120 : 260); modeRef.current = 'bubble'; setMode('bubble'); setFolded(false); }
    catch (reason) { setFolded(false); setError(message(reason)); }
    releaseLayout();
    animating.current = false;
  }, []);
  const expand = useCallback(async () => {
    if (animating.current || modeRef.current !== 'bubble') return;
    animating.current = true;
    const [width, height] = await windowApi.bubbleTargetSize().catch(() => [364, 620] as [number, number]);
    holdLayout(width, height);
    setFolded(true); modeRef.current = 'open'; setMode('open');
    await new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
    const growing = windowApi.animateBubble(false, reducedMotion() ? 120 : 340);
    // Start revealing the content while the window is still growing, so it unfolds in one motion.
    await sleep(reducedMotion() ? 0 : 90);
    setFolded(false);
    try { await growing; } catch (reason) { setError(message(reason)); }
    releaseLayout();
    animating.current = false;
  }, []);
  const syncPrefs = useCallback((settings: SettingsView) => setPrefs({ hoverExpand: settings.hover_expand, onTop: settings.always_on_top, autoCollapse: settings.auto_collapse, collapseSecs: settings.auto_collapse_secs, locked: settings.locked, trayMode: settings.tray_mode, trayFilter: settings.tray_filter, trayGroup: settings.tray_group, filters: settings.filters }), []);
  useEffect(() => { void settingsApi.get().then(settings => { applyTheme(settings.theme); applyGlass(settings.opacity, settings.frost); applyGroupColors(settings.group_colors); setLanguage(settings.language); syncPrefs(settings); startFilter.current(settings.default_filter); }, () => {}); }, [syncPrefs]);
  // A window left expanded with the pointer away and no activity folds back into the bubble.
  useEffect(() => {
    const state = { inside: true, last: Date.now() };
    const touch = () => { state.last = Date.now(); };
    const enter = () => { state.inside = true; touch(); };
    const leave = () => { state.inside = false; touch(); };
    const root = document.documentElement;
    root.addEventListener('mouseenter', enter); root.addEventListener('mouseleave', leave);
    window.addEventListener('pointermove', enter); window.addEventListener('pointerdown', touch); window.addEventListener('keydown', touch);
    // Native pointer tracking keeps working while the app is in the background.
    const nativePointer = windowApi.on<boolean>('pointer', inside => { if (inside) enter(); else leave(); });
    const timer = window.setInterval(() => {
      const { autoCollapse, collapseSecs, locked } = prefsRef.current;
      if (!autoCollapse || locked || modeRef.current !== 'open' || state.inside) { if (modeRef.current !== 'open') touch(); return; }
      const typing = document.hasFocus() && document.activeElement instanceof HTMLInputElement;
      if (typing || false) { touch(); return; }
      if (Date.now() - state.last >= collapseSecs * 1000) { touch(); void collapse(); }
    }, 1000);
    return () => { void nativePointer.then(stop => stop()); window.clearInterval(timer); root.removeEventListener('mouseenter', enter); root.removeEventListener('mouseleave', leave); window.removeEventListener('pointermove', enter); window.removeEventListener('pointerdown', touch); window.removeEventListener('keydown', touch); };
  }, [collapse]);
  async function toggleLock() {
    try { syncPrefs(await settingsApi.update({ locked: !prefs.locked })); } catch (reason) { setError(message(reason)); }
  }
  async function togglePin() {
    try { syncPrefs(await settingsApi.update({ always_on_top: !prefs.onTop })); } catch (reason) { setError(message(reason)); }
  }
  useEffect(() => {
    const onKey = (event: globalThis.KeyboardEvent) => { if ((event.metaKey || event.ctrlKey) && event.key === ',') { event.preventDefault(); void windowApi.openSettings(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  useEffect(() => {
    const focusComposer = () => { setView('tasks'); setTimeout(() => document.getElementById('new-task')?.focus(), 80); };
    const pending = [windowApi.on('collapse', () => void collapse()), windowApi.on('expand', () => void expand()),
      windowApi.on('focus-composer', focusComposer),
      windowApi.on<{ filter: FilterId | null; group: string | null }>('goto', payload => { pendingGoto.current = payload; runGoto(); }), windowApi.on('tasks-changed', () => void load()),
      windowApi.on<SettingsView>('settings-changed', next => { setAvailableUpdate(current => current?.version === next.skipped_update_version ? null : current); applyTheme(next.theme); applyGlass(next.opacity, next.frost); applyGroupColors(next.group_colors); setLanguage(next.language); syncPrefs(next); })];
    return () => { pending.forEach(promise => void promise.then(off => off())); };
  }, [collapse, expand, syncPrefs, load, runGoto]);
  useEffect(() => { runGoto(); }, [mode, runGoto]);
  useEffect(() => { void windowApi.setTrayGroups(groups.map(group => [group.id, group.name])).catch(() => {}); }, [groups]);

  const remaining = remainingCount(tasks);
  useEffect(() => { void windowApi.setTrayTitles(trayTitles(prefs.trayMode, tasks, groups, localDate(), prefs.trayFilter, groups.some(group => group.id === prefs.trayGroup) ? prefs.trayGroup : 'all')).catch(() => {}); }, [prefs.trayMode, prefs.trayFilter, prefs.trayGroup, tasks, groups]);
  // Keep the selected filter in view when the strip is scrolled or the filter changes.
  useEffect(() => { strip.current?.querySelector('[aria-selected="true"]')?.scrollIntoView?.({ inline: 'center', block: 'nearest', behavior: 'smooth' }); }, [scope, range]);
  useEffect(() => () => window.clearTimeout(undoTimer.current), []);

  function showUndo(item: Undo) {
    window.clearTimeout(undoTimer.current);
    setUndo(item);
    undoTimer.current = window.setTimeout(() => setUndo(null), UNDO_MS);
  }
  async function remove(task: TodoTask) {
    if (await run(() => taskApi.remove(task.id))) showUndo({ kind: 'task', id: task.id, title: task.title });
  }
  async function removeGroup(group: GroupInfo) {
    if (await run(() => taskApi.removeGroup(group.id))) showUndo({ kind: 'group', id: group.id, title: t('分组 {name}', { name: group.name }) });
  }
  async function restore() {
    if (!undo) return;
    window.clearTimeout(undoTimer.current);
    const target = undo;
    setUndo(null);
    await run(() => target.kind === 'group' ? taskApi.restoreGroup(target.id) : taskApi.restore(target.id));
  }
  const toggleSet = <T,>(set: Set<T>, value: T) => { const next = new Set(set); if (next.has(value)) next.delete(value); else next.add(value); return next; };

  const groupMenu = (group: GroupInfo, index: number): MenuEntry[] => [
    { label: t('添加任务'), onSelect: () => { setScope('all'); setAdding(group.id); } },
    { label: t('重命名…'), onSelect: () => openManager({ rename: group.id }) },
    { label: t('换颜色'), onSelect: () => void run(() => taskApi.updateGroup(group.id, { color: nextColor(group.color) })) },
    'separator',
    { label: t('上移'), disabled: index === 0, onSelect: () => void run(() => taskApi.moveGroup(group.id, -1)) },
    { label: t('下移'), disabled: index === groups.length - 1, onSelect: () => void run(() => taskApi.moveGroup(group.id, 1)) },
    'separator',
    { label: t('删除分组'), danger: true, disabled: groups.length <= 1, onSelect: () => void removeGroup(group) },
  ];
  const backgroundMenu = (): MenuEntry[] => [
    { label: t('新建分组…'), onSelect: () => openManager({ add: true }) },
    { label: t('管理分组…'), onSelect: () => openManager() },
    { label: t('管理标签…'), onSelect: () => setView('tags') },
    'separator',
    { label: scope === 'today' ? t('查看全部任务') : t('查看今天'), onSelect: () => { setRange(null); setScope(scope === 'today' ? 'all' : 'today'); } },
    { label: t('任务视图'), onSelect: () => void windowApi.openViews() },
    { label: t('收起为悬浮球'), onSelect: () => void collapse() },
  ];

  if (mode === 'bubble') return <Bubble tasks={tasks} groups={groups} hoverDetails={prefs.hoverExpand} onExpand={() => void expand()} />;

  const today = localDate();
  const allTags = collectTags(tasks);
  const activeTag = tag && allTags.includes(tag) ? tag : null;
  const shown = activeTag ? filterByTag(tasks, activeTag) : tasks;
  const views = buildGroups(shown, groups);
  const viewRange = range ?? { start: today, end: today };
  const todayData = buildToday(shown, groups, today, viewRange.start, viewRange.end);
  const lists = buildLists(shown, groups, today);
  const todayOnly = viewRange.start === today && viewRange.end === today;
  const marks = new Set(tasks.filter(task => task.due_date && !task.completed).map(task => task.due_date!));
  const scopeCount = scope === 'today' ? (todayOnly ? todayData.overdue.length + todayData.today.length : todayData.days.reduce((sum, day) => sum + day.tasks.length, 0))
    : scope === 'overdue' ? lists.overdue.length : scope === 'undated' ? lists.undatedCount : scope === 'done' ? lists.done.length : remaining;
  const chooseRange = (next: DateRange) => { setRange(next.start === today && next.end === today ? null : next); setScope('today'); };
  const chooseScope = (next: Scope) => { setScope(next); if (next !== 'today') setRange(null); setDayOpen(false); };
  const ranges = quickRanges(today);
  const activeFilter: FilterId | null = scope === 'today'
    ? (range ? RANGE_FILTERS.find(entry => ranges[entry.index].range.start === range.start && ranges[entry.index].range.end === range.end)?.id ?? null : 'today')
    : scope;
  const selectFilter = (id: FilterId) => {
    if (id === 'today') { setRange(null); setScope('today'); setDayOpen(false); return; }
    const entry = RANGE_FILTERS.find(item => item.id === id);
    if (entry) { chooseRange(ranges[entry.index].range); setDayOpen(false); return; }
    chooseScope(id as Scope);
  };
  // Dragging works from anywhere on the strip, perspective buttons included; a plain click still selects.
  const tabDrag = {
    onPointerDown: (event: React.PointerEvent) => { tabOrigin.current = event.button === 0 ? { x: event.clientX, y: event.clientY } : null; tabDragged.current = false; },
    onPointerMove: (event: React.PointerEvent) => {
      const origin = tabOrigin.current;
      if (!origin || tabDragged.current || event.buttons !== 1) return;
      if (Math.hypot(event.clientX - origin.x, event.clientY - origin.y) > 4) { tabDragged.current = true; tabOrigin.current = null; void windowApi.startDragging(); }
    },
    onPointerUp: () => { tabOrigin.current = null; },
    onClickCapture: (event: React.MouseEvent) => { if (tabDragged.current) { event.preventDefault(); event.stopPropagation(); tabDragged.current = false; } },
  };
  startFilter.current = selectFilter;
  const addNext = (task: TodoTask) => { if (task.parent_id) { setExpanded(new Set(expanded).add(task.parent_id)); setAddingSub(task.parent_id); } else setAdding(task.category); };
  const rowProps = { mutating, run, editing, setEditing, addingSub, setAddingSub, addNext, expanded, setExpanded, remove, toggleSet, groups, today, openMenu };

  return <TagContext.Provider value={{ active: activeTag, pick: next => setTag(activeTag === next ? null : next) }}><main className={`dt-window ${folded ? 'pose-folded' : ''} ${moving ? 'is-moving' : ''}`}>
    {view === 'tags' ? <><TagManager tasks={tasks} run={run} onSwitch={next => (next === 'groups' ? openManager() : setView('tags'))} onBack={() => setView('tasks')} onPick={name => { setTag(name); setScope('all'); setView('tasks'); }} />{error && <div className="dt-error" role="alert">{error}</div>}</>
    : view === 'groups' ? <><GroupManager groups={groups} tasks={tasks} run={run} intent={managerIntent} onSwitch={next => (next === 'tags' ? setView('tags') : openManager())} onBack={() => setView('tasks')} onDelete={group => void removeGroup(group)} />{error && <div className="dt-error" role="alert">{error}</div>}{undo && <div className="dt-toast" role="status"><span className="dt-toast-text">{t('已删除「{title}」', { title: undo.title })}</span><button onClick={() => void restore()}>{t('撤销')}</button></div>}</> : <>
    <header className="dt-head" data-tauri-drag-region>
      <div className="dt-tabs" data-tauri-drag-region {...tabDrag} role="tablist" aria-label={t('视图')} ref={strip}>
        {prefs.filters.map(id => ({ id, label: FILTER_LABELS[id] })).map(filter => <button key={filter.id} type="button" role="tab" data-filter={filter.id} aria-selected={activeFilter === filter.id} className={`dt-tab ${activeFilter === filter.id ? 'is-on' : ''}`} onClick={() => selectFilter(filter.id)}>
          {t(filter.label)}{filter.id === 'overdue' && lists.overdue.length > 0 && <i className="dt-tab-badge">{lists.overdue.length}</i>}
        </button>)}
      </div>
      <button type="button" aria-haspopup="dialog" aria-expanded={dayOpen} aria-label={activeFilter === null ? rangeLabel(viewRange, today) : t('日历')} className={`dt-icon dt-tab-more ${activeFilter === null ? 'is-on' : ''}`} title={t('选择日期、范围或其他视图')} onClick={() => setDayOpen(!dayOpen)}><ChevronDown className="dt-svg" strokeWidth={1.5} />{activeFilter === null && <span className="dt-range-label">{rangeLabel(viewRange, today)}</span>}</button>
      <button type="button" className="dt-icon" aria-label={t('任务视图')} title={t('任务视图')} onClick={() => void windowApi.openViews()}><Columns3 className="dt-svg" strokeWidth={1.5} /></button>
      {isDemo && <span className="dt-demo" data-tauri-drag-region>{t('演示')}</span>}
      <button className={`dt-icon dt-pin ${prefs.onTop ? 'is-on' : ''}`} aria-label={prefs.onTop ? t('取消置顶') : t('置顶窗口')} aria-pressed={prefs.onTop} title={prefs.onTop ? t('已置顶：悬浮在其他窗口之上') : t('置顶窗口')} onClick={() => void togglePin()}><PinIcon on={prefs.onTop} /></button>
      <button className={`dt-icon dt-lock ${prefs.locked ? 'is-on' : ''}`} aria-label={prefs.locked ? t('取消固定') : t('固定窗口')} aria-pressed={prefs.locked} title={prefs.locked ? t('已固定：不会自动收起，也不会淡出') : t('固定窗口：不自动收起，也不淡出')} onClick={() => void toggleLock()}>{prefs.locked ? <Lock className="dt-svg" strokeWidth={1.5} /> : <LockOpen className="dt-svg" strokeWidth={1.5} />}</button>
      <button className="dt-icon" aria-label={t('收起为悬浮球')} title={t('收起为悬浮球')} onClick={() => void collapse()}><Minimize2 className="dt-svg" strokeWidth={1.5} /></button>
    </header>
    {allTags.length > 0 && view === 'tasks' && <nav className="dt-tagbar" aria-label={t('标签')}>{allTags.map(name => <button key={name} type="button" className={`dt-tagbar-item ${activeTag === name ? 'is-on' : ''}`} aria-pressed={activeTag === name} onClick={() => setTag(activeTag === name ? null : name)}>#{name}</button>)}<button type="button" className="dt-tagbar-item dt-tagbar-manage" onClick={() => setView('tags')}>{t('管理…')}</button></nav>}
    {dayOpen && <DayPop range={viewRange} today={today} marks={marks} onRange={chooseRange} onClose={() => setDayOpen(false)} />}
    {(error || loadError) && <div className="dt-error" role="alert">{error || loadError}</div>}
    {availableUpdate && <div className="dt-set-note" role="status">{t('发现新版本 {version}', { version: availableUpdate.version ?? '' })} <button type="button" className="dt-link" onClick={() => { setAvailableUpdate(null); void windowApi.openSettings(); }}>{t('打开设置')}</button></div>}
    <div className="dt-scroll" onContextMenu={event => openMenu(event, backgroundMenu())}>
      {scope === 'today' ? <TodayList data={todayData} range={viewRange} groups={groups} today={today} upcomingOpen={upcomingOpen} setUpcomingOpen={setUpcomingOpen} foldedOpen={foldedOpen} setFoldedOpen={setFoldedOpen} toggleSet={toggleSet} hasTasks={tasks.length > 0} rowProps={rowProps} />
      : scope === 'overdue' || scope === 'undated' || scope === 'done' ? <ScopeList scope={scope} lists={lists} groups={groups} today={today} rowProps={rowProps} /> : <>
      {tasks.length === 0 && <p className="dt-empty">{t('把要做的事，放在这里。')}</p>}
      {views.map(({ group, open, done }, index) => <section className={`dt-group ${group.color} ${flash === group.id ? 'is-flash' : ''}`} key={group.id} aria-labelledby={`group-${group.id}`}>
        <div className={`dt-group-label ${group.color}`} onContextMenu={event => openMenu(event, groupMenu(group, index))}><b id={`group-${group.id}`}>{group.name}</b><span className="dt-group-tools"><button type="button" className="dt-icon dt-group-plus" aria-label={t('添加到「{name}」', { name: group.name })} title={t('在这个分组里添加任务')} onClick={() => { setScope('all'); setAdding(group.id); }}><Plus className="dt-svg" strokeWidth={1.5} /></button><span className="dt-n">{open.length}</span></span></div>
        <ul className="dt-list">{open.map((node, index) => <TaskItem key={node.task.id} node={node} prevId={index > 0 ? open[index - 1].task.id : null} first={index === 0} last={index === open.length - 1} {...rowProps} />)}</ul>
        <GroupAdd group={group} open={adding === group.id} onOpen={() => setAdding(group.id)} onClose={() => setAdding(null)} lastId={open.length ? open[open.length - 1].task.id : null} run={run} onIndented={id => setExpanded(new Set(expanded).add(id))} />
        {done.length > 0 && <>
          <button className="dt-folded" aria-expanded={foldedOpen.has(group.id)} onClick={() => setFoldedOpen(toggleSet(foldedOpen, group.id))}>
            <span className="dt-col"><ChevronRight className="dt-svg" strokeWidth={1.5} style={{ transform: foldedOpen.has(group.id) ? 'rotate(90deg)' : undefined, transition: 'transform var(--dur-fold)' }} /></span>{t('已完成')} {done.length}
          </button>
          {foldedOpen.has(group.id) && <ul className="dt-list">{done.map((node, index) => <TaskItem key={node.task.id} node={node} prevId={null} first={index === 0} last={index === done.length - 1} {...rowProps} />)}</ul>}
        </>}
      </section>)}
      </>}
    </div>
    {undo && <div className="dt-toast" role="status"><span className="dt-toast-text">{t('已删除「{title}」', { title: undo.title })}</span><button onClick={() => void restore()}>{t('撤销')}</button></div>}
    <TaskComposer tags={allTags} groups={groups} today={today} trailing={tasks.length ? t('还有 {n} 件', { n: scopeCount }) : ''} defaultDue={scope === 'today' ? viewRange.start : undefined} onNewGroup={() => openManager({ add: true })} onManageTags={() => setView('tags')} onManageGroups={() => openManager()} onAdd={(title, category, due) => run(() => taskApi.add(title, category, undefined, due))} />
    </>}
    {menu && <Menu state={menu} onClose={closeMenu} />}
    <ResizeGrips />
  </main></TagContext.Provider>;
}

interface ItemProps {
  node: TaskNode; prevId: string | null; groups: GroupInfo[]; today: string; openMenu: OpenMenu; first: boolean; last: boolean; mutating: boolean; run: Run;
  editing: string | null; setEditing: (id: string | null) => void;
  addingSub: string | null; setAddingSub: (id: string | null) => void; addNext: (task: TodoTask) => void;
  expanded: Set<string>; setExpanded: (next: Set<string>) => void;
  remove: (task: TodoTask) => Promise<void>;
  toggleSet: <T,>(set: Set<T>, value: T) => Set<T>;
}

/** The parent's circle split into one arc per subtask; finished subtasks are drawn in the accent colour. */
function SegmentRing({ count, done }: { count: number; done: number }) {
  const gap = count > 12 ? 0 : Math.min(14, 120 / count) ;
  const span = 100 / count;
  const gapUnits = gap / 3.6;
  return <svg className="dt-ring dt-segments" viewBox="0 0 21 21" aria-hidden="true">
    {Array.from({ length: count }, (_, index) => <circle key={index} cx="10.5" cy="10.5" r="9.75" pathLength="100" className={index < done ? 'is-done' : ''}
      strokeDasharray={`${Math.max(span - gapUnits, 1)} 100`} strokeDashoffset={-(index * span + gapUnits / 2)} />)}
  </svg>;
}

function TaskItem(props: ItemProps) {
  const { node, prevId, groups, today, openMenu, first, last, mutating, run, editing, setEditing, addingSub, setAddingSub, addNext, expanded, setExpanded, remove, toggleSet } = props;
  const { task, children } = node;
  const doneCount = children.filter(child => child.completed).length;
  const isOpen = expanded.has(task.id) || addingSub === task.id;
  const startSub = () => { setExpanded(new Set(expanded).add(task.id)); setAddingSub(task.id); };

  return <li className="dt-item">
    <TaskRow task={task} today={today} openMenu={openMenu} groups={groups} prevId={prevId} onIndented={id => setExpanded(new Set(expanded).add(id))} first={first} last={last} subCount={children.length} subDone={doneCount} expanded={isOpen} onToggleSub={() => setExpanded(toggleSet(expanded, task.id))}
      mutating={mutating} run={run} editing={editing === task.id} setEditing={setEditing} onAddSub={startSub} onNext={() => addNext(task)} remove={remove} />
    {(children.length > 0 || addingSub === task.id) && <ul className="dt-sub" hidden={!isOpen}>
      {children.map((child, index) => <li key={child.id} className="dt-item"><TaskRow task={child} sub today={today} openMenu={openMenu} groups={groups} prevId={null} onIndented={() => {}} first={index === 0} last={index === children.length - 1} subCount={0} subDone={0} expanded={false} onToggleSub={() => {}}
        mutating={mutating} run={run} editing={editing === child.id} setEditing={setEditing} onAddSub={() => {}} onNext={() => addNext(child)} remove={remove} /></li>)}
      {addingSub === task.id && <li className="dt-item"><SubAdd parent={task} run={run} close={() => setAddingSub(null)} /></li>}
    </ul>}
  </li>;
}

function Actions({ title, sub, flat, disabled, onAddSub, onDue, onDelete }: { title: string; sub?: boolean; flat?: boolean; disabled: boolean; onAddSub: () => void; onDue: () => void; onDelete: () => void }) {
  return <span className="dt-actions">
    {!sub && !flat && <button className="dt-icon" aria-label={t('添加子任务 {title}', { title })} title={t('添加子任务')} disabled={disabled} onClick={onAddSub}><Plus className="dt-svg" strokeWidth={1.5} /></button>}
    <button className="dt-icon" aria-label={t('设置到期日 {title}', { title })} title={t('到期日')} disabled={disabled} onClick={onDue}><CalendarDays className="dt-svg" strokeWidth={1.5} /></button>
    <button className="dt-icon is-danger" aria-label={t('删除 {title}', { title })} title={t('删除')} disabled={disabled} onClick={onDelete}><Trash2 className="dt-svg" size={15} strokeWidth={1.5} /></button>
  </span>;
}

interface RowProps {
  task: TodoTask; sub?: boolean; flat?: boolean; hideDue?: boolean; tag?: GroupInfo; today: string; openMenu: OpenMenu; groups: GroupInfo[]; prevId: string | null; onIndented: (parentId: string) => void;
  first: boolean; last: boolean; subCount: number; subDone: number; expanded: boolean; onToggleSub: () => void;
  mutating: boolean; run: Run; editing: boolean; setEditing: (id: string | null) => void; onAddSub: () => void; onNext?: () => void; remove: (task: TodoTask) => Promise<void>;
}

function TaskRow({ task, sub, flat, hideDue, tag, today, openMenu, groups, prevId, onIndented, first, last, subCount, subDone, expanded, onToggleSub, mutating, run, editing, setEditing, onAddSub, onNext, remove }: RowProps) {
  const [picking, setPicking] = useState(false);
  const progress = subCount ? subDone / subCount : 0;
  const due = task.due_date ? dueInfo(task.due_date, today) : null;
  const classes = ['dt-row', sub ? 'is-sub' : '', task.completed ? 'is-done' : '', subCount ? 'has-sub' : '', editing ? 'is-editing' : ''].filter(Boolean).join(' ');
  const toggle = () => void run(() => taskApi.patch(task.id, { completed: !task.completed }));
  const menuItems = (): MenuEntry[] => [
    ...(!sub && !flat && !task.completed ? [{ label: t('添加子任务'), onSelect: onAddSub }] : []),
    { label: task.due_date ? t('修改到期日…') : t('设置到期日…'), onSelect: () => setPicking(true) },
    ...(task.due_date ? [{ label: t('清除到期日'), onSelect: () => void run(() => taskApi.setDue(task.id, null)) }] : []),
    ...(!flat && !sub && prevId ? [{ label: t('缩进为上一条的子任务'), onSelect: () => void run(() => taskApi.reparent(task.id, prevId)).then(ok => { if (ok) onIndented(prevId); }) }] : []),
    ...(!flat && sub ? [{ label: t('取消缩进'), onSelect: () => void run(() => taskApi.reparent(task.id, null)) }] : []),
    ...(!flat ? [{ label: t('上移'), disabled: first, onSelect: () => void run(() => taskApi.move(task.id, -1)) }, { label: t('下移'), disabled: last, onSelect: () => void run(() => taskApi.move(task.id, 1)) }] : []),
    ...(!sub && groups.length > 1 ? ['separator' as const, ...groups.filter(group => group.id !== task.category).map(group => ({ label: t('移到「{name}」', { name: group.name }), dot: group.color, onSelect: () => void run(() => taskApi.patch(task.id, { category: group.id })) }))] : []),
    'separator',
    { label: t('删除'), danger: true, onSelect: () => void remove(task) },
  ];
  return <>
    <div className={classes} onContextMenu={event => openMenu(event, menuItems())}>
      <button className={`dt-check ${task.completed ? 'is-on' : ''} ${!task.completed && subCount > 1 ? 'is-seg' : ''}`} role="checkbox" aria-checked={task.completed} disabled={mutating} aria-label={t(task.completed ? '恢复 {title}' : '完成 {title}', { title: task.title })} onClick={toggle}>
        {task.completed ? <Check className="dt-svg" strokeWidth={2} /> : subCount > 1 ? <SegmentRing count={subCount} done={subDone} /> : subCount > 0 && progress > 0 && <svg className="dt-ring" viewBox="0 0 21 21" aria-hidden="true"><circle cx="10.5" cy="10.5" r="9.75" pathLength="100" strokeDasharray={`${progress * 100} 100`} /></svg>}
      </button>
      {editing
        ? <EditField task={task} sub={sub} groups={groups} prevId={prevId} onIndented={onIndented} run={run} close={() => setEditing(null)} onNext={onNext} />
        : <>
          <span className="dt-text" role="button" tabIndex={0} aria-label={t('编辑 {title}', { title: task.title })} onClick={() => setEditing(task.id)} onKeyDown={event => {
            if (event.key === 'Enter') setEditing(task.id);
            else if (event.altKey && !flat && (event.key === 'ArrowUp' || event.key === 'ArrowDown')) { event.preventDefault(); const down = event.key === 'ArrowDown'; if (down ? !last : !first) void run(() => taskApi.move(task.id, down ? 1 : -1)); }
          }}><TitleText title={task.title} /></span>
          {due && !hideDue && <button type="button" className={`dt-due is-${due.tone} ${task.completed ? 'is-done' : ''}`} aria-label={t('到期日 {date}，点击修改', { date: due.text })} aria-expanded={picking} onClick={() => setPicking(!picking)}>{due.text}</button>}
          {tag && <span className={`dt-tag ${tag.color}`}>{tag.name}</span>}
          {subCount > 0 && <button className="dt-subcount" aria-expanded={expanded} title={t('展开 / 收起子任务')} aria-label={t('子任务 {done}/{total}', { done: subDone, total: subCount })} onClick={onToggleSub}>{subDone}/{subCount}<ChevronRight className="dt-svg" strokeWidth={1.5} /></button>}
          <Actions title={task.title} sub={sub} flat={flat} disabled={mutating} onAddSub={onAddSub} onDue={() => setPicking(!picking)} onDelete={() => void remove(task)} />
        </>}
    </div>
    {picking && <DuePicker task={task} today={today} sub={sub} run={run} close={() => setPicking(false)} />}
  </>;
}

function DuePicker({ task, today, sub, run, close }: { task: TodoTask; today: string; sub?: boolean; run: Run; close: () => void }) {
  const choose = async (date: string | null) => { if (await run(() => taskApi.setDue(task.id, date))) close(); };
  return <div className={`dt-due-pop ${sub ? 'is-sub' : ''}`} role="group" aria-label={t('到期日')} onKeyDown={event => { if (event.key === 'Escape') close(); }}>
    <div className="dt-chips">
      {quickDates(today).map(quick => <button key={quick.label} type="button" className={task.due_date === quick.date ? 'is-on' : ''} onClick={() => void choose(quick.date)}>{quick.label}</button>)}
      {task.due_date && <button type="button" className="dt-chip-clear" onClick={() => void choose(null)}>{t('清除')}</button>}
    </div>
    <Calendar mode="single" today={today} value={task.due_date ? { start: task.due_date, end: task.due_date } : null} onChange={range => void choose(range.start)} />
  </div>;
}

interface RowProps2 { mutating: boolean; run: Run; editing: string | null; setEditing: (id: string | null) => void; remove: (task: TodoTask) => Promise<void>; openMenu: OpenMenu }

/** A flat list of tasks across groups, each row tagged with its group. */
function FlatRows({ items, groups, today, rowProps, hideDue }: { items: TodoTask[]; groups: GroupInfo[]; today: string; rowProps: RowProps2; hideDue?: boolean }) {
  return <ul className="dt-list">{items.map(task => <li className="dt-item" key={task.id}>
    <TaskRow task={task} flat hideDue={hideDue && task.due_date === today} today={today} openMenu={rowProps.openMenu} tag={groups.find(group => group.id === task.category)} groups={groups} prevId={null} onIndented={() => {}} first last subCount={0} subDone={0} expanded={false} onToggleSub={() => {}}
      mutating={rowProps.mutating} run={rowProps.run} editing={rowProps.editing === task.id} setEditing={rowProps.setEditing} onAddSub={() => {}} remove={rowProps.remove} />
  </li>)}</ul>;
}

function Section({ title, tone, count, children }: { title: string; tone: string; count: number; children: React.ReactNode }) {
  return count > 0 ? <section className="dt-group" aria-label={title}>
    <div className={`dt-group-label ${tone}`}><b>{title}</b><span className="dt-n">{count}</span></div>
    {children}
  </section> : null;
}

function Fold({ label, count, open, onToggle, children }: { label: string; count: number; open: boolean; onToggle: () => void; children: React.ReactNode }) {
  return count > 0 ? <section className="dt-group">
    <button className="dt-folded" aria-expanded={open} onClick={onToggle}>
      <span className="dt-col"><ChevronRight className="dt-svg" strokeWidth={1.5} style={{ transform: open ? 'rotate(90deg)' : undefined, transition: 'transform var(--dur-fold)' }} /></span>{label} {count}
    </button>
    {open && children}
  </section> : null;
}

interface TodayListProps {
  data: ReturnType<typeof buildToday>; range: DateRange; groups: GroupInfo[]; today: string; hasTasks: boolean;
  upcomingOpen: boolean; setUpcomingOpen: (open: boolean) => void;
  foldedOpen: Set<Category>; setFoldedOpen: (next: Set<Category>) => void; toggleSet: <T,>(set: Set<T>, value: T) => Set<T>;
  rowProps: RowProps2;
}

/** The day view: today (overdue, due today, the coming week) or any other day / range picked in the calendar. */
function TodayList({ data, range, groups, today, hasTasks, upcomingOpen, setUpcomingOpen, foldedOpen, setFoldedOpen, toggleSet, rowProps }: TodayListProps) {
  const doneKey = '__today_done__';
  const rows = (items: TodoTask[]) => <FlatRows items={items} groups={groups} today={today} rowProps={rowProps} />;
  const todayOnly = range.start === today && range.end === today;
  const dayTitle = (date: string) => { const name = dueInfo(date, today).text; const short = monthDay(date); return name === short ? `${weekdayShort(date)} · ${short}` : `${name} · ${short}`; };
  const doneFold = <Fold label={t('已完成')} count={data.done.length} open={foldedOpen.has(doneKey)} onToggle={() => setFoldedOpen(toggleSet(foldedOpen, doneKey))}>{rows(data.done)}</Fold>;
  if (!todayOnly) {
    return <>
      {data.days.map(day => <Section key={day.date} title={dayTitle(day.date)} tone="work" count={day.tasks.length}>{rows(day.tasks)}</Section>)}
      {data.days.length === 0 && <p className="dt-empty">{t('{day}没有安排。在下方添加，任务会定在这一天。', { day: rangeLabel(range, today) })}</p>}
      {doneFold}
    </>;
  }
  const none = data.overdue.length + data.today.length === 0;
  const empty = none && data.upcoming.length + data.done.length === 0;
  return <>
    <Section title={t('已逾期')} tone="is-overdue" count={data.overdue.length}>{rows(data.overdue)}</Section>
    <Section title={t('今天')} tone="work" count={data.today.length}><FlatRows items={data.today} groups={groups} today={today} rowProps={rowProps} hideDue /></Section>
    {none && <p className="dt-empty">{!hasTasks ? t('把要做的事，放在这里。') : empty ? t('今天没有安排。在下方添加，或在「全部」里给任务设置到期日。') : t('今天没有要做的事。')}</p>}
    <Fold label={t('接下来 {n} 天', { n: UPCOMING_DAYS })} count={data.upcoming.length} open={upcomingOpen} onToggle={() => setUpcomingOpen(!upcomingOpen)}>{rows(data.upcoming)}</Fold>
    {doneFold}
  </>;
}

/** Overdue, undated and completed perspectives across all groups. */
function ScopeList({ scope, lists, groups, today, rowProps }: { scope: 'overdue' | 'undated' | 'done'; lists: Lists; groups: GroupInfo[]; today: string; rowProps: RowProps2 }) {
  const rows = (items: TodoTask[]) => <FlatRows items={items} groups={groups} today={today} rowProps={rowProps} />;
  if (scope === 'overdue') return lists.overdue.length ? <Section title={t('已逾期')} tone="is-overdue" count={lists.overdue.length}>{rows(lists.overdue)}</Section> : <p className="dt-empty">{t('没有逾期的任务。')}</p>;
  if (scope === 'done') return lists.done.length ? <Section title={t('已完成')} tone="work" count={lists.done.length}>{rows(lists.done)}</Section> : <p className="dt-empty">{t('还没有完成的任务。')}</p>;
  return lists.undated.length ? <>{lists.undated.map(entry => <Section key={entry.group.id} title={entry.group.name} tone={entry.group.color} count={entry.tasks.length}>{rows(entry.tasks)}</Section>)}</> : <p className="dt-empty">{t('每个任务都有到期日。')}</p>;
}

function EditField({ task, sub, groups, prevId, onIndented, run, close, onNext }: { onNext?: () => void; task: TodoTask; sub?: boolean; groups: GroupInfo[]; prevId: string | null; onIndented: (parentId: string) => void; run: Run; close: () => void }) {
  const [title, setTitle] = useState(task.title);
  const [category, setCategory] = useState<Category>(task.category);
  const [menu, setMenu] = useState<MenuState | null>(null);
  const composing = useRef(false);
  const input = useRef<HTMLTextAreaElement>(null);
  const done = useRef(false);
  // The field grows with its text so Shift+Enter can add lines inside the task.
  useLayoutEffect(() => { const el = input.current; if (el) { el.style.height = 'auto'; el.style.height = `${el.scrollHeight}px`; } }, [title]);
  const save = async (): Promise<boolean> => {
    if (done.current) return true;
    const trimmed = title.trim();
    done.current = true;
    if (!trimmed || (trimmed === task.title && category === task.category)) { close(); return true; }
    const ok = await run(() => taskApi.patch(task.id, { ...(trimmed !== task.title ? { title: trimmed } : {}), ...(category !== task.category ? { category } : {}) }));
    if (ok) close(); else done.current = false;
    return ok;
  };
  const reparent = async (parentId: string | null) => {
    if (!await save()) return;
    if (await run(() => taskApi.reparent(task.id, parentId)) && parentId) onIndented(parentId);
  };
  const onKeyDown = async (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (isImeEvent(event, composing.current)) return;
    // Enter finishes this task and starts the next one beside it; Shift+Enter breaks the line inside this task.
    if (event.key === 'Enter' && event.shiftKey) return;
    if (event.key === 'Enter') { event.preventDefault(); if (await save()) onNext?.(); }
    else if (event.key === 'Escape') { event.preventDefault(); done.current = true; close(); }
    // Tab indents this task under the task above it; Shift+Tab brings a subtask back out.
    else if (event.key === 'Tab') {
      event.preventDefault();
      if (event.shiftKey) { if (sub) await reparent(null); }
      else if (!sub && prevId) await reparent(prevId);
    }
  };
  return <>
    <textarea ref={input} rows={1} className="dt-text-edit" aria-label={t('任务内容')} autoFocus value={title} onChange={event => setTitle(event.target.value)}
      onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }} onKeyDown={event => void onKeyDown(event)}
      onBlur={event => { if (!event.currentTarget.parentElement?.contains(event.relatedTarget as Node | null)) void save(); }} />
    {!sub && <button type="button" className={`dt-cat-pick ${groupColor(groups, category)}`} aria-haspopup="menu" aria-label={t('分组：{name}，点击选择', { name: groupName(groups, category) })} title={t('选择分组')}
      onClick={event => { const box = event.currentTarget.getBoundingClientRect(); setMenu({ x: box.left, y: box.bottom + 2, keyboard: false, items: groups.map(group => ({ label: group.name, dot: group.color, checked: group.id === category, onSelect: () => { setCategory(group.id); input.current?.focus(); } })) }); }}>{groupName(groups, category)}</button>}
    {menu && <Menu state={menu} onClose={() => setMenu(null)} />}
  </>;
}

/** The quiet "add a task" row at the bottom of a group. Tab indents the new task under the last one, Shift+Tab undoes that. */
function GroupAdd({ group, open, onOpen, onClose, lastId, run, onIndented }: { group: GroupInfo; open: boolean; onOpen: () => void; onClose: () => void; lastId: string | null; run: Run; onIndented: (parentId: string) => void }) {
  const [title, setTitle] = useState('');
  const [indent, setIndent] = useState(false);
  const composing = useRef(false);
  const busy = useRef(false);
  const parent = indent ? lastId : null;
  const close = () => { onClose(); setTitle(''); setIndent(false); };
  const add = async () => {
    const trimmed = title.trim();
    if (!trimmed || busy.current) return;
    busy.current = true;
    const ok = await run(() => taskApi.add(trimmed, group.id, parent ?? undefined));
    busy.current = false;
    if (ok) { setTitle(''); if (parent) onIndented(parent); }
  };
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (isImeEvent(event, composing.current)) return;
    if (event.key === 'Enter') { event.preventDefault(); void add(); }
    else if (event.key === 'Escape') { event.preventDefault(); close(); }
    else if (event.key === 'Tab') { event.preventDefault(); setIndent(!event.shiftKey && lastId !== null); }
  };
  if (!open) return <button type="button" className="dt-add-row" aria-label={t('在「{name}」下添加任务', { name: group.name })} onClick={onOpen}><Plus className="dt-svg" strokeWidth={1.5} />{t('添加任务')}</button>;
  return <div className={`dt-row is-editing dt-add-input ${indent ? 'is-sub' : ''}`}>
    <span className="dt-check" aria-hidden="true" style={{ borderStyle: 'dashed', cursor: 'default' }} />
    <input className="dt-text-edit" aria-label={t('新任务（{name}）', { name: group.name })} autoFocus value={title} placeholder={indent ? t('子任务') : t('写下一件小事')} onChange={event => setTitle(event.target.value)}
      onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }} onKeyDown={onKeyDown}
      onBlur={() => { if (!title.trim()) close(); }} />
  </div>;
}

function SubAdd({ parent, run, close }: { parent: TodoTask; run: Run; close: () => void }) {
  const [title, setTitle] = useState('');
  const composing = useRef(false);
  const busy = useRef(false);
  const add = async (asTopLevel: boolean) => {
    const trimmed = title.trim();
    if (!trimmed || busy.current) return;
    busy.current = true;
    const ok = await run(() => taskApi.add(trimmed, parent.category, asTopLevel ? undefined : parent.id));
    busy.current = false;
    if (ok) { setTitle(''); if (asTopLevel) close(); }
  };
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (isImeEvent(event, composing.current)) return;
    if (event.key === 'Enter') { event.preventDefault(); void add(false); }
    else if (event.key === 'Escape') { event.preventDefault(); close(); }
    else if (event.key === 'Tab') { event.preventDefault(); if (event.shiftKey) { if (title.trim()) void add(true); else close(); } }
  };
  return <div className="dt-row is-sub is-editing">
    <span className="dt-check" aria-hidden="true" style={{ borderStyle: 'dashed', cursor: 'default' }} />
    <input className="dt-text-edit" aria-label={t('新子任务')} autoFocus value={title} placeholder={t('子任务')} onChange={event => setTitle(event.target.value)}
      onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }} onKeyDown={onKeyDown}
      onBlur={() => { if (!title.trim()) close(); }} />
  </div>;
}

/** The calendar popover: pick a day or a range (week numbers shown), or one of the ready-made ranges. */
function DayPop({ range, today, marks, onRange, onClose }: { range: DateRange; today: string; marks: Set<string>; onRange: (range: DateRange) => void; onClose: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const outside = (event: PointerEvent) => { const target = event.target as HTMLElement; if (!ref.current?.contains(target) && !target.closest('.dt-tab-more')) onClose(); };
    document.addEventListener('pointerdown', outside, true);
    return () => document.removeEventListener('pointerdown', outside, true);
  }, [onClose]);
  const same = (a: DateRange) => a.start === range.start && a.end === range.end;
  return <div ref={ref} className="dt-day-pop" role="dialog" aria-label={t('日历')} onKeyDown={event => { if (event.key === 'Escape') onClose(); }}>
    <div className="dt-chips">
      {quickRanges(today).map(quick => <button key={quick.label} type="button" className={same(quick.range) ? 'is-on' : ''} onClick={() => onRange(quick.range)}>{quick.label}</button>)}
    </div>
    <Calendar mode="range" today={today} value={range} marks={marks} onChange={onRange} />
    <div className="dt-chips is-foot"><span className="dt-chips-spacer" /><button type="button" className="dt-link" onClick={onClose}>{t('完成')}</button></div>
  </div>;
}

/** A push-pin: upright and filled when the window is pinned on top, tilted and outlined when it is not. */
function PinIcon({ on }: { on: boolean }) {
  return <svg className={`dt-svg dt-pin-svg ${on ? 'is-on' : ''}`} viewBox="0 0 24 24" aria-hidden="true">
    <path d="M12 17v5" />
    <path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z" />
  </svg>;
}
