import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { trayTitles, upcoming } from '../src/trayTitles';
import type { TodoTask } from '../src/types';

afterEach(cleanup);
const task = (id: string, title: string, due: string | null, extra: Partial<TodoTask> = {}): TodoTask => ({ id, title, category: 'work', completed: false, status: extra.completed ? 'done' : 'todo', start_date: null, position: 0, created_at: '', updated_at: '', deleted_at: null, revision: 1, parent_id: null, due_date: due, ...extra });
const groups = [{ id: 'work', name: '工作', color: 'work', position: 0 }];
const TODAY = '2026-10-30';
const tasks = [task('a', '没日期的事', null), task('b', '交季度报告', '2026-11-03'), task('c', '今天的会', TODAY), task('d', '做完了', TODAY, { completed: true }), task('e', '子任务', TODAY, { parent_id: 'c' })];

it('orders open tasks by due date, undated last', () => {
  expect(upcoming(tasks, groups).map(t => t.id)).toEqual(['c', 'e', 'b', 'a']);
});

it('menu bar text for each mode', () => {
  expect(trayTitles('icon', tasks, groups, TODAY)).toEqual([]);
  expect(trayTitles('count', tasks, groups, TODAY)).toEqual(['3']);
  expect(trayTitles('next', tasks, groups, TODAY)).toEqual(['今天的会']);
  expect(trayTitles('next_date', tasks, groups, TODAY)).toEqual(['今天 今天的会']);
  const rotate = trayTitles('rotate', tasks, groups, TODAY);
  expect(rotate[0]).toBe('还有 3 件');
  expect(rotate).toContain('今天 今天的会');
  expect(rotate.some(line => line.includes('交季度报告'))).toBe(true);
  expect(trayTitles('next', [], groups, TODAY)).toEqual(['没有待办']);
});

it('menu bar text can be narrowed to a date perspective and a group', () => {
  const two = [{ id: 'life', name: '生活', color: 'life', position: 1 }, ...groups];
  const mixed = [
    task('w1', '工作今天', TODAY), task('w2', '工作逾期', '2026-10-20'), task('w3', '工作下周', '2026-11-04'),
    task('l1', '生活今天', TODAY, { category: 'life' }), task('l2', '生活无日期', null, { category: 'life' }), task('l3', '生活完成', TODAY, { category: 'life', completed: true }),
  ];
  expect(trayTitles('count', mixed, two, TODAY, 'today')).toEqual(['3']);
  expect(trayTitles('count', mixed, two, TODAY, 'today', 'life')).toEqual(['1']);
  expect(trayTitles('count', mixed, two, TODAY, 'overdue')).toEqual(['1']);
  expect(trayTitles('next', mixed, two, TODAY, 'overdue')).toEqual(['工作逾期']);
  expect(trayTitles('count', mixed, two, TODAY, 'undated')).toEqual(['1']);
  expect(trayTitles('next', mixed, two, TODAY, 'undated', 'work')).toEqual(['没有待办']);
  expect(trayTitles('count', mixed, two, TODAY, 'done')).toEqual(['1']);
  expect(trayTitles('next', mixed, two, TODAY, 'done')).toEqual(['生活完成']);
  expect(trayTitles('count', mixed, two, TODAY, 'week')).toEqual(['2']);
  expect(trayTitles('count', mixed, two, TODAY, 'nextweek')).toEqual(['1']);
  expect(trayTitles('count', mixed, two, TODAY, 'all', 'life')).toEqual(['2']);
});

it('long titles are clipped for the menu bar', () => {
  const long = [task('x', '这是一个非常非常非常非常非常非常非常非常长的任务标题', null)];
  const [line] = trayTitles('next', long, groups, TODAY);
  expect(line.length).toBeLessThanOrEqual(24);
  expect(line.endsWith('…')).toBe(true);
});

let QuickAdd: typeof import('../src/QuickAdd').QuickAdd;
beforeEach(async () => {
  vi.resetModules();
  window.history.pushState({}, '', '/?demo&quick');
  ({ QuickAdd } = await import('../src/QuickAdd'));
});

it('the quick-add panel adds a task on Enter, to the chosen group and due date, and dismisses itself', async () => {
  const { windowApi } = await import('../src/windowApi');
  const done = vi.spyOn(windowApi, 'quickDone').mockResolvedValue();
  const { taskApi } = await import('../src/taskApi');
  render(<QuickAdd />);
  const input = await screen.findByRole('textbox', { name: '快速添加' });
  await screen.findByRole('button', { name: /分组：工作/ });
  fireEvent.keyDown(input, { key: 'Tab' });
  await screen.findByRole('button', { name: /分组：生活/ });
  fireEvent.click(screen.getByRole('button', { name: '设置到期日' }));
  await screen.findByRole('button', { name: /到期日：今天/ });
  fireEvent.change(input, { target: { value: '快速记一笔' } });
  fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
  await waitFor(() => expect(done).toHaveBeenCalledWith(true));
  const added = (await taskApi.list()).find(item => item.title === '快速记一笔');
  expect(added?.category).toBe('life');
  expect(added?.due_date).toBeTruthy();
  expect((input as HTMLInputElement).value).toBe('');
});

it('Escape dismisses the quick-add panel without adding, and IME Enter does not submit', async () => {
  const { windowApi } = await import('../src/windowApi');
  const done = vi.spyOn(windowApi, 'quickDone').mockResolvedValue();
  render(<QuickAdd />);
  const input = await screen.findByRole('textbox', { name: '快速添加' });
  fireEvent.change(input, { target: { value: '拼音中' } });
  fireEvent.keyDown(input, { key: 'Enter', keyCode: 229, isComposing: true });
  expect(done).not.toHaveBeenCalled();
  fireEvent.keyDown(input, { key: 'Escape' });
  expect(done).toHaveBeenCalledWith(false);
});
