import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';

let ViewsWindow: typeof import('../src/Views').ViewsWindow;
let api: typeof import('../src/taskApi').taskApi;
let dates: typeof import('../src/dates');
beforeEach(async () => {
  vi.resetModules();
  window.history.pushState({}, '', '/?demo&views');
  ({ ViewsWindow } = await import('../src/Views'));
  api = (await import('../src/taskApi')).taskApi;
  dates = await import('../src/dates');
});
afterEach(cleanup);
async function ready() {
  render(<ViewsWindow />);
  await screen.findByRole('region', { name: '未排期' });
}
async function board() {
  await ready();
  fireEvent.click(screen.getByRole('tab', { name: '看板' }));
  return screen.getByRole('region', { name: '待办' });
}
it('keeps the view tabs in a draggable header and supports switching all views', async () => {
  await ready();
  const header = screen.getByRole('banner');
  expect(header.querySelector('[data-tauri-drag-region]')).toBeTruthy();
  expect(within(header).getByRole('tablist')).toBeTruthy();
  fireEvent.click(within(header).getByRole('tab', { name: '甘特' }));
  expect(screen.getByRole('tabpanel').id).toBe('dv-panel-gantt');
  fireEvent.click(within(header).getByRole('tab', { name: '看板' }));
  expect(screen.getByRole('tabpanel').id).toBe('dv-panel-board');
});

it('disables movement animations when reduced motion is requested', () => {
  const css = readFileSync('src/views.css', 'utf8');
  expect(css).toMatch(/@media\s*\(prefers-reduced-motion:\s*reduce\)/);
  expect(css).toMatch(/animation-name:\s*dv-fade/);
  expect(css).toMatch(/transition:\s*none/);
});
function transfer() {
  const data = new Map<string, string>();
  return { types: ['application/x-dotist-task'], effectAllowed: 'none', dropEffect: 'none',
    setData: (type: string, value: string) => data.set(type, value), getData: (type: string) => data.get(type) ?? '' };
}
function actions(title: string) { fireEvent.click(screen.getByLabelText(`任务操作 ${title}`)); }

it('renders the monthly calendar and unscheduled list; segment switches to three top-level-only columns and back', async () => {
  await ready();
  expect(screen.getByRole('grid')).toBeTruthy();
  expect(screen.getAllByRole('gridcell')).toHaveLength(42);
  expect(within(screen.getByRole('region', { name: '未排期' })).getByRole('article', { name: '给绿萝换盆' })).toBeTruthy();
  expect(within(screen.getByRole('grid')).queryByText('给绿萝换盆')).toBeNull();
  expect(screen.getByRole('tab', { name: '甘特' })).toBeTruthy();
  fireEvent.click(screen.getByRole('tab', { name: '看板' }));
  for (const name of ['待办', '进行中', '完成']) expect(screen.getByRole('region', { name })).toBeTruthy();
  expect(within(screen.getByRole('region', { name: '进行中' })).getByRole('article', { name: '回复项目消息' })).toBeTruthy();
  expect(screen.queryByRole('article', { name: '排进日历' })).toBeNull();
  expect(screen.getByText('子任务 1/3')).toBeTruthy();
  fireEvent.click(screen.getByRole('tab', { name: '日历' }));
  expect(screen.getByRole('grid')).toBeTruthy();
});

it('marks overdue with a triangle and text, and allows completing it from the selected day', async () => {
  await ready();
  const yesterday = dates.addDays(dates.localDate(), -1);
  fireEvent.click(screen.getByRole('gridcell', { name: dates.fullDate(yesterday) }));
  const card = await screen.findByRole('article', { name: '回复项目消息' });
  expect(within(card).getByText('已逾期').textContent).toContain('△');
  fireEvent.click(within(card).getByRole('checkbox', { name: '完成 回复项目消息' }));
  await waitFor(() => expect(within(screen.getByRole('article', { name: '回复项目消息' })).getByRole('checkbox').getAttribute('aria-checked')).toBe('true'));
  const task = (await api.list()).find(task => task.id === 'demo-1')!;
  expect([task.completed, task.status]).toEqual([true, 'done']);
  expect(within(screen.getByRole('article', { name: task.title })).queryByText('已逾期')).toBeNull();
});

