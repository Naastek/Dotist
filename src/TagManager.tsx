import { ChevronLeft, Trash2 } from 'lucide-react';
import { useRef, useState } from 'react';
import { t } from './i18n';
import { ManagerSwitch } from './ManagerSwitch';
import { isImeEvent } from './TaskComposer';
import { taskApi } from './taskApi';
import { retag, tagCounts, tagsOf } from './tags';
import type { TodoTask } from './types';

type Run = (action: () => Promise<void>) => Promise<boolean>;

/** The small tag manager: every #tag in use, how many tasks carry it; open it as a filter, rename it or remove it. */
export function TagManager({ tasks, run, onBack, onPick, onSwitch }: { onSwitch: (next: 'groups' | 'tags') => void; tasks: TodoTask[]; run: Run; onBack: () => void; onPick: (tag: string) => void }) {
  const [renaming, setRenaming] = useState<string | null>(null);
  const counts = tagCounts(tasks);
  const rewrite = (tag: string, next: string | null) => run(async () => {
    for (const task of tasks) if (!task.deleted_at && tagsOf(task).includes(tag)) await taskApi.patch(task.id, { title: retag(task.title, tag, next) });
  });
  return <>
    <header className="dt-head" data-tauri-drag-region>
      <button className="dt-icon" aria-label={t('返回任务列表')} title={t('返回')} onClick={onBack}><ChevronLeft className="dt-svg" strokeWidth={1.5} /></button>
      <ManagerSwitch current="tags" onSwitch={onSwitch} />
      <span className="dt-left" data-tauri-drag-region>{t('{n} 个', { n: counts.length })}</span>
    </header>
    <div className="dt-scroll dt-settings">
      {counts.length === 0 && <p className="dt-empty">{t('在任务里写 #词 就会有标签，比如：写周报 #sideproject')}</p>}
      <ul className="dt-list">
        {counts.map(({ tag, open }) => <li key={tag} className="dt-group-row dt-tag-row">
          {renaming === tag
            ? <RenameTag tag={tag} close={() => setRenaming(null)} save={next => rewrite(tag, next)} />
            : <button type="button" className="dt-group-name" aria-label={t('查看标签 {tag}', { tag })} title={t('点击查看带这个标签的任务')} onClick={() => onPick(tag)}>#{tag}</button>}
          <span className="dt-group-count">{open}</span>
          <span className="dt-group-actions">
            <button type="button" className="dt-text-btn" aria-label={t('重命名标签 {tag}', { tag })} onClick={() => setRenaming(tag)}>{t('重命名')}</button>
            <button className="dt-icon is-danger" aria-label={t('移除标签 {tag}', { tag })} title={t('从所有任务里移除这个标签')} onClick={() => void rewrite(tag, null)}><Trash2 className="dt-svg" strokeWidth={1.5} /></button>
          </span>
        </li>)}
      </ul>
      <p className="dt-set-note">{t('标签写在任务标题里（#词），所以改名和移除会同步改写所有带它的任务。')}</p>
    </div>
  </>;
}

function RenameTag({ tag, close, save }: { tag: string; close: () => void; save: (next: string) => Promise<boolean> }) {
  const [name, setName] = useState(tag);
  const composing = useRef(false);
  const done = useRef(false);
  const commit = async () => {
    if (done.current) return;
    done.current = true;
    const next = name.trim().replace(/^#+/, '').replace(/\s+/g, '');
    if (!next || next === tag) { close(); return; }
    if (await save(next)) close(); else done.current = false;
  };
  return <input className="dt-text-edit dt-group-rename" aria-label={t('标签名称')} autoFocus value={name} maxLength={24} onChange={event => setName(event.target.value)}
    onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }}
    onKeyDown={event => {
      if (isImeEvent(event, composing.current)) return;
      if (event.key === 'Enter') { event.preventDefault(); void commit(); }
      else if (event.key === 'Escape') { event.preventDefault(); done.current = true; close(); }
    }}
    onBlur={() => void commit()} />;
}
