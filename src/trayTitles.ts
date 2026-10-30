import { dueInfo, inRange, quickRanges } from './dates';
import { t } from './i18n';
import type { FilterId, TrayMode } from './settingsApi';
import type { GroupInfo, TodoTask } from './types';

const LIMIT = 24;
const clip = (text: string) => (text.length > LIMIT ? `${text.slice(0, LIMIT - 1)}…` : text);

/** Open tasks in the order they are due: dated ones by date, then the rest by group and position. */
export function upcoming(tasks: TodoTask[], groups: GroupInfo[]): TodoTask[] {
  const order = new Map(groups.map((group, index) => [group.id, index]));
  return tasks.filter(task => !task.completed).sort((a, b) =>
    (a.due_date ?? '9999-99-99').localeCompare(b.due_date ?? '9999-99-99') || (order.get(a.category) ?? 0) - (order.get(b.category) ?? 0) || a.position - b.position);
}

function line(task: TodoTask, today: string, withDate: boolean) {
  return clip(withDate && task.due_date ? `${dueInfo(task.due_date, today).text} ${task.title}` : task.title);
}

const RANGE_INDEX: Partial<Record<FilterId, number>> = { tomorrow: 1, week: 2, nextweek: 3, next7: 4 };

/** Whether a task belongs to a date perspective (the same ones as the header filters). */
export function inPerspective(task: TodoTask, filter: FilterId, today: string): boolean {
  const due = task.due_date;
  switch (filter) {
    case 'all': return !task.completed && !task.parent_id;
    case 'today': return !task.completed && !!due && due <= today;
    case 'overdue': return !task.completed && !!due && due < today;
    case 'undated': return !task.completed && !due && !task.parent_id;
    case 'done': return task.completed;
    default: return !task.completed && !!due && inRange(due, quickRanges(today)[RANGE_INDEX[filter] ?? 0].range);
  }
}

/** The text(s) for the menu bar item in a given mode; more than one means it cycles. `filter` and `groupId` narrow what it is about. */
export function trayTitles(mode: TrayMode, tasks: TodoTask[], groups: GroupInfo[], today: string, filter: FilterId = 'all', groupId = 'all'): string[] {
  const scoped = tasks.filter(task => (groupId === 'all' || task.category === groupId) && inPerspective(task, filter, today));
  const list = filter === 'done' ? [...scoped].sort((a, b) => b.updated_at.localeCompare(a.updated_at)) : upcoming(scoped, groups);
  const count = String(scoped.length);
  switch (mode) {
    case 'icon': return [];
    case 'count': return [count];
    case 'next': return list[0] ? [line(list[0], today, false)] : [t('没有待办')];
    case 'next_date': return list[0] ? [line(list[0], today, true)] : [t('没有待办')];
    case 'rotate': return [...new Set([t('还有 {n} 件', { n: count }), ...list.slice(0, 4).map(task => line(task, today, true))])];
  }
}
