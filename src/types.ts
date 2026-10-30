/** A group id: the three defaults keep the ids `work`, `life` and `study`; new groups get a UUID. */
export type Category = string;
export interface GroupInfo { id: string; name: string; color: string; position: number; }
export type TaskStatus = 'todo' | 'doing' | 'done';
export interface TodoTask {
  id: string;
  title: string;
  category: Category;
  completed: boolean;
  status: TaskStatus;
  start_date: string | null;
  position: number;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
  revision: number;
  parent_id: string | null;
  /** Local calendar date `YYYY-MM-DD`. */
  due_date: string | null;
}
export const GROUP_COLORS = ['work', 'life', 'study', 'teal', 'rose', 'moss'] as const;
export function nextGroupId(groups: GroupInfo[], current: Category): Category {
  if (!groups.length) return current;
  const index = groups.findIndex(group => group.id === current);
  return groups[(index + 1) % groups.length].id;
}
export function groupName(groups: GroupInfo[], id: Category) { return groups.find(group => group.id === id)?.name ?? ''; }
export function groupColor(groups: GroupInfo[], id: Category) { return groups.find(group => group.id === id)?.color ?? 'work'; }
export function nextColor(color: string) {
  const index = GROUP_COLORS.indexOf(color as (typeof GROUP_COLORS)[number]);
  return GROUP_COLORS[(index + 1) % GROUP_COLORS.length];
}
