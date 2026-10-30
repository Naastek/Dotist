import { CalendarDays, CornerDownLeft, X } from 'lucide-react';
import { useEffect, useRef, useState, type KeyboardEvent } from 'react';
import { Calendar } from './Calendar';
import { dueInfo, quickDates } from './dates';
import { t } from './i18n';
import { Menu, type MenuEntry, type MenuState } from './Menu';
import { groupColor, groupName, type Category, type GroupInfo } from './types';

export function isImeEvent(event: KeyboardEvent<HTMLInputElement | HTMLTextAreaElement>, composing: boolean) {
  return composing || event.nativeEvent.isComposing || event.keyCode === 229;
}

interface ComposerProps {
  groups: GroupInfo[];
  /** Applied to new tasks unless a date is picked here (the day view passes the viewed day). */
  defaultDue?: string;
  today?: string;
  onNewGroup?: () => void;
  onManageGroups?: () => void;
  onManageTags?: () => void;
  /** Tags already in use, offered as completions after a `#`. */
  tags?: string[];
  /** Small status text at the right end of the bar (the remaining count). */
  trailing?: string;
  onAdd: (title: string, category: Category, due?: string) => void | boolean | Promise<void | boolean>;
}

/** One flat bar: group, due date, the text field and the enter hint. No boxes inside boxes. */
export function TaskComposer({ groups, defaultDue, today = '', onNewGroup, onManageGroups, onManageTags, tags = [], trailing, onAdd }: ComposerProps) {
  const [title, setTitle] = useState('');
  const [chosen, setCategory] = useState<Category>('work');
  const category = groups.some(group => group.id === chosen) ? chosen : groups[0]?.id ?? chosen;
  const [busy, setBusy] = useState(false);
  const [due, setDue] = useState<string | null>(null);
  const [menu, setMenu] = useState<MenuState | null>(null);
  const [calendar, setCalendar] = useState(false);
  const composing = useRef(false);
  const submitting = useRef(false);
  const pop = useRef<HTMLDivElement>(null);
  const [pick, setPick] = useState(-1);
  const partial = /(^|\s)#([^\s#]*)$/.exec(title);
  const suggestions = partial ? tags.filter(tag => tag.toLowerCase().startsWith(partial[2].toLowerCase()) && tag !== partial[2]).slice(0, 6) : [];
  const complete = (tag: string) => { setTitle(title.replace(/#([^\s#]*)$/, `#${tag} `)); setPick(-1); };

  useEffect(() => {
    if (!calendar) return;
    const outside = (event: PointerEvent) => { const target = event.target as HTMLElement; if (!pop.current?.contains(target) && !target.closest('.dt-due-pick')) setCalendar(false); };
    const key = (event: globalThis.KeyboardEvent) => { if (event.key === 'Escape') setCalendar(false); };
    document.addEventListener('pointerdown', outside, true);
    window.addEventListener('keydown', key);
    return () => { document.removeEventListener('pointerdown', outside, true); window.removeEventListener('keydown', key); };
  }, [calendar]);

  async function submit() {
    const trimmed = title.trim();
    if (!trimmed || submitting.current || composing.current) return;
    submitting.current = true;
    setBusy(true);
    try {
      const effectiveDue = due ?? defaultDue;
      const result = await (effectiveDue ? onAdd(trimmed, category, effectiveDue) : onAdd(trimmed, category));
      if (result !== false) { setTitle(''); setDue(null); }
    } finally { submitting.current = false; setBusy(false); }
  }

  function onKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (isImeEvent(event, composing.current)) return;
    // After a `#`: arrows walk the suggestions, Tab takes the highlighted one (or the first), Enter only takes one that was walked to.
    if (suggestions.length) {
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); setPick((pick + (event.key === 'ArrowDown' ? 1 : -1) + suggestions.length) % suggestions.length); return; }
      if (event.key === 'Tab') { event.preventDefault(); complete(suggestions[Math.max(pick, 0)]); return; }
      if (event.key === 'Enter' && pick >= 0) { event.preventDefault(); complete(suggestions[pick]); return; }
    }
    if (event.key !== 'Enter') return;
    event.preventDefault();
    void submit();
  }

  const groupMenu = (event: React.MouseEvent<HTMLButtonElement>) => {
    const box = event.currentTarget.getBoundingClientRect();
    const items: MenuEntry[] = [
      { label: t('管理分组…'), onSelect: () => onManageGroups?.() },
      ...(onManageTags ? [{ label: t('管理标签…'), onSelect: () => onManageTags() }] : []),
      'separator',
      ...groups.map(group => ({ label: group.name, dot: group.color, checked: group.id === category, onSelect: () => setCategory(group.id) })),
      'separator',
      { label: t('新建分组…'), onSelect: () => onNewGroup?.() },
    ];
    setMenu({ x: box.left, y: box.top, items, placement: 'above' });
  };

  const shownDue = due ?? defaultDue ?? null;
  const dueText = shownDue && today ? dueInfo(shownDue, today).text : '';

  return <div className="dt-composer">
    <button type="button" className={`dt-cat-pick ${groupColor(groups, category)}`} aria-haspopup="menu" aria-expanded={menu !== null} aria-label={t('分组：{name}，点击选择', { name: groupName(groups, category) })} title={t('选择分组')} onClick={groupMenu}>{groupName(groups, category)}</button>
    {today && <button type="button" className={`dt-due-pick ${dueText ? 'is-set' : ''}`} aria-haspopup="dialog" aria-expanded={calendar} aria-label={dueText ? t('到期日：{date}', { date: dueText }) : t('设置到期日')} title={t('到期日')} onClick={() => setCalendar(!calendar)}>
      <CalendarDays className="dt-svg" strokeWidth={1.5} />{dueText && <span>{dueText}</span>}
    </button>}
    <input id="new-task" aria-label={t('新任务')} value={title} placeholder={t('写下一件小事')} onChange={event => { setTitle(event.target.value); setPick(-1); }} onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }} onKeyDown={onKeyDown} />
    {suggestions.length > 0 && <div className="dt-tag-suggest" role="listbox" aria-label={t('标签')}>{suggestions.map((tag, index) => <button key={tag} type="button" role="option" aria-selected={index === pick} className={index === pick ? 'is-on' : ''} tabIndex={-1} onMouseDown={event => { event.preventDefault(); complete(tag); }}>#{tag}</button>)}</div>}
    {trailing && !title.trim() && <span className="dt-composer-count">{trailing}</span>}
    <button type="button" className={`dt-enter ${title.trim() ? 'is-ready' : ''}`} aria-label={t('添加任务')} title={t('回车添加')} tabIndex={-1} disabled={busy || !title.trim()} onClick={() => void submit()}><CornerDownLeft className="dt-svg" strokeWidth={1.5} /></button>
    {calendar && <div ref={pop} className="dt-cal-pop" role="dialog" aria-label={t('到期日')}>
      <div className="dt-chips">
        {quickDates(today).map(quick => <button key={quick.label} type="button" className={due === quick.date ? 'is-on' : ''} onClick={() => { setDue(quick.date); setCalendar(false); }}>{quick.label}</button>)}
        {due && <button type="button" className="dt-chip-clear" onClick={() => { setDue(null); setCalendar(false); }}><X className="dt-svg" strokeWidth={1.5} />{t('清除到期日')}</button>}
      </div>
      <Calendar mode="single" today={today} value={shownDue ? { start: shownDue, end: shownDue } : null} onChange={range => { setDue(range.start); setCalendar(false); }} />
    </div>}
    {menu && <Menu state={menu} onClose={() => setMenu(null)} />}
  </div>;
}
