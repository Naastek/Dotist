import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';

let ViewsWindow: typeof import('../src/Views').ViewsWindow;
let api: typeof import('../src/taskApi').taskApi;
let dates: typeof import('../src/dates');
beforeEach(async () => {
  vi.resetModules();
  window.history.pushState({}, '', '/?demo&views');
  ({ ViewsWindow } = await import('../src/Views'));
  api = (await import('../src/taskApi')).taskApi;
  dates = await import('../src/dates');
  render(<ViewsWindow />);
  await screen.findByRole('region', { name: '未排期' });
});
afterEach(cleanup);

it('switches between month, week and day while navigating the selected date', () => {
  const today = dates.localDate();
  const scales = screen.getByLabelText('日历视图');
  expect(within(scales).getByRole('button', { name: '月' }).getAttribute('aria-pressed')).toBe('true');
  expect(screen.getAllByRole('gridcell')).toHaveLength(42);
  fireEvent.click(within(scales).getByRole('button', { name: '周' }));
  expect(screen.getAllByRole('gridcell')).toHaveLength(7);
  expect(within(screen.getByRole('gridcell', { name: dates.fullDate(today) })).getByText('整理本周的工作计划')).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: '下一段' }));
  expect(screen.getByRole('gridcell', { name: dates.fullDate(dates.addDays(today, 7)) }).getAttribute('aria-selected')).toBe('true');
  fireEvent.click(within(scales).getByRole('button', { name: '日' }));
  expect(screen.getAllByRole('gridcell')).toHaveLength(1);
  fireEvent.click(screen.getByRole('button', { name: '今天' }));
  expect(within(screen.getByRole('region', { name: dates.fullDate(today) })).getByRole('article', { name: '整理本周的工作计划' })).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: '上一段' }));
  expect(screen.getByRole('gridcell', { name: dates.fullDate(dates.addDays(today, -1)) })).toBeTruthy();
  fireEvent.click(within(scales).getByRole('button', { name: '月' }));
  expect(screen.getAllByRole('gridcell')).toHaveLength(42);
});

it('moves a task to another day in week view and retains its group', async () => {
  const today = dates.localDate();
  fireEvent.click(within(screen.getByLabelText('日历视图')).getByRole('button', { name: '周' }));
  const source = within(screen.getByRole('gridcell', { name: dates.fullDate(today) })).getByText('整理本周的工作计划');
  const targetDate = dates.addDays(today, dates.parseDate(today).getDay() === 1 ? 1 : -1);
  const target = screen.getByRole('gridcell', { name: dates.fullDate(targetDate) });
  const data = new Map<string, string>();
  const dataTransfer = { types: ['application/x-dotist-task'], effectAllowed: 'none', dropEffect: 'none', setData: (key: string, value: string) => data.set(key, value), getData: (key: string) => data.get(key) ?? '' };
  const before = (await api.list()).find(task => task.id === 'demo-0')!;
  fireEvent.dragStart(source, { dataTransfer });
  fireEvent.drop(target, { dataTransfer });
  await waitFor(async () => expect((await api.list()).find(task => task.id === before.id)?.due_date).toBe(targetDate));
  expect((await api.list()).find(task => task.id === before.id)?.category).toBe(before.category);
});

it('groups Gantt rows by existing group, collapses them, and keeps grouping independent of task data', async () => {
  fireEvent.click(screen.getByRole('tab', { name: '甘特' }));
  const before = await api.list();
  fireEvent.click(within(screen.getByLabelText('排序方式')).getByRole('button', { name: '按分组' }));
  const panel = screen.getByRole('tabpanel');
  const headings = [...panel.querySelectorAll('.dv-gantt-group > button')];
  expect(headings.map(node => node.textContent)).toEqual(expect.arrayContaining([expect.stringContaining('工作'), expect.stringContaining('生活')]));
  expect(headings.findIndex(node => node.textContent?.includes('工作'))).toBeLessThan(headings.findIndex(node => node.textContent?.includes('生活')));
  const work = headings.find(node => node.textContent?.includes('工作'))!;
  expect(work.getAttribute('aria-expanded')).toBe('true');
  fireEvent.click(work);
  expect(work.getAttribute('aria-expanded')).toBe('false');
  expect(panel.querySelector('[data-task-id="demo-0"][data-sort-scope="gantt"]')).toBeNull();
  fireEvent.click(work);
  expect(panel.querySelector('[data-task-id="demo-0"][data-sort-scope="gantt"]')).toBeTruthy();
  expect(await api.list()).toEqual(before);
  fireEvent.click(within(screen.getByLabelText('排序方式')).getByRole('button', { name: '手动排序' }));
  expect(panel.querySelector('.dv-gantt-group')).toBeNull();
});

