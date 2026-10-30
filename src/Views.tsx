import { Check, ChevronLeft, ChevronRight, ArrowUp, ArrowDown } from 'lucide-react';
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type DragEvent, type KeyboardEvent } from 'react';
import { addDays, addMonths, fullDate, localDate, monthTitle, parseDate, weekdayShort, weekStartsOn } from './dates';
import { setLanguage, t, tError } from './i18n';
import { applyTheme, settingsApi, type SettingsView } from './settingsApi';
import { taskApi } from './taskApi';
import { groupColor, groupName, type GroupInfo, type TaskStatus, type TodoTask } from './types';
import { windowApi } from './windowApi';
import './views.css';

const STATUSES: { id: TaskStatus; label: string }[] = [
  { id: 'todo', label: '待办' }, { id: 'doing', label: '进行中' }, { id: 'done', label: '完成' },
];
const DRAG_TYPE = 'application/x-dotist-task';
const errorMessage = (reason: unknown) => tError(reason instanceof Error ? reason.message : String(reason));
const order = (a: TodoTask, b: TodoTask) => a.position - b.position || a.id.localeCompare(b.id);
type Change = (operation: () => Promise<void>, finished?: () => void) => void;
function beginDrag(event: DragEvent, task: TodoTask) {
  event.dataTransfer.setData(DRAG_TYPE, task.id);
  event.dataTransfer.effectAllowed = 'move';
}
function acceptDrag(event: DragEvent) {
  if (event.dataTransfer.types.includes(DRAG_TYPE)) { event.preventDefault(); event.dataTransfer.dropEffect = 'move'; }
}
function Overdue({ task, today }: { task: TodoTask; today: string }) {
  return task.due_date && task.due_date < today && !task.completed
    ? <span className="dv-overdue"><span aria-hidden="true">△</span> {t('已逾期')}</span> : null;
}
function TaskCard({ task, tasks, groups, today, change, board = false, first, last, busy }: {
  task: TodoTask; tasks: TodoTask[]; groups: GroupInfo[]; today: string; change: Change;
  board?: boolean; first?: boolean; last?: boolean; busy: boolean;
}) {
  const children = tasks.filter(child => child.parent_id === task.id);
  return <article data-task-id={task.id} className={`dv-card ${task.completed ? 'is-done' : ''}`} aria-label={task.title}
    draggable={!busy} onDragStart={event => beginDrag(event, task)}>
    <div className="dv-task-title">
      <button type="button" role="checkbox" aria-checked={task.completed} disabled={busy}
        aria-label={t(task.completed ? '恢复 {title}' : '完成 {title}', { title: task.title })}
        className={`dt-check ${task.completed ? 'is-on' : ''}`}
        onClick={() => change(() => taskApi.patch(task.id, { completed: !task.completed }))}>
        {task.completed && <Check className="dt-svg" />}
      </button>
      <span className="dv-task-text">{task.title}</span>
    </div>
    <div className="dv-meta">
      <span className={`dv-group ${groupColor(groups, task.category)}`}><span aria-hidden="true">●</span> {groupName(groups, task.category)}</span>
      {task.parent_id && <span>{t('子任务')}</span>}
      {task.due_date && <time dateTime={task.due_date}>{task.due_date}</time>}
      <Overdue task={task} today={today} />
      {board && <span>{t('子任务 {done}/{total}', { done: children.filter(child => child.completed).length, total: children.length })}</span>}
    </div>
    <details className="dv-actions">
      <summary aria-label={t('任务操作 {title}', { title: task.title })}>{t('调整任务')}</summary>
      <div className="dv-fields">
        <label>{t('状态')}<select aria-label={t('状态 {title}', { title: task.title })} value={task.status} disabled={busy}
          onChange={event => change(() => taskApi.patch(task.id, { status: event.target.value as TaskStatus }))}>
          {STATUSES.map(status => <option key={status.id} value={status.id}>{t(status.label)}</option>)}
        </select></label>
        <label>{t('开始日')}<input type="date" aria-label={t('开始日 {title}', { title: task.title })} disabled={busy}
          value={task.start_date ?? ''} max={task.due_date ?? undefined}
          onChange={event => change(() => taskApi.setStart(task.id, event.target.value || null))} /></label>
        <label>{t('到期日')}<input type="date" aria-label={t('到期日 {title}', { title: task.title })} disabled={busy}
          value={task.due_date ?? ''} min={task.start_date ?? undefined}
          onChange={event => change(() => taskApi.setDue(task.id, event.target.value || null))} /></label>
        {board && <div className="dv-reorder">
          <button type="button" disabled={busy || first} aria-label={t('上移 {title}', { title: task.title })} onClick={() => change(() => taskApi.moveStatus(task.id, -1))}><ArrowUp size={16} />{t('上移')}</button>
          <button type="button" disabled={busy || last} aria-label={t('下移 {title}', { title: task.title })} onClick={() => change(() => taskApi.moveStatus(task.id, 1))}><ArrowDown size={16} />{t('下移')}</button>
        </div>}
      </div>
    </details>
  </article>;
}

