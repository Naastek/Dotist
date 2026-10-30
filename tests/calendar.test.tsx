import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { useState } from 'react';
import { afterEach, expect, it, vi } from 'vitest';
import { Calendar } from '../src/Calendar';
import { addDays, addMonths, fullDate, isoWeek, weekStartsOn, type DateRange } from '../src/dates';

afterEach(cleanup);
const TODAY = '2026-10-30'; // a Friday

function Harness({ mode, onChange }: { mode: 'single' | 'range'; onChange?: (range: DateRange) => void }) {
  const [value, setValue] = useState<DateRange | null>(null);
  return <Calendar mode={mode} today={TODAY} value={value} marks={new Set(['2026-10-31'])} onChange={range => { setValue(range); onChange?.(range); }} />;
}
const day = (iso: string) => screen.getByRole('gridcell', { name: fullDate(iso) });

it('computes ISO week numbers across year boundaries', () => {
  expect(isoWeek('2026-10-30')).toBe(44);
  expect(isoWeek('2026-01-01')).toBe(1);
  expect(isoWeek('2027-01-01')).toBe(53);
  expect(isoWeek('2024-12-30')).toBe(1);
  expect(isoWeek('2021-01-03')).toBe(53);
  expect(addMonths('2026-12-01', 1)).toBe('2027-01-01');
});

it('shows the month, a week-number column, today, and a dot on days that have tasks', () => {
  render(<Harness mode="single" />);
  expect(screen.getByText('2026年10月')).toBeTruthy();
  expect(weekStartsOn()).toBe(1);
  const weeks = screen.getAllByRole('rowheader').map(cell => cell.textContent);
  expect(weeks).toContain('44');
  expect(weeks).toHaveLength(6);
  expect(day(TODAY).getAttribute('aria-current')).toBe('date');
  expect(day('2026-10-31').className).toContain('has-tasks');
  expect(day('2026-10-30').className).toContain('is-today');
});

it('single mode selects one day', () => {
  const change = vi.fn();
  render(<Harness mode="single" onChange={change} />);
  fireEvent.click(day('2026-10-14'));
  expect(change).toHaveBeenCalledWith({ start: '2026-10-14', end: '2026-10-14' });
  expect(day('2026-10-14').getAttribute('aria-selected')).toBe('true');
});

it('range mode: the second click closes the range, in either order, and Shift extends', () => {
  const change = vi.fn();
  render(<Harness mode="range" onChange={change} />);
  fireEvent.click(day('2026-10-20'));
  expect(change).toHaveBeenLastCalledWith({ start: '2026-10-20', end: '2026-10-20' });
  expect(screen.getByText('再点一天，选出结束日期')).toBeTruthy();
  fireEvent.click(day('2026-10-24'));
  expect(change).toHaveBeenLastCalledWith({ start: '2026-10-20', end: '2026-10-24' });
  for (const date of ['2026-10-20', '2026-10-22', '2026-10-24']) expect(day(date).getAttribute('aria-selected')).toBe('true');
  expect(day('2026-10-25').getAttribute('aria-selected')).toBe('false');
  fireEvent.click(day('2026-10-12'));
  fireEvent.click(day('2026-10-08'));
  expect(change).toHaveBeenLastCalledWith({ start: '2026-10-08', end: '2026-10-12' });
  fireEvent.click(day('2026-10-27'), { shiftKey: true });
  expect(change).toHaveBeenLastCalledWith({ start: '2026-10-08', end: '2026-10-27' });
});

it('moves between months with the buttons and the keyboard', () => {
  render(<Harness mode="single" />);
  fireEvent.click(screen.getByRole('button', { name: '下个月' }));
  expect(screen.getByText('2026年11月')).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: '上个月' }));
  fireEvent.click(screen.getByRole('button', { name: '上个月' }));
  expect(screen.getByText('2026年9月')).toBeTruthy();
  fireEvent.click(within(screen.getByRole('group', { name: '日历' })).getByRole('button', { name: '今天' }));
  expect(screen.getByText('2026年10月')).toBeTruthy();
  const grid = screen.getByRole('grid');
  fireEvent.keyDown(grid, { key: 'ArrowDown' });
  expect(screen.getByText('2026年11月')).toBeTruthy();
  expect(document.activeElement?.getAttribute('data-date')).toBe(addDays(TODAY, 7));
  fireEvent.keyDown(grid, { key: 'PageUp' });
  expect(screen.getByText('2026年10月')).toBeTruthy();
});
