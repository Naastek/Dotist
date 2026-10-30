import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from 'react';
import { dueInfo, localDate, quickDates } from './dates';
import { t } from './i18n';
import { applyGlass, applyGroupColors, applyTheme, settingsApi } from './settingsApi';
import { setLanguage } from './i18n';
import { taskApi } from './taskApi';
import { isImeEvent } from './TaskComposer';
import type { GroupInfo } from './types';
import { windowApi } from './windowApi';

const LAST_GROUP = 'dotist.quick.group';
const remembered = () => { try { return localStorage.getItem(LAST_GROUP); } catch { return null; } };

/** The quick-add panel: a single input shown from anywhere. Enter adds, Esc closes, Tab changes the group. */
export function QuickAdd() {
  const [groups, setGroups] = useState<GroupInfo[]>([]);
  const [group, setGroup] = useState<string | null>(remembered());
  const [title, setTitle] = useState('');
  const [dueIndex, setDueIndex] = useState(-1);
  const [error, setError] = useState('');
  const input = useRef<HTMLInputElement>(null);
  const composing = useRef(false);
  const busy = useRef(false);

  const refresh = useCallback(() => {
    setTitle(''); setDueIndex(-1); setError('');
    void taskApi.groups().then(setGroups, () => {});
    setTimeout(() => input.current?.focus(), 30);
  }, []);
  useEffect(() => { void settingsApi.get().then(next => { applyTheme(next.theme); applyGlass(next.opacity, next.frost); applyGroupColors(next.group_colors); setLanguage(next.language); }, () => {}); }, []);
  useEffect(() => {
    refresh();
    const off = windowApi.on('quick-show', refresh);
    return () => { void off.then(stop => stop()); };
  }, [refresh]);

  const today = localDate();
  const shortcuts = quickDates(today);
  const current = groups.find(item => item.id === group) ?? groups[0];
  const due = dueIndex >= 0 ? shortcuts[dueIndex] : null;
  const cycleGroup = (step: number) => {
    if (!groups.length) return;
    const index = Math.max(0, groups.findIndex(item => item.id === current?.id));
    const next = groups[(index + step + groups.length) % groups.length].id;
    setGroup(next);
    try { localStorage.setItem(LAST_GROUP, next); } catch { /* not remembered */ }
  };

  const add = async () => {
    const trimmed = title.trim();
    if (!trimmed || !current || busy.current) return;
    busy.current = true;
    try {
      await taskApi.add(trimmed, current.id, undefined, due?.date);
      await windowApi.quickDone(true);
      refresh();
    } catch (reason) { setError(t(typeof reason === 'string' ? reason : reason instanceof Error ? reason.message : '操作失败，请重试。')); }
    finally { busy.current = false; }
  };
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (isImeEvent(event, composing.current)) return;
    if (event.key === 'Enter') { event.preventDefault(); void add(); }
    else if (event.key === 'Escape') { event.preventDefault(); void windowApi.quickDone(false); }
    else if (event.key === 'Tab') { event.preventDefault(); cycleGroup(event.shiftKey ? -1 : 1); }
  };

  return <div className="dt-quick" data-tauri-drag-region>
    <input ref={input} className="dt-quick-input" aria-label={t('快速添加')} value={title} placeholder={t('写下一件小事')} autoFocus
      onChange={event => setTitle(event.target.value)} onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }} onKeyDown={onKeyDown} />
    <div className="dt-quick-meta">
      {current && <button type="button" className={`dt-cat-pick ${current.color}`} aria-label={t('分组：{name}，点击选择', { name: current.name })} onClick={() => cycleGroup(1)}>{current.name}</button>}
      <button type="button" className={`dt-quick-due ${due ? 'is-set' : ''}`} aria-label={due ? t('到期日：{date}', { date: dueInfo(due.date, today).text }) : t('设置到期日')} onClick={() => setDueIndex(dueIndex + 1 >= shortcuts.length ? -1 : dueIndex + 1)}>{due ? due.label : t('到期日')}</button>
      <span className="dt-quick-hint">{error || t('回车添加 · Esc 关闭 · Tab 换分组')}</span>
    </div>
  </div>;
}
