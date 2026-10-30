import { createContext, useContext } from 'react';
import type { TodoTask } from './types';

/** Tags live in the title as `#word` (Things / Obsidian style), so they work for every group, in the MCP server, and need no migration. */
const TAG = /(^|\s)#([^\s#]+)/g;

export function splitTitle(title: string): { text: string; tags: string[] } {
  const tags: string[] = [];
  const text = title.replace(TAG, (_, lead: string, tag: string) => { if (!tags.includes(tag)) tags.push(tag); return lead; }).replace(/\s{2,}/g, ' ').trim();
  return { text: text || title, tags };
}

export const tagsOf = (task: TodoTask) => splitTitle(task.title).tags;

/** Every tag in use, most used first. */
export function collectTags(tasks: TodoTask[]): string[] {
  const counts = new Map<string, number>();
  for (const task of tasks) if (!task.deleted_at && !task.completed) for (const tag of tagsOf(task)) counts.set(tag, (counts.get(tag) ?? 0) + 1);
  return [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([tag]) => tag);
}

/** Tasks carrying the tag, plus the context around them: a matching task keeps its subtasks, a matching subtask keeps its parent. */
export function filterByTag(tasks: TodoTask[], tag: string): TodoTask[] {
  const keep = new Set<string>();
  for (const task of tasks) if (tagsOf(task).includes(tag)) { keep.add(task.id); if (task.parent_id) keep.add(task.parent_id); }
  for (const task of tasks) if (task.parent_id && keep.has(task.parent_id)) keep.add(task.id);
  return tasks.filter(task => keep.has(task.id));
}

const escape = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
/** Renames `#from` to `#to` in a title, or drops it when `to` is null. */
export function retag(title: string, from: string, to: string | null): string {
  const out = title.replace(new RegExp(`(^|\\s)#${escape(from)}(?=\\s|$)`, 'g'), (_, lead: string) => (to ? `${lead}#${to}` : lead));
  return out.replace(/\s{2,}/g, ' ').trim() || title;
}

/** Tags with how many open tasks use each, across every task that is not deleted (finished ones still count as users). */
export function tagCounts(tasks: TodoTask[]): { tag: string; open: number; all: number }[] {
  const map = new Map<string, { open: number; all: number }>();
  for (const task of tasks) if (!task.deleted_at) for (const tag of tagsOf(task)) { const row = map.get(tag) ?? { open: 0, all: 0 }; row.all += 1; if (!task.completed) row.open += 1; map.set(tag, row); }
  return [...map.entries()].sort((a, b) => b[1].open - a[1].open || a[0].localeCompare(b[0])).map(([tag, row]) => ({ tag, ...row }));
}

export const TagContext = createContext<{ active: string | null; pick: (tag: string) => void }>({ active: null, pick: () => {} });

/** A task title with its tags set apart as quiet, clickable marks. */
export function TitleText({ title }: { title: string }) {
  const { active, pick } = useContext(TagContext);
  const { text, tags } = splitTitle(title);
  if (!tags.length) return <>{title}</>;
  return <>{text}{tags.map(tag => <button key={tag} type="button" className={`dt-tag ${active === tag ? 'is-on' : ''}`} tabIndex={-1} onClick={event => { event.stopPropagation(); pick(tag); }}>#{tag}</button>)}</>;
}
