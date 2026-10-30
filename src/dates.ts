import { locale, t } from './i18n';

const pad = (value: number) => String(value).padStart(2, '0');

/** Local calendar date as `YYYY-MM-DD`; due dates carry no time of day. */
export function localDate(date: Date = new Date()): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}
export function parseDate(iso: string): Date {
  const [year, month, day] = iso.split('-').map(Number);
  return new Date(year, month - 1, day);
}
export function addDays(iso: string, days: number): string {
  const date = parseDate(iso);
  date.setDate(date.getDate() + days);
  return localDate(date);
}
export function addMonths(iso: string, months: number): string {
  const date = parseDate(iso);
  date.setDate(1);
  date.setMonth(date.getMonth() + months);
  return localDate(date);
}
export function daysBetween(from: string, to: string): number {
  return Math.round((parseDate(to).getTime() - parseDate(from).getTime()) / 86_400_000);
}

/** ISO 8601 week number (weeks start on Monday; week 1 contains the year's first Thursday). */
export function isoWeek(iso: string): number {
  const date = parseDate(iso);
  const weekday = (date.getDay() + 6) % 7;
  date.setDate(date.getDate() - weekday + 3);
  const firstThursday = new Date(date.getFullYear(), 0, 4);
  return 1 + Math.round(((date.getTime() - firstThursday.getTime()) / 86_400_000 - 3 + ((firstThursday.getDay() + 6) % 7)) / 7);
}

/** English weeks start on Sunday; the other supported languages start on Monday. */
export function weekStartsOn(): 0 | 1 { return locale().startsWith('en') ? 0 : 1; }

const format = (iso: string, options: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat(locale(), options).format(parseDate(iso));
export const monthDay = (iso: string) => format(iso, { month: 'short', day: 'numeric' });
export const fullDate = (iso: string) => format(iso, { dateStyle: 'full' });
export const monthTitle = (iso: string) => format(iso, { year: 'numeric', month: 'long' });
export const weekdayShort = (iso: string) => format(iso, { weekday: 'short' });
const yearMonthDay = (iso: string) => format(iso, { year: 'numeric', month: 'short', day: 'numeric' });

export type DueTone = 'overdue' | 'today' | 'soon' | 'later';
export interface DueInfo { text: string; tone: DueTone }

export function dueInfo(due: string, today: string): DueInfo {
  const diff = daysBetween(today, due);
  const sameYear = parseDate(due).getFullYear() === parseDate(today).getFullYear();
  const date = sameYear ? monthDay(due) : yearMonthDay(due);
  if (diff < 0) return { text: diff === -1 ? t('昨天') : date, tone: 'overdue' };
  if (diff === 0) return { text: t('今天'), tone: 'today' };
  if (diff === 1) return { text: t('明天'), tone: 'soon' };
  if (diff <= 6) return { text: weekdayShort(due), tone: 'soon' };
  return { text: date, tone: 'later' };
}

export interface DateRange { start: string; end: string }

/** Shortcuts offered next to the calendar. "下周一" is always strictly after today. */
export function quickDates(today: string): { label: string; date: string }[] {
  const weekday = parseDate(today).getDay();
  return [
    { label: t('今天'), date: today },
    { label: t('明天'), date: addDays(today, 1) },
    { label: t('下周一'), date: addDays(today, ((8 - weekday) % 7) || 7) },
  ];
}

/** Range shortcuts for the day view: this week, next week and the coming seven days. */
export function quickRanges(today: string): { label: string; range: DateRange }[] {
  const monday = addDays(today, -((parseDate(today).getDay() + 6) % 7));
  return [
    { label: t('今天'), range: { start: today, end: today } },
    { label: t('明天'), range: { start: addDays(today, 1), end: addDays(today, 1) } },
    { label: t('本周'), range: { start: monday, end: addDays(monday, 6) } },
    { label: t('下周'), range: { start: addDays(monday, 7), end: addDays(monday, 13) } },
    { label: t('未来 7 天'), range: { start: today, end: addDays(today, 6) } },
  ];
}

export function inRange(date: string, range: DateRange | null): boolean {
  return !!range && date >= range.start && date <= range.end;
}

/** Compact label for a viewed range: one day by name ("明天"), several days as "10月30日 – 11月5日". */
export function rangeLabel(range: DateRange, today: string): string {
  if (range.start === range.end) return range.start === today ? t('今天') : dueInfo(range.start, today).text;
  return `${monthDay(range.start)} – ${monthDay(range.end)}`;
}