it('moves a card across columns using drag/drop and keeps completed in sync', async () => {
  await board();
  const card = screen.getByRole('article', { name: '整理本周的工作计划' });
  const dataTransfer = transfer();
  fireEvent.dragStart(card, { dataTransfer });
  fireEvent.dragOver(screen.getByRole('region', { name: '完成' }), { dataTransfer });
  fireEvent.drop(screen.getByRole('region', { name: '完成' }), { dataTransfer });
  await within(screen.getByRole('region', { name: '完成' })).findByRole('article', { name: '整理本周的工作计划' });
  expect((await api.list()).filter(task => task.id === 'demo-0' || task.parent_id === 'demo-0').every(task => task.completed && task.status === 'done')).toBe(true);
});

it('changes status without dragging, preserves doing when editing dates, and restores todo when unchecked', async () => {
  await board();
  actions('给绿萝换盆');
  fireEvent.change(screen.getByRole('combobox', { name: '状态 给绿萝换盆' }), { target: { value: 'doing' } });
  const doing = await within(screen.getByRole('region', { name: '进行中' })).findByRole('article', { name: '给绿萝换盆' });
  expect(within(doing).getByRole('checkbox').getAttribute('aria-checked')).toBe('false');
  actions('给绿萝换盆');
  fireEvent.change(screen.getByLabelText('到期日 给绿萝换盆'), { target: { value: '2027-03-10' } });
  await waitFor(async () => expect((await api.list()).find(task => task.id === 'demo-7')?.due_date).toBe('2027-03-10'));
  expect((await api.list()).find(task => task.id === 'demo-7')?.status).toBe('doing');
  fireEvent.click(within(screen.getByRole('article', { name: '给绿萝换盆' })).getByRole('checkbox'));
  await within(screen.getByRole('region', { name: '完成' })).findByRole('article', { name: '给绿萝换盆' });
  fireEvent.click(within(screen.getByRole('article', { name: '给绿萝换盆' })).getByRole('checkbox'));
  await within(screen.getByRole('region', { name: '待办' })).findByRole('article', { name: '给绿萝换盆' });
  expect((await api.list()).find(task => task.id === 'demo-7')?.status).toBe('todo');
});

it('reorders cards within a status column using the non-drag controls', async () => {
  await board();
  const column = screen.getByRole('region', { name: '待办' });
  const before = within(column).getAllByRole('article').map(card => card.getAttribute('aria-label'));
  actions(before[1]!);
  fireEvent.click(screen.getByRole('button', { name: `上移 ${before[1]}` }));
  await waitFor(() => expect(within(column).getAllByRole('article')[0].getAttribute('aria-label')).toBe(before[1]));
});

it.each(['drag', 'button'] as const)('board %s reordering keeps other status tasks in their relative position', async method => {
  await board();
  const column = screen.getByRole('region', { name: '待办' });
  const source = within(column).getByRole('article', { name: '整理本周的工作计划' });
  const target = within(column).getByRole('article', { name: '下班后散步，顺路买些水果' });
  if (method === 'drag') {
    const dataTransfer = transfer();
    fireEvent.dragStart(source, { dataTransfer });
    fireEvent.drop(target, { dataTransfer });
  } else {
    actions('整理本周的工作计划');
    fireEvent.click(screen.getByRole('button', { name: '下移 整理本周的工作计划' }));
  }
  await waitFor(() => expect(within(column).getAllByRole('article')[0].getAttribute('aria-label')).toBe('下班后散步，顺路买些水果'));
  const tasks = (await api.list()).filter(task => ['demo-0', 'demo-1', 'demo-6'].includes(task.id)).sort((a, b) => a.position - b.position || a.id.localeCompare(b.id));
  expect(tasks.map(task => task.id)).toEqual(['demo-1', 'demo-6', 'demo-0']);
});

it('reorders calendar cards without changing their date or group', async () => {
  await ready();
  const section = screen.getByRole('region', { name: dates.fullDate(dates.localDate()) });
  const source = within(section).getByRole('article', { name: '下班后散步，顺路买些水果' });
  const target = within(section).getByRole('article', { name: '整理本周的工作计划' });
  target.getBoundingClientRect = () => new DOMRect(0, 0, 200, 40);
  const before = (await api.list()).find(task => task.id === 'demo-6')!;
  const dataTransfer = transfer();
  fireEvent.dragStart(source, { dataTransfer });
  fireEvent.dragOver(target, { dataTransfer, clientY: 10 });
  fireEvent.drop(target, { dataTransfer, clientY: 10 });
  await waitFor(() => expect(within(section).getAllByRole('article')[0].getAttribute('aria-label')).toBe('下班后散步，顺路买些水果'));
  const after = (await api.list()).find(task => task.id === before.id)!;
  expect([after.category, after.due_date]).toEqual([before.category, before.due_date]);
});

