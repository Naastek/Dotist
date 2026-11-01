import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';

let Views: typeof import('../src/Views').ViewsWindow;
let api: typeof import('../src/taskApi').taskApi;
let dates: typeof import('../src/dates');
const originalPointer = window.PointerEvent;

beforeEach(async () => {
  vi.resetModules();
  window.PointerEvent = MouseEvent as typeof PointerEvent;
  window.history.pushState({}, '', '/?demo&views');
  ({ ViewsWindow: Views } = await import('../src/Views'));
  ({ taskApi: api } = await import('../src/taskApi'));
  dates = await import('../src/dates');
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); window.PointerEvent = originalPointer; });

async function ready() {
  render(<Views />);
  await screen.findByRole('region', { name: '未排期' });
}

function drag(source: Element, target: Element) {
  target.getBoundingClientRect = () => new DOMRect(0, 0, 200, 40);
  const original = document.elementFromPoint;
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => target });
  try {
    fireEvent.pointerDown(source, { button: 0, buttons: 1, clientX: 10, clientY: 80 });
    fireEvent.pointerMove(source, { buttons: 1, clientX: 10, clientY: 10 });
    fireEvent.pointerUp(source, { button: 0, clientX: 10, clientY: 10 });
  } finally {
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: original });
  }
}

it('sorts calendar cards through pointer movement without changing dates', async () => {
  await ready();
  const section = screen.getByRole('region', { name: dates.fullDate(dates.localDate()) });
  const source = within(within(section).getByRole('article', { name: '下班后散步，顺路买些水果' })).getByText('下班后散步，顺路买些水果');
  const target = within(section).getByRole('article', { name: '整理本周的工作计划' });
  drag(source, target);
  await waitFor(() => expect(within(section).getAllByRole('article')[0].getAttribute('aria-label')).toBe('下班后散步，顺路买些水果'));
  expect((await api.list()).find(task => task.id === 'demo-6')?.due_date).toBe(dates.localDate());
});

it('moves a calendar task to another date through pointer movement', async () => {
  await ready();
  const source = within(screen.getByRole('article', { name: '给绿萝换盆' })).getByText('给绿萝换盆');
  const date = dates.addDays(dates.localDate(), 1);
  drag(source, screen.getByRole('gridcell', { name: dates.fullDate(date) }));
  await waitFor(async () => expect((await api.list()).find(task => task.id === 'demo-7')?.due_date).toBe(date));
});

it('moves a board task to another status through pointer movement', async () => {
  await ready();
  fireEvent.click(screen.getByRole('tab', { name: '看板' }));
  const panel = screen.getByRole('tabpanel');
  const source = within(within(panel).getByRole('article', { name: '给绿萝换盆' })).getByText('给绿萝换盆');
  drag(source, within(panel).getByRole('region', { name: '进行中' }));
  await within(within(panel).getByRole('region', { name: '进行中' })).findByRole('article', { name: '给绿萝换盆' });
  expect((await api.list()).find(task => task.id === 'demo-7')?.status).toBe('doing');
});

it('sorts Gantt task labels through pointer movement', async () => {
  await ready();
  fireEvent.click(screen.getByRole('tab', { name: '甘特' }));
  const panel = screen.getByRole('tabpanel');
  const source = within(panel).getByText('下班后散步，顺路买些水果', { selector: 'strong' });
  const target = within(panel).getByText('整理本周的工作计划', { selector: 'strong' }).closest('.dv-gantt-label')!;
  drag(source, target);
  await waitFor(() => expect(panel.querySelector('.dv-gantt-row .dv-gantt-label strong')?.textContent).toBe('下班后散步，顺路买些水果'));
});

