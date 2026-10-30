import { expect, it } from 'vitest';
import { addDays, daysBetween, dueInfo, localDate, quickDates } from '../src/dates';
import { buildToday } from '../src/todayView';
import type { TodoTask } from '../src/types';

// 2026-10-30 is a Friday.
const TODAY = '2026-10-30';

it('formats local dates and does calendar arithmetic across month and year ends', () => {
  expect(localDate(new Date(2026, 0, 5))).toBe('2026-01-05');
  expect(addDays('2026-10-30', 3)).toBe('2026-11-02');
  expect(addDays('2026-12-31', 1)).toBe('2027-01-01');
  expect(addDays('2026-03-01', -1)).toBe('2026-02-28');
  expect(daysBetween('2026-10-30', '2026-11-02')).toBe(3);
});

it('labels due dates relative to today with a tone', () => {
  expect(dueInfo('2026-10-30', TODAY)).toEqual({ text: '今天', tone: 'today' });
  expect(dueInfo('2026-10-31', TODAY)).toEqual({ text: '明天', tone: 'soon' });
  expect(dueInfo('2026-11-02', TODAY)).toEqual({ text: '周一', tone: 'soon' });
  expect(dueInfo('2026-11-20', TODAY)).toEqual({ text: '11月20日', tone: 'later' });
  expect(dueInfo('2027-01-03', TODAY)).toEqual({ text: '2027年1月3日', tone: 'later' });
  expect(dueInfo('2026-10-29', TODAY)).toEqual({ text: '昨天', tone: 'overdue' });
  expect(dueInfo('2026-10-02', TODAY)).toEqual({ text: '10月2日', tone: 'overdue' });
});

it('offers today, tomorrow and the next Monday as shortcuts', () => {
  expect(quickDates(TODAY)).toEqual([{ label: '今天', date: '2026-10-30' }, { label: '明天', date: '2026-10-31' }, { label: '下周一', date: '2026-11-02' }]);
  expect(quickDates('2026-11-02')[2].date).toBe('2026-11-09');
  expect(quickDates('2026-11-01')[2].date).toBe('2026-11-02');
});

const task = (id: string, due: string | null, extra: Partial<TodoTask> = {}): TodoTask => ({ id, title: id, category: 'work', completed: false, status: extra.completed ? 'done' : 'todo', start_date: null, position: 0, created_at: '', updated_at: '2026-10-01T00:00:00.000Z', deleted_at: null, revision: 1, parent_id: null, due_date: due, ...extra });
const groups = [{ id: 'work', name: '工作', color: 'work', position: 0 }, { id: 'life', name: '生活', color: 'life', position: 1 }];

it('splits tasks into overdue, today, the coming week and done', () => {
  const data = buildToday([
    task('late', '2026-10-20'), task('now-b', TODAY, { category: 'life' }), task('now-a', TODAY), task('soon', '2026-11-05'), task('far', '2026-12-01'),
    task('none', null), task('done-today', TODAY, { completed: true }), task('done-old', '2026-10-10', { completed: true }),
    task('done-late-today', '2026-10-25', { completed: true, updated_at: new Date(2026, 9, 30, 9).toISOString() }),
  ], groups, TODAY);
  expect(data.overdue.map(t => t.id)).toEqual(['late']);
  expect(data.today.map(t => t.id)).toEqual(['now-a', 'now-b']);
  expect(data.upcoming.map(t => t.id)).toEqual(['soon']);
  expect(data.done.map(t => t.id).sort()).toEqual(['done-late-today', 'done-today']);
});