it('reorders summaries within a day without writing the due date again', async () => {
  await ready();
  const day = screen.getByRole('gridcell', { name: dates.fullDate(dates.localDate()) });
  const source = within(day).getByText('提交周报');
  const target = within(day).getByText('整理本周的工作计划');
  target.getBoundingClientRect = () => new DOMRect(0, 0, 200, 40);
  const setDue = vi.spyOn(api, 'setDue');
  const dataTransfer = transfer();
  fireEvent.dragStart(source, { dataTransfer });
  fireEvent.dragOver(target, { dataTransfer, clientY: 10 });
  fireEvent.drop(target, { dataTransfer, clientY: 10 });
  await waitFor(() => expect(day.querySelector('.dv-day-task')?.textContent).toContain('提交周报'));
  expect(setDue).not.toHaveBeenCalled();
});

it('provides non-drag ordering controls for calendar cards', async () => {
  await ready();
  const section = screen.getByRole('region', { name: dates.fullDate(dates.localDate()) });
  const before = within(section).getAllByRole('article').map(card => card.getAttribute('aria-label'));
  actions(before[1]!);
  fireEvent.click(within(section).getByRole('button', { name: `上移 ${before[1]}` }));
  await waitFor(() => expect(within(section).getAllByRole('article')[0].getAttribute('aria-label')).toBe(before[1]));
});

it('reorders Gantt labels without changing the task dates', async () => {
  await ready();
  fireEvent.click(screen.getByRole('tab', { name: '甘特' }));
  const panel = screen.getByRole('tabpanel');
  const source = within(panel).getByText('下班后散步，顺路买些水果', { selector: 'strong' }).closest('.dv-gantt-label')!;
  const target = within(panel).getByText('整理本周的工作计划', { selector: 'strong' }).closest('.dv-gantt-label')!;
  target.getBoundingClientRect = () => new DOMRect(0, 0, 200, 40);
  const before = (await api.list()).find(task => task.id === 'demo-6')!;
  const dataTransfer = transfer();
  fireEvent.dragStart(source, { dataTransfer });
  fireEvent.dragOver(target, { dataTransfer, clientY: 10 });
  fireEvent.drop(target, { dataTransfer, clientY: 10 });
  await waitFor(() => expect(document.querySelector('.dv-gantt-row .dv-gantt-label strong')?.textContent).toBe('下班后散步，顺路买些水果'));
  const after = (await api.list()).find(task => task.id === before.id)!;
  expect([after.start_date, after.due_date]).toEqual([before.start_date, before.due_date]);
});

it('does not reorder an unscheduled card onto a scheduled Gantt row', async () => {
  await ready();
  fireEvent.click(screen.getByRole('tab', { name: '甘特' }));
  const panel = screen.getByRole('tabpanel');
  const source = within(panel).getByRole('article', { name: '给绿萝换盆' });
  const target = within(panel).getByText('整理本周的工作计划', { selector: 'strong' }).closest('.dv-gantt-label')!;
  const reorder = vi.spyOn(api, 'reorder');
  const dataTransfer = transfer();
  fireEvent.dragStart(source, { dataTransfer });
  fireEvent.dragOver(target, { dataTransfer });
  fireEvent.drop(target, { dataTransfer });
  expect(reorder).not.toHaveBeenCalled();
  expect((await api.list()).find(task => task.id === 'demo-7')?.due_date).toBeNull();
});

it('supports keyboard ordering of scheduled Gantt rows', async () => {
  await ready();
  fireEvent.click(screen.getByRole('tab', { name: '甘特' }));
  const panel = screen.getByRole('tabpanel');
  const labels = panel.querySelectorAll('.dv-gantt-row .dv-gantt-label');
  const first = labels[0].querySelector('strong')?.textContent;
  const second = labels[1].querySelector('strong')?.textContent;
  fireEvent.keyDown(labels[1], { key: 'ArrowUp', altKey: true });
  await waitFor(() => expect(panel.querySelector('.dv-gantt-row .dv-gantt-label strong')?.textContent).toBe(second));
  expect(panel.querySelectorAll('.dv-gantt-row .dv-gantt-label strong')[1].textContent).toBe(first);
});

