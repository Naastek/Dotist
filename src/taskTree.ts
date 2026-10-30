import type { GroupInfo, TodoTask } from './types';

export interface TaskNode { task: TodoTask; children: TodoTask[]; }
export interface GroupView { group: GroupInfo; open: TaskNode[]; done: TaskNode[]; }

const byPosition = (a: TodoTask, b: TodoTask) => a.position - b.position || a.id.localeCompare(b.id);

/** Groups the flat task list into one-level trees per group; completed parents go to `done`. */
export function buildGroups(tasks: TodoTask[], groups: GroupInfo[]): GroupView[] {
  const children = new Map<string, TodoTask[]>();
  for (const task of tasks) {
    if (task.parent_id) children.set(task.parent_id, [...(children.get(task.parent_id) ?? []), task]);
  }
  return groups.map(group => {
    const nodes = tasks.filter(task => task.category === group.id && !task.parent_id).sort(byPosition)
      .map(task => ({ task, children: (children.get(task.id) ?? []).sort(byPosition) }));
    return { group, open: nodes.filter(node => !node.task.completed), done: nodes.filter(node => node.task.completed) };
  });
}

export function remainingCount(tasks: TodoTask[]) {
  return tasks.filter(task => !task.parent_id && !task.completed).length;
}
export function totalCount(tasks: TodoTask[]) { return tasks.filter(task => !task.parent_id).length; }

/** The next thing to do: first unfinished top-level task in group order. */
export function nextTask(tasks: TodoTask[], groups: GroupInfo[]): TodoTask | undefined {
  for (const view of buildGroups(tasks, groups)) if (view.open[0]) return view.open[0].task;
  return undefined;
}
