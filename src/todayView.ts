import { addDays, localDate } from './dates';
import type { GroupInfo, TodoTask } from './types';

export interface DayList { date: string; tasks: TodoTask[]; }
export interface TodayData {
  /** For a viewed range other than "just today": open tasks per day, in date order. */
  days: DayList[];
  overdue: TodoTask[];
  today: TodoTask[];
  upcoming: TodoTask[];
  done: TodoTask[];
}

export const UPCOMING_DAYS = 7;

/**
 * Splits tasks by due date. For today alone: overdue and due-today open tasks, the next seven days, and what was
 * finished (due today, or overdue but completed today). For any other day or range: the open tasks per day, plus
 * the completed ones. Subtasks with their own due date appear as their own rows.
 */
export function buildToday(tasks: TodoTask[], groups: GroupInfo[], today: string, start: string = today, end: string = start): TodayData {
  const order = new Map(groups.map((group, index) => [group.id, index]));
  const sort = (a: TodoTask, b: TodoTask) => (a.due_date ?? '').localeCompare(b.due_date ?? '') || (order.get(a.category) ?? 0) - (order.get(b.category) ?? 0) || a.position - b.position;
  const dated = tasks.filter(task => task.due_date);
  const open = dated.filter(task => !task.completed);
  if (start !== today || end !== today) {
    const within = (task: TodoTask) => task.due_date! >= start && task.due_date! <= end;
    const days = [...new Set(open.filter(within).map(task => task.due_date!))].sort().map(date => ({ date, tasks: open.filter(task => task.due_date === date).sort(sort) }));
    return { days, overdue: [], today: [], upcoming: [], done: dated.filter(task => task.completed && within(task)).sort(sort) };
  }
  const horizon = addDays(today, UPCOMING_DAYS);
  return {
    days: [],
    overdue: open.filter(task => task.due_date! < today).sort(sort),
    today: open.filter(task => task.due_date === today).sort(sort),
    upcoming: open.filter(task => task.due_date! > today && task.due_date! <= horizon).sort(sort),
    done: dated.filter(task => task.completed && task.due_date! <= today && (task.due_date === today || localDate(new Date(task.updated_at)) === today)).sort(sort),
  };
}

export interface Lists { overdue: TodoTask[]; undated: GroupedTasks[]; undatedCount: number; done: TodoTask[]; }
export interface GroupedTasks { group: GroupInfo; tasks: TodoTask[]; }

/** The cross-cutting perspectives: everything overdue, everything without a date, everything completed. */
export function buildLists(tasks: TodoTask[], groups: GroupInfo[], today: string): Lists {
  const order = new Map(groups.map((group, index) => [group.id, index]));
  const byPosition = (a: TodoTask, b: TodoTask) => a.position - b.position;
  const open = tasks.filter(task => !task.completed);
  const undated = open.filter(task => !task.due_date);
  return {
    overdue: open.filter(task => task.due_date && task.due_date < today).sort((a, b) => a.due_date!.localeCompare(b.due_date!) || (order.get(a.category) ?? 0) - (order.get(b.category) ?? 0) || byPosition(a, b)),
    undated: groups.map(group => ({ group, tasks: undated.filter(task => task.category === group.id).sort(byPosition) })).filter(entry => entry.tasks.length),
    undatedCount: undated.length,
    done: tasks.filter(task => task.completed).sort((a, b) => b.updated_at.localeCompare(a.updated_at)).slice(0, 200),
  };
}
