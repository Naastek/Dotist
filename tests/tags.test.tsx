import { describe, expect, it } from 'vitest';
import { collectTags, filterByTag, splitTitle } from '../src/tags';
import type { TodoTask } from '../src/types';

const task = (id: string, title: string, parent: string | null = null, completed = false): TodoTask => ({ id, title, category: 'work', completed, status: completed ? 'done' : 'todo', start_date: null, position: 0, created_at: '', updated_at: '', deleted_at: null, revision: 1, parent_id: parent, due_date: null });

describe('tags', () => {
  it('splits #tags out of a title, keeping the text', () => {
    expect(splitTitle('回复消息 #sideproject #工作')).toEqual({ text: '回复消息', tags: ['sideproject', '工作'] });
    expect(splitTitle('#only')).toEqual({ text: '#only', tags: ['only'] });
    expect(splitTitle('C# 入门').tags).toEqual([]);
  });
  it('lists tags in use, most used first, ignoring finished tasks', () => {
    expect(collectTags([task('1', 'a #x'), task('2', 'b #y #x'), task('3', 'c #z', null, true)])).toEqual(['x', 'y']);
  });
  it('filters across groups and keeps parent and subtask context', () => {
    const list = [task('p', '父任务 #a'), task('c', '子任务', 'p'), task('q', '别的'), task('d', '子 #a', 'q')];
    expect(filterByTag(list, 'a').map(item => item.id).sort()).toEqual(['c', 'd', 'p', 'q']);
  });
});
