import { ChevronLeft, ChevronRight } from 'lucide-react';
import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react';
import { addDays, addMonths, fullDate, inRange, isoWeek, localDate, monthTitle, parseDate, weekStartsOn, type DateRange } from './dates';
import { locale, t } from './i18n';

/**
 * The calendar used for due dates (one day) and for the day view (one day or a range). Weeks are numbered (ISO),
 * days that have tasks carry a dot, and it works from the keyboard: arrows move, Enter picks, PageUp/PageDown change month.
 */
export function Calendar({ mode, value, today, marks, onChange }: {
  mode: 'single' | 'range';
  value: DateRange | null;
  today: string;
  /** Dates (YYYY-MM-DD) that have open tasks. */
  marks?: Set<string>;
  onChange: (range: DateRange) => void;
}) {
  const [cursor, setCursor] = useState(() => (value?.start ?? today).slice(0, 8) + '01');
  const [focus, setFocus] = useState(value?.start ?? today);
  const [anchor, setAnchor] = useState<string | null>(null);
  const [hover, setHover] = useState<string | null>(null);
  const grid = useRef<HTMLDivElement>(null);
  const moved = useRef(false);

  const weeks = useMemo(() => {
    const first = parseDate(cursor);
    const offset = (first.getDay() - weekStartsOn() + 7) % 7;
    const start = addDays(cursor, -offset);
    return Array.from({ length: 6 }, (_, week) => Array.from({ length: 7 }, (_, day) => addDays(start, week * 7 + day)));
  }, [cursor]);
  const weekdays = weeks[0].map(date => new Intl.DateTimeFormat(locale(), { weekday: 'short' }).format(parseDate(date)));
  const preview: DateRange | null = anchor && hover ? (hover < anchor ? { start: hover, end: anchor } : { start: anchor, end: hover }) : value;

  useEffect(() => {
    if (!moved.current) return;
    moved.current = false;
    grid.current?.querySelector<HTMLButtonElement>(`[data-date="${focus}"]`)?.focus();
  }, [focus, cursor]);

  const pick = (date: string, extend = false) => {
    setFocus(date);
    if (mode === 'single') { onChange({ start: date, end: date }); return; }
    const from = anchor ?? (extend ? value?.start ?? null : null);
    if (from) { onChange(date < from ? { start: date, end: from } : { start: from, end: date }); setAnchor(null); setHover(null); }
    else { setAnchor(date); onChange({ start: date, end: date }); }
  };

  const go = (date: string) => { moved.current = true; setFocus(date); setCursor(date.slice(0, 8) + '01'); };
  const onKeyDown = (event: KeyboardEvent) => {
    const step: Record<string, number> = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 };
    if (event.key in step) { event.preventDefault(); go(addDays(focus, step[event.key])); }
    else if (event.key === 'PageUp' || event.key === 'PageDown') { event.preventDefault(); go(addMonths(focus.slice(0, 8) + '01', event.key === 'PageUp' ? -1 : 1).slice(0, 8) + focus.slice(8)); }
    else if (event.key === 'Home') { event.preventDefault(); go(today); }
    else if (event.key === 'Escape' && anchor) { event.stopPropagation(); setAnchor(null); setHover(null); }
  };

  return <div className="dt-cal" role="group" aria-label={t('日历')}>
    <div className="dt-cal-head">
      <button type="button" className="dt-icon" aria-label={t('上个月')} onClick={() => setCursor(addMonths(cursor, -1))}><ChevronLeft className="dt-svg" strokeWidth={1.5} /></button>
      <b className="dt-cal-title" aria-live="polite">{monthTitle(cursor)}</b>
      <button type="button" className="dt-link" onClick={() => { setCursor(today.slice(0, 8) + '01'); setFocus(today); }}>{t('今天')}</button>
      <button type="button" className="dt-icon" aria-label={t('下个月')} onClick={() => setCursor(addMonths(cursor, 1))}><ChevronRight className="dt-svg" strokeWidth={1.5} /></button>
    </div>
    <div className="dt-cal-grid" role="grid" aria-label={monthTitle(cursor)} ref={grid} onKeyDown={onKeyDown} onMouseLeave={() => setHover(null)}>
      <div className="dt-cal-row is-head" role="row">
        <span className="dt-cal-wk" role="columnheader" title={t('周数')}>{t('周')}</span>
        {weekdays.map((name, index) => <span key={index} role="columnheader" className="dt-cal-dow">{name}</span>)}
      </div>
      {weeks.map(week => {
        const monday = week[weekStartsOn() === 1 ? 0 : 1];
        return <div key={week[0]} className="dt-cal-row" role="row">
          <span className="dt-cal-wk" role="rowheader" aria-label={t('第 {n} 周', { n: isoWeek(monday) })}>{isoWeek(monday)}</span>
          {week.map(date => {
            const selected = inRange(date, preview);
            const edge = preview && (date === preview.start || date === preview.end);
            const classes = ['dt-cal-day', date.slice(0, 7) !== cursor.slice(0, 7) ? 'is-outside' : '', date === today ? 'is-today' : '', selected ? 'in-range' : '', edge ? 'is-edge' : '',
              preview && date === preview.start ? 'is-start' : '', preview && date === preview.end ? 'is-end' : '', marks?.has(date) ? 'has-tasks' : ''].filter(Boolean).join(' ');
            return <button key={date} type="button" role="gridcell" className={classes} data-date={date} tabIndex={date === focus ? 0 : -1} aria-selected={selected} aria-current={date === today ? 'date' : undefined}
              aria-label={fullDate(date)} onMouseEnter={() => { if (anchor) setHover(date); }} onClick={event => pick(date, event.shiftKey)} onFocus={() => setFocus(date)}>{parseDate(date).getDate()}</button>;
          })}
        </div>;
      })}
    </div>
    {mode === 'range' && <p className="dt-cal-hint">{anchor ? t('再点一天，选出结束日期') : t('点一天，再点另一天可选范围；按住 Shift 点击也能延伸')}</p>}
  </div>;
}

export { localDate };