const dayDistance = (a: string, b: string) => Math.round((Date.parse(b + 'T00:00:00Z') - Date.parse(a + 'T00:00:00Z')) / 86400000);
function Gantt({ tasks, groups, today, change, busy }: { tasks: TodoTask[]; groups: GroupInfo[]; today: string; change: Change; busy: boolean }) {
  const [scale, setScale] = useState<'week' | 'month'>('month');
  const [preview, setPreview] = useState<{ id: string; delta: number; edge: 'start' | 'end' | 'move'; task: TodoTask } | null>(null);
  const [dragging, setDragging] = useState(false);
  const [anchor, setAnchor] = useState(today);
  const first = scale === 'week' ? addDays(anchor, -((parseDate(anchor).getDay() - weekStartsOn() + 7) % 7)) : anchor.slice(0, 7) + '-01';
  const end = scale === 'week' ? addDays(first, 7) : addMonths(first, 1);
  const count = dayDistance(first, end);
  const top = tasks.filter(task => !task.parent_id).sort(order);
  const drag = useRef<{ task: TodoTask; x: number; width: number; edge: 'start' | 'end' | 'move' } | null>(null);
  const shift = (task: TodoTask, delta: number, edge: 'start' | 'end' | 'move', finished?: () => void) => {
    if (!delta) { finished?.(); return; }
    const start = task.start_date && edge !== 'end' ? addDays(task.start_date, delta) : task.start_date;
    const due = task.due_date && edge !== 'start' ? addDays(task.due_date, delta) : task.due_date;
    change(() => taskApi.setDateRange(task.id, start, due), finished);
  };
  return <>
    <div className="dv-month-nav"><h2 aria-live="polite">{first} – {addDays(end, -1)}</h2>
      <div className="dv-segments" aria-label={t('时间尺度')}>
        <button type="button" aria-pressed={scale === 'week'} onClick={() => setScale('week')}>{t('周')}</button>
        <button type="button" aria-pressed={scale === 'month'} onClick={() => setScale('month')}>{t('月')}</button>
      </div>
      <button type="button" aria-label={t('上一段')} onClick={() => setAnchor(scale === 'week' ? addDays(anchor, -7) : addMonths(anchor, -1))}><ChevronLeft size={18} /></button>
      <button type="button" onClick={() => setAnchor(today)}>{t('今天')}</button>
      <button type="button" aria-label={t('下一段')} onClick={() => setAnchor(scale === 'week' ? addDays(anchor, 7) : addMonths(anchor, 1))}><ChevronRight size={18} /></button>
    </div>
    <p className="dv-hint">{t('拖动横条或边缘调整日期；也可在「调整任务」中输入日期。')}</p>
    <div className="dv-gantt">
      <div className="dv-gantt-head"><span></span><div className="dv-gantt-dates">{Array.from({ length: count }, (_, i) => <span key={i}>{parseDate(addDays(first, i)).getDate()}</span>)}</div></div>
      {top.filter(task => task.start_date || task.due_date).map(task => {
        const delta = preview?.id === task.id ? preview.delta : 0;
        const base = preview?.id === task.id ? preview.task : task;
        const begin = addDays(base.start_date ?? base.due_date!, preview?.edge === 'end' ? 0 : delta);
        const finish = addDays(base.due_date ?? base.start_date!, preview?.edge === 'start' ? 0 : delta);
        const rawLeft = dayDistance(first, begin), rawRight = dayDistance(first, finish) + 1;
        const left = preview?.id === task.id ? Math.min(count - 1, Math.max(0, rawLeft)) : Math.max(0, rawLeft);
        const right = preview?.id === task.id ? Math.max(left + 1, Math.min(count, rawRight)) : Math.min(count, rawRight);
        const children = tasks.filter(child => child.parent_id === task.id);
        return <div className="dv-gantt-row" key={task.id}>
          <div className="dv-gantt-label"><span className={`dv-group ${groupColor(groups, task.category)}`}><span aria-hidden="true">●</span> {groupName(groups, task.category)}</span> <strong>{task.completed ? '✓ ' : ''}{task.title}</strong> {children.length > 0 && <span>{t('子任务 {done}/{total}', { done: children.filter(child => child.completed).length, total: children.length })}</span>} <Overdue task={task} today={today} />
            <TaskCard {...{ task, tasks, groups, today, change, busy }} />
          </div>
          <div className="dv-gantt-track" style={{ backgroundSize: `${100 / count}% 100%` }}> {today >= first && today < end && <span className="dv-today-line" style={{ left: `${(dayDistance(first, today) + .5) / count * 100}%` }} />}
            {right > left && <div role="button" tabIndex={0} aria-label={t('甘特任务 {title}', { title: task.title })} title={`${begin} – ${finish}`} className={`dv-gantt-bar ${groupColor(groups, task.category)} ${task.completed ? 'is-done' : ''} ${begin === finish ? 'is-single' : ''} ${dragging && preview?.id === task.id ? 'is-dragging' : ''}`} style={{ left: `${left / count * 100}%`, width: `${(right - left) / count * 100}%` }}
              onPointerDown={event => { if (busy || event.button !== 0) return; const rect = event.currentTarget.getBoundingClientRect(); const track = event.currentTarget.parentElement!.getBoundingClientRect(); const offset = event.clientX - rect.left; drag.current = { task, x: event.clientX, width: track.width, edge: task.start_date && begin >= first && offset < Math.min(8, rect.width / 2) ? 'start' : task.due_date && finish < end && offset > rect.width - Math.min(8, rect.width / 2) ? 'end' : 'move' }; setPreview({ id: task.id, delta: 0, edge: drag.current.edge, task }); setDragging(true); event.currentTarget.setPointerCapture(event.pointerId); }}
              onPointerMove={event => { const item = drag.current; if (item && item.width) setPreview({ id: task.id, delta: Math.round((event.clientX - item.x) / item.width * count), edge: item.edge, task: item.task }); }}
              onPointerUp={event => { const item = drag.current; drag.current = null; setDragging(false); if (item && item.width) { const delta = Math.round((event.clientX - item.x) / item.width * count); setPreview({ id: task.id, delta, edge: item.edge, task: item.task }); shift(item.task, delta, item.edge, () => setPreview(null)); } else setPreview(null); }} onPointerCancel={() => { drag.current = null; setDragging(false); setPreview(null); }}
              onKeyDown={event => { if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); shift(task, event.key === 'ArrowLeft' ? -1 : 1, event.shiftKey ? 'end' : 'move'); } }}>{task.completed ? '✓' : ''}{preview?.id === task.id && dragging && <span className="dv-gantt-tooltip" role="status">{begin} – {finish}</span>}</div>}
          </div>
        </div>;
      })}
    </div>
    <section className="dv-gantt-unscheduled" aria-label={t('未排期')}><h2>{t('未排期')}</h2>{top.filter(task => !task.start_date && !task.due_date).map(task => <TaskCard key={task.id} {...{ task, tasks, groups, today, change, busy }} />)}</section>
  </>;
}

