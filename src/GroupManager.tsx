import { ChevronDown, ChevronLeft, ChevronUp, Trash2 } from 'lucide-react';
import { useRef, useState, type KeyboardEvent } from 'react';
import { t } from './i18n';
import { ManagerSwitch } from './ManagerSwitch';
import { isImeEvent } from './TaskComposer';
import { taskApi } from './taskApi';
import { nextColor, type GroupInfo, type TodoTask } from './types';

type Run = (action: () => Promise<void>) => Promise<boolean>;

/** The small group manager: add, rename, recolor, reorder and delete groups. */
export function GroupManager({ groups, tasks, run, intent, onBack, onDelete, onSwitch }: { onSwitch: (next: 'groups' | 'tags') => void; groups: GroupInfo[]; tasks: TodoTask[]; run: Run; intent?: { rename?: string; add?: boolean }; onBack: () => void; onDelete: (group: GroupInfo) => void }) {
  const [renaming, setRenaming] = useState<string | null>(intent?.rename ?? null);
  const [adding, setAdding] = useState('');
  const composing = useRef(false);

  const countOf = (group: GroupInfo) => tasks.filter(task => task.category === group.id && !task.parent_id && !task.completed).length;
  const addGroup = async () => { if (adding.trim() && await run(() => taskApi.addGroup(adding))) setAdding(''); };
  const onAddKey = (event: KeyboardEvent<HTMLInputElement>) => {
    if (isImeEvent(event, composing.current)) return;
    if (event.key === 'Enter') { event.preventDefault(); void addGroup(); }
    else if (event.key === 'Escape') { event.preventDefault(); setAdding(''); }
  };

  return <>
    <header className="dt-head" data-tauri-drag-region>
      <button className="dt-icon" aria-label={t('返回任务列表')} title={t('返回')} onClick={onBack}><ChevronLeft className="dt-svg" strokeWidth={1.5} /></button>
      <ManagerSwitch current="groups" onSwitch={onSwitch} />
      <span className="dt-left" data-tauri-drag-region>{t('{n} 个', { n: groups.length })}</span>
    </header>
    <div className="dt-scroll dt-settings">
      <ul className="dt-list">
        {groups.map((group, index) => <li key={group.id} className={`dt-group-row ${group.color}`}>
          <button type="button" className="dt-swatch" aria-label={t('更改「{name}」的颜色', { name: group.name })} title={t('点击换色')} onClick={() => void run(() => taskApi.updateGroup(group.id, { color: nextColor(group.color) }))} />
          {renaming === group.id
            ? <RenameField group={group} run={run} close={() => setRenaming(null)} />
            : <button type="button" className="dt-group-name" aria-label={t('重命名「{name}」', { name: group.name })} title={t('点击重命名')} onClick={() => setRenaming(group.id)}>{group.name}</button>}
          <span className="dt-group-count">{countOf(group)}</span>
          <span className="dt-group-actions">
            <button className="dt-icon" aria-label={t('上移分组 {name}', { name: group.name })} title={t('上移')} disabled={index === 0} onClick={() => void run(() => taskApi.moveGroup(group.id, -1))}><ChevronUp className="dt-svg" strokeWidth={1.5} /></button>
            <button className="dt-icon" aria-label={t('下移分组 {name}', { name: group.name })} title={t('下移')} disabled={index === groups.length - 1} onClick={() => void run(() => taskApi.moveGroup(group.id, 1))}><ChevronDown className="dt-svg" strokeWidth={1.5} /></button>
            <button className="dt-icon is-danger" aria-label={t('删除分组 {name}', { name: group.name })} title={groups.length <= 1 ? t('至少保留一个分组') : t('删除分组（连同其中的任务，可撤销）')} disabled={groups.length <= 1} onClick={() => onDelete(group)}><Trash2 className="dt-svg" size={15} strokeWidth={1.5} /></button>
          </span>
        </li>)}
      </ul>
      <div className="dt-field dt-group-add">
        <input aria-label={t('新分组名称')} autoFocus={intent?.add} value={adding} placeholder={t('新分组，回车添加')} maxLength={20} onChange={event => setAdding(event.target.value)}
          onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }} onKeyDown={onAddKey} />
      </div>
      <p className="dt-set-note">{t('删除分组会连同其中的任务一起删除，底部提示里可以撤销。点色块换颜色，点名字重命名。')}</p>
    </div>
  </>;
}

function RenameField({ group, run, close }: { group: GroupInfo; run: Run; close: () => void }) {
  const [name, setName] = useState(group.name);
  const composing = useRef(false);
  const done = useRef(false);
  const save = async () => {
    if (done.current) return;
    done.current = true;
    const trimmed = name.trim();
    if (!trimmed || trimmed === group.name) { close(); return; }
    if (await run(() => taskApi.updateGroup(group.id, { name: trimmed }))) close(); else done.current = false;
  };
  return <input className="dt-text-edit dt-group-rename" aria-label={t('分组名称')} autoFocus value={name} maxLength={20} onChange={event => setName(event.target.value)}
    onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }}
    onKeyDown={event => {
      if (isImeEvent(event, composing.current)) return;
      if (event.key === 'Enter') { event.preventDefault(); void save(); }
      else if (event.key === 'Escape') { event.preventDefault(); done.current = true; close(); }
    }}
    onBlur={() => void save()} />;
}