it('reschedules an unscheduled task by dragging to a day, and by using its date input', async () => {
  await ready();
  const today = dates.localDate();
  const dataTransfer = transfer();
  fireEvent.dragStart(screen.getByRole('article', { name: '给绿萝换盆' }), { dataTransfer });
  fireEvent.drop(screen.getByRole('gridcell', { name: dates.fullDate(today) }), { dataTransfer });
  await within(screen.getByRole('region', { name: dates.fullDate(today) })).findByRole('article', { name: '给绿萝换盆' });
  expect(within(screen.getByRole('region', { name: '未排期' })).queryByText('给绿萝换盆')).toBeNull();
  actions('给绿萝换盆');
  fireEvent.change(screen.getByLabelText('到期日 给绿萝换盆'), { target: { value: '' } });
  await within(screen.getByRole('region', { name: '未排期' })).findByRole('article', { name: '给绿萝换盆' });
});

it('moves date focus with arrow keys across month boundaries and switches segments from the keyboard', async () => {
  await ready();
  const today = dates.localDate();
  const day = screen.getByRole('gridcell', { name: dates.fullDate(today) });
  day.focus();
  fireEvent.keyDown(day, { key: 'ArrowDown' });
  const next = await screen.findByRole('gridcell', { name: dates.fullDate(dates.addDays(today, 7)) });
  await waitFor(() => expect(document.activeElement).toBe(next));
  expect(next.getAttribute('aria-selected')).toBe('true');
  const tab = screen.getByRole('tab', { name: '日历' });
  fireEvent.keyDown(tab, { key: 'ArrowRight' });
  expect(screen.getByRole('tab', { name: '看板' }).getAttribute('aria-selected')).toBe('true');
  expect(document.activeElement).toBe(screen.getByRole('tab', { name: '看板' }));
});

it('shows write errors without moving the card or losing the task', async () => {
  await board();
  vi.spyOn(api, 'patch').mockRejectedValueOnce(new Error('写入失败'));
  actions('给绿萝换盆');
  fireEvent.change(screen.getByRole('combobox', { name: '状态 给绿萝换盆' }), { target: { value: 'done' } });
  expect((await screen.findByRole('alert')).textContent).toContain('写入失败');
  expect(within(screen.getByRole('region', { name: '待办' })).getByRole('article', { name: '给绿萝换盆' })).toBeTruthy();
});

it('refreshes from a cross-window tasks-changed broadcast', async () => {
  const { windowApi } = await import('../src/windowApi');
  let changed = () => {};
  vi.spyOn(windowApi, 'on').mockImplementation((async (event: string, handler: () => void) => { if (event === 'tasks-changed') changed = handler; return () => {}; }) as never);
  await board();
  await api.patch('demo-7', { status: 'doing' });
  act(() => changed());
  await within(screen.getByRole('region', { name: '进行中' })).findByRole('article', { name: '给绿萝换盆' });
});


it('renders gantt ranges, single days, unscheduled top-level tasks and switches scale', async () => {
  const today = dates.localDate();
  await api.setDateRange('demo-0', dates.addDays(today, -2), dates.addDays(today, 2));
  await ready();
  fireEvent.click(screen.getByRole('tab', { name: '甘特' }));
  const range = screen.getByRole('button', { name: '甘特任务 整理本周的工作计划' });
  expect(range.classList.contains('is-single')).toBe(false);
  expect(screen.getByRole('button', { name: '甘特任务 下班后散步，顺路买些水果' }).classList.contains('is-single')).toBe(true);
  expect(within(screen.getByRole('region', { name: '未排期' })).getByRole('article', { name: '给绿萝换盆' })).toBeTruthy();
  expect(screen.queryByRole('button', { name: '甘特任务 排进日历' })).toBeNull();
  expect(screen.getByText('子任务 1/3')).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: '周' }));
  expect(screen.getByRole('button', { name: '周' }).getAttribute('aria-pressed')).toBe('true');
  expect(document.querySelectorAll('.dv-gantt-dates span')).toHaveLength(7);
});