it('Escape cancels a pointer drag before it can change status', async () => {
  await ready();
  fireEvent.click(screen.getByRole('tab', { name: '看板' }));
  const panel = screen.getByRole('tabpanel');
  const source = within(within(panel).getByRole('article', { name: '给绿萝换盆' })).getByText('给绿萝换盆');
  const target = within(panel).getByRole('region', { name: '进行中' });
  const original = document.elementFromPoint;
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => target });
  try {
    fireEvent.pointerDown(source, { button: 0, buttons: 1, clientY: 80 });
    fireEvent.pointerMove(source, { buttons: 1, clientY: 10 });
    fireEvent.keyDown(window, { key: 'Escape' });
    fireEvent.pointerUp(source, { button: 0, clientY: 10 });
    expect((await api.list()).find(task => task.id === 'demo-7')?.status).toBe('todo');
    expect(panel.querySelector('.is-dragging')).toBeNull();
  } finally {
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: original });
  }
});

it('does not select a summary’s original day after dragging it to another date', async () => {
  await ready();
  const today = dates.localDate();
  const yesterday = dates.addDays(today, -1);
  const tomorrow = dates.addDays(today, 1);
  const source = within(screen.getByRole('gridcell', { name: dates.fullDate(yesterday) })).getByText('回复项目消息');
  const target = screen.getByRole('gridcell', { name: dates.fullDate(tomorrow) });
  const original = document.elementFromPoint;
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => target });
  try {
    fireEvent.pointerDown(source, { button: 0, buttons: 1, clientY: 80 });
    fireEvent.pointerMove(source, { buttons: 1, clientY: 10 });
    fireEvent.pointerUp(source, { button: 0, clientY: 10 });
    fireEvent.click(source);
    expect(screen.getByRole('gridcell', { name: dates.fullDate(today) }).getAttribute('aria-selected')).toBe('true');
    await waitFor(async () => expect((await api.list()).find(task => task.id === 'demo-1')?.due_date).toBe(tomorrow));
  } finally {
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: original });
  }
});

it('scrolls the views window while dragging a card near the edge', async () => {
  await ready();
  const scroller = document.querySelector<HTMLElement>('.dv-content')!;
  Object.defineProperties(scroller, { clientHeight: { value: 200 }, scrollHeight: { value: 1000 } });
  scroller.getBoundingClientRect = () => new DOMRect(0, 0, 200, 200);
  const source = within(screen.getByRole('article', { name: '给绿萝换盆' })).getByText('给绿萝换盆');
  const target = screen.getByRole('gridcell', { name: dates.fullDate(dates.localDate()) });
  const original = document.elementFromPoint;
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => target });
  let frame!: FrameRequestCallback;
  vi.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => { frame = callback; return 123; });
  const cancel = vi.spyOn(window, 'cancelAnimationFrame').mockImplementation(() => {});
  try {
    fireEvent.pointerDown(source, { button: 0, buttons: 1, clientX: 10, clientY: 100 });
    fireEvent.pointerMove(source, { buttons: 1, clientX: 10, clientY: 190 });
    act(() => frame(0));
    expect(scroller.scrollTop).toBeGreaterThan(0);
    fireEvent.pointerCancel(source);
    expect(cancel).toHaveBeenCalledWith(123);
    const stoppedAt = scroller.scrollTop;
    act(() => frame(16));
    expect(scroller.scrollTop).toBe(stoppedAt);
  } finally {
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: original });
  }
});

it('uses the date under the pointer after a manual scroll', async () => {
  await ready();
  const source = within(screen.getByRole('article', { name: '给绿萝换盆' })).getByText('给绿萝换盆');
  const firstDate = dates.addDays(dates.localDate(), 1);
  const finalDate = dates.addDays(dates.localDate(), 2);
  let hit: Element = screen.getByRole('gridcell', { name: dates.fullDate(firstDate) });
  const original = document.elementFromPoint;
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => hit });
  try {
    fireEvent.pointerDown(source, { button: 0, buttons: 1, clientX: 10, clientY: 80 });
    fireEvent.pointerMove(source, { buttons: 1, clientX: 10, clientY: 10 });
    hit = screen.getByRole('gridcell', { name: dates.fullDate(finalDate) });
    fireEvent.scroll(document.querySelector('.dv-content')!);
    fireEvent.pointerUp(source, { button: 0, clientX: 10, clientY: 10 });
    await waitFor(async () => expect((await api.list()).find(task => task.id === 'demo-7')?.due_date).toBe(finalDate));
  } finally {
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: original });
  }
});