it('keeps keyboard ordering inside its Gantt group', async () => {
  fireEvent.click(screen.getByRole('tab', { name: '甘特' }));
  fireEvent.click(within(screen.getByLabelText('排序方式')).getByRole('button', { name: '按分组' }));
  const panel = screen.getByRole('tabpanel');
  const labels = [...panel.querySelectorAll<HTMLElement>('.dv-gantt-label')];
  const firstLife = labels.find(node => node.dataset.taskId === 'demo-6')!;
  const reorder = vi.spyOn(api, 'reorder');
  fireEvent.keyDown(firstLife, { key: 'ArrowUp', altKey: true });
  expect(reorder).not.toHaveBeenCalled();
  const secondWork = labels.find(node => node.dataset.taskId === 'demo-1')!;
  fireEvent.keyDown(secondWork, { key: 'ArrowUp', altKey: true });
  await waitFor(() => expect(reorder).toHaveBeenCalledWith('demo-1', 'demo-0', false, true));
});

it('shows each group range from its earliest start to latest due date, clipped to the visible month', async () => {
  const first = dates.localDate().slice(0, 7) + '-01';
  const nextMonth = dates.addMonths(first, 1);
  await api.setDateRange('demo-0', dates.addDays(first, -2), null);
  await api.setDateRange('demo-1', null, dates.addDays(first, 5));
  await api.setDateRange('demo-2', dates.addDays(first, 2), dates.addDays(first, 3));
  fireEvent.focus(window);
  await waitFor(async () => expect((await api.list()).find(task => task.id === 'demo-0')?.start_date).toBe(dates.addDays(first, -2)));
  fireEvent.click(screen.getByRole('tab', { name: '甘特' }));
  fireEvent.click(within(screen.getByLabelText('排序方式')).getByRole('button', { name: '按分组' }));
  const group = screen.getByRole('button', { name: /工作/ }).closest('.dv-gantt-group')!;
  const range = group.querySelector<HTMLElement>('.dv-gantt-group-range')!;
  const daysInMonth = dates.daysBetween(first, nextMonth);
  expect(parseFloat(range.style.left)).toBe(0);
  expect(parseFloat(range.style.width)).toBeCloseTo(6 / daysInMonth * 100);
  await api.setDateRange('demo-1', null, dates.addDays(nextMonth, 3));
  fireEvent.focus(window);
  await waitFor(() => expect(parseFloat(group.querySelector<HTMLElement>('.dv-gantt-group-range')!.style.width)).toBe(100));
});

it('does not reorder tasks across groups while the grouped Gantt view is active', async () => {
  fireEvent.click(screen.getByRole('tab', { name: '甘特' }));
  fireEvent.click(within(screen.getByLabelText('排序方式')).getByRole('button', { name: '按分组' }));
  const panel = screen.getByRole('tabpanel');
  const source = panel.querySelector<HTMLElement>('[data-task-id="demo-0"][data-sort-scope="gantt"]')!;
  const target = panel.querySelector<HTMLElement>('[data-task-id="demo-6"][data-sort-scope="gantt"]')!;
  const values = new Map<string, string>();
  const dataTransfer = { types: ['application/x-dotist-task'], effectAllowed: 'none', dropEffect: 'none', setData: (key: string, value: string) => values.set(key, value), getData: (key: string) => values.get(key) ?? '' };
  const reorder = vi.spyOn(api, 'reorder');
  fireEvent.dragStart(source, { dataTransfer });
  fireEvent.drop(target, { dataTransfer });
  expect(reorder).not.toHaveBeenCalled();
});