it('moves dates by keyboard and retains them when an invalid end is rejected', async () => {
  const today = dates.localDate().slice(0, 7) + '-10';
  await api.setDateRange('demo-0', today, dates.addDays(today, 1));
  await ready(); fireEvent.click(screen.getByRole('tab', { name: '甘特' }));
  fireEvent.keyDown(screen.getByRole('button', { name: '甘特任务 整理本周的工作计划' }), { key: 'ArrowRight' });
  await waitFor(async () => expect((await api.list()).find(task => task.id === 'demo-0')?.start_date).toBe(dates.addDays(today, 1)));
  fireEvent.keyDown(screen.getByRole('button', { name: '甘特任务 整理本周的工作计划' }), { key: 'ArrowLeft', shiftKey: true });
  await waitFor(async () => expect((await api.list()).find(task => task.id === 'demo-0')?.due_date).toBe(dates.addDays(today, 1)));
  fireEvent.keyDown(screen.getByRole('button', { name: '甘特任务 整理本周的工作计划' }), { key: 'ArrowLeft', shiftKey: true });
  expect((await screen.findByRole('alert')).textContent).toContain('开始日不能晚于到期日');
  expect((await api.list()).find(task => task.id === 'demo-0')?.due_date).toBe(dates.addDays(today, 1));
});

it('hides and removes the outgoing panel after switching', async () => {
  await ready();
  fireEvent.click(screen.getByRole('tab', { name: '看板' }));
  expect(screen.getByRole('tabpanel').id).toBe('dv-panel-board');
  expect(document.querySelector('.dv-panel-exit')?.getAttribute('aria-hidden')).toBe('true');
  await waitFor(() => expect(document.querySelector('.dv-panel-exit')).toBeNull());
});

it('reorders cards by dropping on another card', async () => {
  await board();
  const column = screen.getByRole('region', { name: '待办' });
  const cards = within(column).getAllByRole('article');
  const first = cards[0].getAttribute('aria-label');
  const second = cards[1].getAttribute('aria-label');
  const dataTransfer = transfer();
  fireEvent.dragStart(cards[0], { dataTransfer });
  fireEvent.drop(cards[1], { dataTransfer });
  await waitFor(() => expect(within(column).getAllByRole('article').slice(0, 2).map(card => card.getAttribute('aria-label'))).toEqual([second, first]));
});

it('previews both gantt edges and rolls back a failed write', async () => {
  const start = dates.localDate().slice(0, 7) + '-10';
  const end = dates.addDays(start, 4);
  await api.setDateRange('demo-0', start, end);
  await ready(); fireEvent.click(screen.getByRole('tab', { name: '甘特' }));
  const bar = screen.getByRole('button', { name: '甘特任务 整理本周的工作计划' });
  const originalPointer = window.PointerEvent;
  window.PointerEvent = MouseEvent as typeof PointerEvent;
  bar.setPointerCapture = () => {};
  const count = document.querySelectorAll('.dv-gantt-dates span').length;
  bar.getBoundingClientRect = () => new DOMRect(100, 0, 100, 20);
  bar.parentElement!.getBoundingClientRect = () => new DOMRect(0, 0, count * 10, 20);
  try {
    fireEvent.pointerDown(bar, { button: 0, clientX: 101 });
    fireEvent.pointerMove(bar, { clientX: 111 });
    expect(bar.title).toBe(`${dates.addDays(start, 1)} – ${end}`);
    expect(screen.getByRole('status').textContent).toContain(dates.addDays(start, 1));
    fireEvent.pointerUp(bar, { clientX: 111 });
    await waitFor(async () => expect((await api.list()).find(task => task.id === 'demo-0')?.start_date).toBe(dates.addDays(start, 1)));
    await waitFor(() => expect(bar.title).toBe(`${dates.addDays(start, 1)} – ${end}`));
    vi.spyOn(api, 'setDateRange').mockRejectedValueOnce(new Error('写入失败'));
    fireEvent.pointerDown(bar, { button: 0, clientX: 199 });
    fireEvent.pointerMove(bar, { clientX: 209 });
    expect(bar.title).toBe(`${dates.addDays(start, 1)} – ${dates.addDays(end, 1)}`);
    fireEvent.pointerUp(bar, { clientX: 209 });
    expect((await screen.findByRole('alert')).textContent).toContain('写入失败');
    await waitFor(() => expect(bar.title).toBe(`${dates.addDays(start, 1)} – ${end}`));
    expect((await api.list()).find(task => task.id === 'demo-0')?.due_date).toBe(end);
  } finally { window.PointerEvent = originalPointer; }
});

it('keeps view styles free of important overrides in both stylesheets', () => {
  expect(readFileSync('src/views.css', 'utf8')).not.toMatch(/!important/);
  expect(readFileSync('src/app.css', 'utf8')).not.toMatch(/\.dv-/);
});
