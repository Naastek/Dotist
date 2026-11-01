import { invoke } from '@tauri-apps/api/core';
import { addDays, localDate, parseDate } from './dates';
import type { Category, GroupInfo, TaskStatus, TodoTask } from './types';

type Patch = { title?: string; category?: Category; completed?: boolean; status?: TaskStatus };
interface TaskApi {
  list(): Promise<TodoTask[]>;
  groups(): Promise<GroupInfo[]>;
  addGroup(name: string, color?: string): Promise<void>;
  updateGroup(id: string, patch: { name?: string; color?: string }): Promise<void>;
  moveGroup(id: string, direction: -1 | 1): Promise<void>;
  removeGroup(id: string): Promise<void>;
  restoreGroup(id: string): Promise<void>;
  /** Indent under `parentId`, or outdent to the top level when null. */
  reparent(id: string, parentId: string | null): Promise<void>;
  add(title: string, category: Category, parentId?: string, dueDate?: string): Promise<void>;
  setStart(id: string, startDate: string | null): Promise<void>;
  setDateRange(id: string, startDate: string | null, dueDate: string | null): Promise<void>;
  moveStatus(id: string, direction: -1 | 1): Promise<void>;
  setDue(id: string, dueDate: string | null): Promise<void>;
  patch(id: string, patch: Patch): Promise<void>;
  remove(id: string): Promise<void>;
  restore(id: string): Promise<void>;
  move(id: string, direction: -1 | 1): Promise<void>;
  reorder(id: string, targetId: string, after: boolean, allTasks: boolean): Promise<void>;
}

const localApi: TaskApi = {
  list: () => invoke('list_tasks'),
  groups: () => invoke('list_groups'),
  addGroup: async (name, color) => { await invoke('add_group', { name, color }); },
  updateGroup: async (id, patch) => { await invoke('update_group', { id, ...patch }); },
  moveGroup: async (id, direction) => { await invoke('move_group', { id, direction }); },
  removeGroup: async id => { await invoke('delete_group', { id }); },
  restoreGroup: async id => { await invoke('restore_group', { id }); },
  reparent: async (id, parentId) => { await invoke('reparent_task', { id, parentId }); },
  add: async (title, category, parentId, dueDate) => { await invoke('add_task', { title, category, parentId, dueDate }); },
  setStart: async (id, startDate) => { await invoke('set_start_date', { id, startDate }); },
  setDateRange: async (id, startDate, dueDate) => { await invoke('set_date_range', { id, startDate, dueDate }); },
  moveStatus: async (id, direction) => { await invoke('move_status_task', { id, direction }); },
  setDue: async (id, dueDate) => { await invoke('set_due_date', { id, dueDate }); },
  patch: async (id, patch) => { await invoke('patch_task', { id, ...patch }); },
  remove: async id => { await invoke('delete_task', { id }); },
  restore: async id => { await invoke('restore_task', { id }); },
  move: async (id, direction) => { await invoke('move_task', { id, direction }); },
  reorder: async (id, targetId, after, allTasks) => { await invoke('reorder_task', { id, targetId, after, allTasks }); },
};