export function ViewsWindow() {
  const [view, setView] = useState<'calendar' | 'board' | 'gantt'>('calendar');
  const [dropColumn, setDropColumn] = useState<TaskStatus | null>(null);
  const [tasks, setTasks] = useState<TodoTask[]>([]);
  const [groups, setGroups] = useState<GroupInfo[]>([]);
  const [today, setToday] = useState(localDate);
  const [selected, setSelected] = useState(today);
  const [month, setMonth] = useState(today.slice(0, 7) + '-01');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const active = useRef(true);
  const changing = useRef(false);
  const request = useRef(0);
  const panelHost = useRef<HTMLDivElement>(null);
  const oldPanel = useRef<HTMLElement | null>(null);
  const panelTimer = useRef<number | undefined>(undefined);
  const boardFirst = useRef<Map<string, DOMRect> | null>(null);
  const captureBoard = (id?: string, x?: number, y?: number) => {
    const rects = new Map<string, DOMRect>();
    panelHost.current?.querySelectorAll<HTMLElement>('.dv-board .dv-card').forEach(node => {
      const rect = node.getBoundingClientRect();
      rects.set(node.dataset.taskId!, node.dataset.taskId === id && x && y ? new DOMRect(x - rect.width / 2, y - rect.height / 2, rect.width, rect.height) : rect);
    });
    boardFirst.current = rects;
  };
  useLayoutEffect(() => {
    const first = boardFirst.current; boardFirst.current = null;
    if (!first || window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return;
    panelHost.current?.querySelectorAll<HTMLElement>('.dv-board .dv-card').forEach(node => {
      const before = first.get(node.dataset.taskId!); if (!before) return;
      const after = node.getBoundingClientRect(); const x = before.left - after.left, y = before.top - after.top;
      if ((x || y) && node.animate) {
        const tokens = getComputedStyle(node); const duration = tokens.getPropertyValue('--dur-collapse').trim();
        node.animate([{ transform: `translate(${x}px, ${y}px)` }, { transform: 'none' }], { duration: duration.endsWith('ms') ? parseFloat(duration) : parseFloat(duration) * 1000 || 220, easing: tokens.getPropertyValue('--ease-smooth').trim() || 'cubic-bezier(0.22, 1, 0.36, 1)' });
      }
    });
  }, [tasks]);
  const switchView = (next: typeof view) => {
    if (next === view) return;
    oldPanel.current?.remove(); window.clearTimeout(panelTimer.current);
    const panel = panelHost.current?.querySelector<HTMLElement>('.dv-panel');
    if (panel && panelHost.current) {
      const clone = panel.cloneNode(true) as HTMLElement; clone.removeAttribute('id'); clone.setAttribute('aria-hidden', 'true'); clone.setAttribute('inert', ''); clone.querySelectorAll('[id], [aria-label]').forEach(node => { node.removeAttribute('id'); node.removeAttribute('aria-label'); }); clone.classList.add('dv-panel-exit');
      panelHost.current.appendChild(clone); oldPanel.current = clone;
      panelTimer.current = window.setTimeout(() => { clone.remove(); if (oldPanel.current === clone) oldPanel.current = null; }, 120);
    }
    setView(next);
  };
  const load = useCallback(async () => {
    const sequence = ++request.current;
    try {
      const [next, nextGroups] = await Promise.all([taskApi.list(), taskApi.groups()]);
      if (active.current && sequence === request.current) { setTasks(next); setGroups(nextGroups); }
    } catch (reason) { if (active.current) setError(errorMessage(reason)); }
    finally { if (active.current) setLoading(false); }
  }, []);
  useEffect(() => {
    active.current = true;
    void load();
    const apply = (settings: SettingsView) => { applyTheme(settings.theme); setLanguage(settings.language); };
    void settingsApi.get().then(next => { if (active.current) apply(next); }, reason => { if (active.current) setError(errorMessage(reason)); });
    const listeners = [windowApi.on('tasks-changed', () => void load()), windowApi.on<SettingsView>('settings-changed', apply)];
    const refresh = () => { setToday(localDate()); void load(); };
    window.addEventListener('focus', refresh);
    const timer = window.setInterval(refresh, 3000);
    return () => {
      active.current = false;
      request.current += 1;
      window.clearInterval(timer);
      window.clearTimeout(panelTimer.current); oldPanel.current?.remove();
      window.removeEventListener('focus', refresh);
      listeners.forEach(off => void off.then(unlisten => unlisten()));
    };
  }, [load]);
  const change: Change = (operation, finished) => {
    if (changing.current) return;
    changing.current = true; setBusy(true); setError('');
    void operation().then(load).catch(reason => { if (active.current) setError(errorMessage(reason)); })
      .finally(() => { changing.current = false; if (active.current) { setBusy(false); finished?.(); } });
  };
  const drop = (event: DragEvent, operation: (id: string) => Promise<void>) => {
    const id = event.dataTransfer.getData(DRAG_TYPE);
    if (!tasks.some(task => task.id === id) || busy) return;
    event.preventDefault();
    change(() => operation(id));
  };
  const choose = (date: string, focus = false) => {
    setSelected(date); setMonth(date.slice(0, 7) + '-01');
    if (focus) requestAnimationFrame(() => document.getElementById(`dv-day-${date}`)?.focus());
  };
  const dayKeys = (event: KeyboardEvent, date: string) => {
    const delta: Record<string, number> = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 };
    if (event.key in delta) { event.preventDefault(); choose(addDays(date, delta[event.key]), true); }
    else if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); choose(date); }
  };
  const start = addDays(month, -((parseDate(month).getDay() - weekStartsOn() + 7) % 7));
  const days = Array.from({ length: 42 }, (_, index) => addDays(start, index));
  const card = (task: TodoTask, board = false, first = false, last = false) => <TaskCard key={task.id} {...{ task, tasks, groups, today, change, board, first, last, busy }} />;
  return <div className="dv-window">
    <a className="dv-skip" href="#dv-content">{t('跳转到任务视图')}</a>
    <header className="dv-header"><div className="dv-drag" data-tauri-drag-region /><h1>{t('任务视图')}</h1>
      <div className="dv-segments" role="tablist" aria-label={t('任务视图')}>
        {(['calendar', 'board', 'gantt'] as const).map(mode => <button type="button" key={mode} id={`dv-tab-${mode}`} role="tab"
          aria-controls={`dv-panel-${mode}`} aria-selected={view === mode} tabIndex={view === mode ? 0 : -1}
          onClick={() => switchView(mode)} onKeyDown={event => {
            if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
              event.preventDefault();
              const modes = ['calendar', 'board', 'gantt'] as const;
              const next = event.key === 'Home' ? 'calendar' : event.key === 'End' ? 'gantt' : modes[(modes.indexOf(view) + (event.key === 'ArrowRight' ? 1 : 2)) % 3];
              switchView(next); document.getElementById(`dv-tab-${next}`)?.focus();
            }
          }}>{t(mode === 'calendar' ? '日历' : mode === 'board' ? '看板' : '甘特')}</button>)}
      </div>
    </header>
    <main id="dv-content" className="dv-content">
      {error && <div className="dv-error" role="alert">{error}<button type="button" onClick={() => { setError(''); void load(); }}>{t('重试')}</button></div>}
      <div className="dv-panel-host" ref={panelHost}>{loading ? <p role="status">{t('正在读取任务…')}</p> : <section key={view} className="dv-panel" role="tabpanel" id={`dv-panel-${view}`} aria-labelledby={`dv-tab-${view}`}>
        {view === 'calendar' ? <>
          <div className="dv-month-nav">
            <h2 aria-live="polite">{monthTitle(month)}</h2>
            <button type="button" aria-label={t('上个月')} onClick={() => setMonth(addMonths(month, -1))}><ChevronLeft size={18} /></button>
            <button type="button" onClick={() => choose(today)}>{t('今天')}</button>
            <button type="button" aria-label={t('下个月')} onClick={() => setMonth(addMonths(month, 1))}><ChevronRight size={18} /></button>
          </div>
          <div className="dv-calendar-layout">
            <div className="dv-month" role="grid" aria-label={monthTitle(month)}>
              <div className="dv-week" role="row">{days.slice(0, 7).map(date => <span role="columnheader" key={date}>{weekdayShort(date)}</span>)}</div>
              {Array.from({ length: 6 }, (_, week) => <div className="dv-week" role="row" key={week}>
                {days.slice(week * 7, week * 7 + 7).map(date => {
                  const due = tasks.filter(task => task.due_date === date).sort(order);
                  return <div role="gridcell" key={date} id={`dv-day-${date}`} aria-label={fullDate(date)} aria-selected={selected === date}
                    aria-current={date === today ? 'date' : undefined} tabIndex={date === selected || (selected.slice(0, 7) !== month.slice(0, 7) && date === month) ? 0 : -1}
                    className={`dv-day ${date.slice(0, 7) !== month.slice(0, 7) ? 'is-outside' : ''}`}
                    onClick={() => choose(date)} onKeyDown={event => dayKeys(event, date)} onDragOver={acceptDrag} onDrop={event => drop(event, id => taskApi.setDue(id, date))}>
                    <span className="dv-day-number">{parseDate(date).getDate()}</span>
                    {due.slice(0, 2).map(task => <span key={task.id} className={`dv-day-task ${task.completed ? 'is-done' : ''}`} draggable={!busy}
                      onDragStart={event => beginDrag(event, task)} title={task.title}>
                      <span aria-hidden="true">{task.completed ? '✓' : task.due_date! < today ? '△' : '·'}</span> {task.title}
                    </span>)}
                    {due.length > 2 && <span className="dv-more">{t('另有 {n} 件', { n: due.length - 2 })}</span>}
                  </div>;
                })}
              </div>)}
            </div>
            <aside className="dv-agenda">
              <section aria-label={fullDate(selected)}><h2>{fullDate(selected)}</h2>
                {tasks.filter(task => task.due_date === selected).sort(order).map(task => card(task))}
                {!tasks.some(task => task.due_date === selected) && <p className="dv-empty">{t('当天没有任务')}</p>}
              </section>
              <section aria-label={t('未排期')}><h2>{t('未排期')} <span>{tasks.filter(task => !task.due_date).length}</span></h2>
                {tasks.filter(task => !task.due_date).sort(order).map(task => card(task))}
                {!tasks.some(task => !task.due_date) && <p className="dv-empty">{t('所有任务均已排期')}</p>}
              </section>
            </aside>
          </div>
          <p className="dv-hint">{t('方向键选择日期；拖动任务调整到期日，也可在「调整任务」中选择日期。')}</p>
        </> : view === 'gantt' ? <Gantt {...{ tasks, groups, today, change, busy }} /> : <>
          <p className="dv-hint">{t('拖动任务更改状态；也可在「调整任务」中更改状态或上下排序。')}</p>
          <div className="dv-board">{STATUSES.map(status => {
            const column = tasks.filter(task => !task.parent_id && task.status === status.id).sort(order);
            return <section className={`dv-column dv-${status.id} ${dropColumn === status.id ? 'is-drop-target' : ''}`} key={status.id} aria-label={t(status.label)}
              onDragOver={event => { acceptDrag(event); if (event.defaultPrevented) setDropColumn(status.id); }}
              onDragLeave={event => { if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setDropColumn(null); }}
              onDrop={event => { setDropColumn(null); const id = event.dataTransfer.getData(DRAG_TYPE); const task = tasks.find(item => item.id === id); if (!task || busy) return; captureBoard(id, event.clientX, event.clientY); const target = (event.target as HTMLElement).closest<HTMLElement>('.dv-card'); const targetId = target?.dataset.taskId; const from = column.findIndex(item => item.id === id); const to = column.findIndex(item => item.id === targetId); drop(event, async () => { if (task.status !== status.id) await taskApi.patch(id, { status: status.id }); else if (from >= 0 && to >= 0) { const direction = from < to ? 1 : -1; for (let i = 0; i < Math.abs(to - from); i++) await taskApi.moveStatus(id, direction); } }); }} onDragEnd={() => setDropColumn(null)}>
              <h2><span className="dv-status-shape" aria-hidden="true">{status.id === 'done' ? '✓' : ''}</span>{t(status.label)} <span>{column.length}</span></h2>
              {column.map((task, index) => card(task, true, index === 0, index === column.length - 1))}
              {!column.length && <p className="dv-empty">{t('暂无任务')}</p>}
            </section>;
          })}</div>
        </>}
      </section>}</div>
    </main>
  </div>;
}