// An explicit browser-only visual preview; it never reads or writes the user's database.
function createDemoApi(): TaskApi {
  const today = localDate();
  const validDate = (value: string) => /^\d{4}-\d{2}-\d{2}$/.test(value) && localDate(parseDate(value)) === value;
  const make = (index: number, category: Category, title: string, completed: boolean, parent: string | null = null, due: string | null = null): TodoTask =>
    ({ id: `demo-${index}`, category, title, completed, status: completed ? 'done' : 'todo', start_date: null, position: index, created_at: '', updated_at: new Date().toISOString(), deleted_at: null, revision: 1, parent_id: parent, due_date: due });
  let tasks: TodoTask[] = [
    make(0, 'work', '整理本周的工作计划', false, null, today), make(1, 'work', '回复项目消息', false, null, addDays(today, -1)), make(2, 'work', '提交周报', true, null, today),
    make(3, 'work', '列出三件最重要的事', true, 'demo-0'), make(4, 'work', '排进日历', false, 'demo-0', today), make(5, 'work', '同步给团队', false, 'demo-0'),
    make(6, 'life', '下班后散步，顺路买些水果', false, null, today), make(7, 'life', '给绿萝换盆', false),
    make(8, 'life', '苹果', false, 'demo-6'), make(9, 'life', '橙子', false, 'demo-6'),
    make(10, 'study', '读完《人类简史》第三章', false, null, addDays(today, 3)),
  ];
  tasks[1].status = 'doing';
  let groups: GroupInfo[] = [{ id: 'work', name: '工作', color: 'work', position: 0 }, { id: 'life', name: '生活', color: 'life', position: 1 }, { id: 'study', name: '学习', color: 'study', position: 2 }];
  const deletedGroups = new Map<string, { group: GroupInfo; tasks: TodoTask[] }>();
  const deleted = new Map<string, TodoTask[]>();
  const siblings = (task: TodoTask) => tasks.filter(item => item.parent_id === task.parent_id && (task.parent_id || item.category === task.category)).sort((a, b) => a.position - b.position || a.id.localeCompare(b.id));
  const demo: TaskApi = {
    list: async () => tasks.map(task => ({ ...task })),
    groups: async () => [...groups].sort((a, b) => a.position - b.position).map(group => ({ ...group })),
    addGroup: async (name, color) => {
      const trimmed = name.trim();
      if (!trimmed) throw new Error('分组名不能为空');
      if (groups.some(group => group.name === trimmed)) throw new Error('已经有同名的分组');
      const palette = ['work', 'life', 'study', 'teal', 'rose', 'moss'];
      groups.push({ id: crypto.randomUUID(), name: trimmed, color: color ?? palette.find(c => !groups.some(group => group.color === c)) ?? palette[groups.length % palette.length], position: groups.length ? Math.max(...groups.map(group => group.position)) + 1 : 0 });
    },
    updateGroup: async (id, patch) => {
      if (patch.name !== undefined) {
        const trimmed = patch.name.trim();
        if (!trimmed) throw new Error('分组名不能为空');
        if (groups.some(group => group.name === trimmed && group.id !== id)) throw new Error('已经有同名的分组');
        patch = { ...patch, name: trimmed };
      }
      groups = groups.map(group => group.id === id ? { ...group, ...patch } : group);
    },
    moveGroup: async (id, direction) => {
      const sorted = [...groups].sort((a, b) => a.position - b.position);
      const index = sorted.findIndex(group => group.id === id);
      const other = sorted[index + direction];
      if (other) { const mine = sorted[index].position; sorted[index].position = other.position; other.position = mine; }
      groups = sorted;
    },
    removeGroup: async id => {
      if (groups.length <= 1) throw new Error('至少保留一个分组');
      const group = groups.find(item => item.id === id);
      if (!group) return;
      const gone = tasks.filter(task => task.category === id);
      deletedGroups.set(id, { group, tasks: gone });
      groups = groups.filter(item => item.id !== id);
      tasks = tasks.filter(task => task.category !== id);
    },
    restoreGroup: async id => {
      const saved = deletedGroups.get(id);
      if (!saved) return;
      groups.push(saved.group); tasks.push(...saved.tasks); deletedGroups.delete(id);
    },
    reparent: async (id, parentId) => {
      const task = tasks.find(item => item.id === id);
      if (!task) return;
      if (parentId) {
        const parent = tasks.find(item => item.id === parentId);
        if (!parent || parent.parent_id) throw new Error('只支持一级子任务');
        if (tasks.some(item => item.parent_id === id)) throw new Error('有子任务的任务不能再缩进');
        const peers = tasks.filter(item => item.parent_id === parentId);
        task.parent_id = parentId; task.category = parent.category; task.position = peers.length ? Math.max(...peers.map(item => item.position)) + 1 : 0;
      } else {
        const parent = tasks.find(item => item.id === task.parent_id);
        if (!parent) throw new Error('这已经是一级任务');
        tasks.filter(item => !item.parent_id && item.category === parent.category && item.position > parent.position).forEach(item => { item.position += 1; });
        task.parent_id = null; task.position = parent.position + 1;
      }
    },
    add: async (title, category, parentId, dueDate) => {
      const parent = parentId ? tasks.find(task => task.id === parentId) : undefined;
      if (parentId && (!parent || parent.parent_id)) throw new Error('无法添加子任务');
      const cat = parent ? parent.category : category;
      const peers = tasks.filter(task => task.parent_id === (parentId ?? null) && (parentId || task.category === cat));
      tasks.push({ id: crypto.randomUUID(), title, category: cat, completed: false, status: 'todo', start_date: null, position: peers.length ? Math.max(...peers.map(task => task.position)) + 1 : 0, created_at: '', updated_at: new Date().toISOString(), deleted_at: null, revision: 1, parent_id: parentId ?? null, due_date: dueDate ?? null });
    },
    setDue: async (id, dueDate) => {
      if (dueDate !== null && !validDate(dueDate)) throw new Error('到期日格式应为 YYYY-MM-DD');
      const task = tasks.find(task => task.id === id);
      if (task?.start_date && dueDate && task.start_date > dueDate) throw new Error('开始日不能晚于到期日');
      tasks = tasks.map(task => task.id === id ? { ...task, due_date: dueDate } : task);
    },
    setStart: async (id, startDate) => {
      if (startDate !== null && !validDate(startDate)) throw new Error('开始日格式应为 YYYY-MM-DD');
      const task = tasks.find(task => task.id === id);
      if (startDate && task?.due_date && startDate > task.due_date) throw new Error('开始日不能晚于到期日');
      tasks = tasks.map(task => task.id === id ? { ...task, start_date: startDate } : task);
    },
    setDateRange: async (id, startDate, dueDate) => {
      if ((startDate && !validDate(startDate)) || (dueDate && !validDate(dueDate))) throw new Error('日期格式应为 YYYY-MM-DD');
      if (startDate && dueDate && startDate > dueDate) throw new Error('开始日不能晚于到期日');
      tasks = tasks.map(task => task.id === id ? { ...task, start_date: startDate, due_date: dueDate } : task);
    },
    moveStatus: async (id, direction) => {
      const task = tasks.find(task => task.id === id);
      if (!task || task.parent_id) return;
      const peers = tasks.filter(item => !item.parent_id && item.status === task.status).sort((a, b) => a.position - b.position || a.id.localeCompare(b.id));
      const index = peers.findIndex(item => item.id === id);
      const other = peers[index + direction];
      if (other) await demo.reorder(id, other.id, direction > 0, true);
    },
    patch: async (id, patch) => {
      const target = tasks.find(task => task.id === id);
      if (!target) return;
      if (patch.status !== undefined && patch.completed !== undefined && patch.completed !== (patch.status === 'done')) throw new Error('完成标记与状态不一致');
      const status = patch.status ?? (patch.completed === undefined ? target.status : patch.completed ? 'done' : 'todo');
      const cascade = status === 'done' && !target.completed;
      tasks = tasks.map(task => {
        if (task.id === id) return { ...task, ...patch, status, completed: status === 'done' };
        if (task.parent_id === id && (cascade || (patch.category && patch.category !== target.category))) return { ...task, completed: cascade ? true : task.completed, status: cascade ? 'done' : task.status, category: patch.category ?? task.category };
        return task;
      });
    },
    remove: async id => {
      const gone = tasks.filter(task => task.id === id || task.parent_id === id);
      deleted.set(id, gone);
      tasks = tasks.filter(task => !gone.includes(task));
    },
    restore: async id => { tasks.push(...(deleted.get(id) ?? [])); deleted.delete(id); },
    move: async (id, direction) => {
      const task = tasks.find(item => item.id === id);
      if (!task) return;
      const group = siblings(task);
      const index = group.findIndex(item => item.id === id);
      const other = group[index + direction];
      if (other) await demo.reorder(id, other.id, direction > 0, false);
    },
    reorder: async (id, targetId, after, allTasks) => {
      const task = tasks.find(item => item.id === id);
      const target = tasks.find(item => item.id === targetId);
      if (!task || !target) throw new Error('找不到任务');
      if (!allTasks && (task.category !== target.category || task.parent_id !== target.parent_id)) throw new Error('只能调整同级任务的顺序');
      if (id === targetId) return;
      const peers = [...tasks].sort((a, b) => a.position - b.position || a.id.localeCompare(b.id));
      const sourceIndex = peers.findIndex(peer => peer.id === id);
      const source = peers.splice(sourceIndex, 1)[0];
      const insertAt = peers.findIndex(peer => peer.id === targetId) + Number(after);
      if (insertAt === sourceIndex) return;
      peers.splice(insertAt, 0, source);
      const candidate = (preferLeft: boolean) => {
        let first = insertAt, last = insertAt;
        while (true) {
          const lower = first === 0 ? Number.MIN_SAFE_INTEGER : peers[first - 1].position + 1;
          const upper = last + 1 === peers.length ? Number.MAX_SAFE_INTEGER : peers[last + 1].position - 1;
          const latestStart = upper - (last - first);
          if (lower <= latestStart) {
            const start = Math.max(lower, Math.min(peers[first].position, latestStart));
            const changed = peers.slice(first, last + 1).filter((peer, index) => peer.position !== start + index);
            return { first, last, start, changed: changed.length, unrelated: changed.filter(peer => peer.id !== id && peer.id !== targetId).length };
          }
          if (first > 0 && (last + 1 === peers.length || preferLeft)) first -= 1;
          else last += 1;
        }
      };
      const left = candidate(true), right = candidate(false);
      const { first, last, start } = left.unrelated < right.unrelated || (left.unrelated === right.unrelated && left.changed <= right.changed) ? left : right;
      const now = new Date().toISOString();
      peers.slice(first, last + 1).forEach((peer, index) => {
        if (peer.position === start + index) return;
        peer.position = start + index; peer.revision += 1;
        if (!peer.completed) peer.updated_at = now;
      });
    },
  };
  return demo;
}

export const isDemo = new URLSearchParams(window.location.search).has('demo');
export const taskApi = isDemo ? createDemoApi() : localApi;
