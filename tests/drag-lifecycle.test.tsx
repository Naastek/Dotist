import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';

const handlers: Record<string, (payload?: unknown) => void> = {};
let api: typeof import('../src/taskApi').taskApi;
let windowApi: typeof import('../src/windowApi').windowApi;
let Views: typeof import('../src/Views').ViewsWindow;
const originalPointer = window.PointerEvent;
beforeEach(async () => {
  vi.resetModules();
  window.history.pushState({}, '', '/?demo&views');
  window.PointerEvent = MouseEvent as typeof PointerEvent;
  ({ windowApi } = await import('../src/windowApi'));
  vi.spyOn(windowApi, 'on').mockImplementation((async (event: string, handler: (payload?: unknown) => void) => {
    handlers[event] = handler; return () => {};
  }) as never);
  api = (await import('../src/taskApi')).taskApi;
  ({ ViewsWindow: Views } = await import('../src/Views'));
});
afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks(); window.PointerEvent = originalPointer; });

it('uses an instant capsule resize when reduced motion is requested', async () => {
  const original = window.matchMedia;
  Object.defineProperty(window, 'matchMedia', { configurable: true, value: () => ({ matches: true }) });
  try {
    const { Bubble } = await import('../src/Bubble');
    const resize = vi.spyOn(windowApi, 'setBubbleOpen');
    render(<Bubble tasks={await api.list()} groups={await api.groups()} hoverDetails onExpand={() => {}} />);
    act(() => handlers.pointer(true));
    expect(resize).toHaveBeenCalledWith(true, expect.any(Number), 1);
  } finally {
    Object.defineProperty(window, 'matchMedia', { configurable: true, value: original });
  }
});

it('bubble stays selected through stale drag-end, pending close and seconds without motion until release', async () => {
  const { Bubble } = await import('../src/Bubble');
  const expand = vi.fn();
  render(<Bubble tasks={await api.list()} groups={await api.groups()} hoverDetails onExpand={expand} />);
  const bubble = screen.getByRole('button');
  bubble.setPointerCapture = vi.fn();
  vi.useFakeTimers();
  act(() => handlers.pointer(true));
  act(() => handlers.pointer(false)); // closing was already queued before dragging
  fireEvent.pointerDown(bubble, { button: 0, clientX: 5, clientY: 5, buttons: 1 });
  fireEvent.pointerMove(bubble, { clientX: 15, clientY: 5, buttons: 1 });
  expect(bubble.classList.contains('is-drag')).toBe(true);
  act(() => { vi.advanceTimersByTime(180); handlers['drag-end'](); });
  expect(bubble.classList.contains('is-drag')).toBe(true);
  act(() => { fireEvent.blur(window); vi.advanceTimersByTime(6000); });
  expect(bubble.classList.contains('is-drag')).toBe(true);
  expect(bubble.querySelector('.dt-bubble-text')!.classList.contains('is-open')).toBe(true);
  fireEvent.pointerUp(window);
  expect(bubble.classList.contains('is-drag')).toBe(false);
  expect(expand).not.toHaveBeenCalled();
});

it('bubble accepts a native confirmed release and remains clickable afterwards', async () => {
  const { Bubble } = await import('../src/Bubble');
  const expand = vi.fn();
  render(<Bubble tasks={[]} groups={[]} hoverDetails onExpand={expand} />);
  const bubble = screen.getByRole('button'); bubble.setPointerCapture = vi.fn();
  fireEvent.pointerDown(bubble, { button: 0, clientX: 0, buttons: 1 });
  fireEvent.pointerMove(bubble, { clientX: 20, buttons: 1 });
  act(() => handlers['drag-end']({ released: true }));
  expect(bubble.classList.contains('is-drag')).toBe(false);
  fireEvent.pointerDown(bubble, { button: 0 }); fireEvent.pointerUp(bubble);
  expect(expand).toHaveBeenCalledOnce();
  fireEvent.pointerDown(bubble, { button: 0 });
  act(() => handlers['drag-end']({ released: true }));
  fireEvent.pointerUp(bubble);
  expect(expand).toHaveBeenCalledTimes(2);
});

it.each(['pointerUp', 'pointerCancel', 'lostPointerCapture'] as const)('gantt freezes refresh and preview until %s, then commits or rolls back', async endEvent => {
  const dates = await import('../src/dates');
  const start = dates.localDate().slice(0, 7) + '-10', end = dates.addDays(start, 4);
  await api.setDateRange('demo-0', start, end);
  vi.useFakeTimers();
  await act(async () => { render(<Views />); });
  expect(screen.getByRole('region', { name: '未排期' })).toBeTruthy();
  fireEvent.click(screen.getByRole('tab', { name: '甘特' }));
  const bar = screen.getByRole('button', { name: '甘特任务 整理本周的工作计划' });
  bar.setPointerCapture = vi.fn();
  bar.getBoundingClientRect = () => new DOMRect(100, 0, 100, 20);
  const count = document.querySelectorAll('.dv-gantt-dates span').length;
  bar.parentElement!.getBoundingClientRect = () => new DOMRect(0, 0, count * 10, 20);
  fireEvent.pointerDown(bar, { button: 0, clientX: 150 });
  fireEvent.pointerMove(bar, { clientX: 160 });
  const preview = bar.title;
  // A refresh that would remove the source must wait.
  await api.setDateRange('demo-0', null, null);
  await act(async () => { handlers['tasks-changed'](); fireEvent.blur(window); fireEvent.focus(window); await vi.advanceTimersByTimeAsync(6500); });
  expect(bar.isConnected).toBe(true);
  expect(bar.title).toBe(preview);
  expect(bar.classList.contains('is-dragging')).toBe(true);
  await act(async () => { fireEvent[endEvent](bar, { clientX: 160, bubbles: true }); });
  expect(document.querySelector('.dv-gantt-bar.is-dragging')).toBeNull();
  const task = (await api.list()).find(task => task.id === 'demo-0')!;
  expect(task.start_date).toBe(endEvent === 'pointerUp' ? dates.addDays(start, 1) : null);
  if (endEvent !== 'pointerUp') expect(bar.isConnected).toBe(false);
});

it.each(['calendar', 'board'] as const)('%s keeps the HTML drag source through timers and refresh until dragend', async view => {
  vi.useFakeTimers();
  await act(async () => { render(<Views />); });
  expect(screen.getByRole('region', { name: '未排期' })).toBeTruthy();
  if (view === 'board') fireEvent.click(screen.getByRole('tab', { name: '看板' }));
  const source = screen.getByRole('article', { name: '给绿萝换盆' });
  const values: Record<string, string> = {};
  const dataTransfer = { setData: (key: string, value: string) => { values[key] = value; }, getData: (key: string) => values[key], types: ['application/x-dotist-task'], effectAllowed: '', dropEffect: '' };
  fireEvent.dragStart(source, { dataTransfer });
  expect(source.classList.contains('is-dragging')).toBe(true);
  const plant = (await api.list()).find(task => task.title === '给绿萝换盆')!;
  await api.patch(plant.id, { status: 'done' });
  await api.setDue(plant.id, '2026-12-01');
  await act(async () => { handlers['tasks-changed'](); fireEvent.blur(window); await vi.advanceTimersByTimeAsync(6500); });
  expect(source.isConnected).toBe(true);
  expect(source.classList.contains('is-dragging')).toBe(true);
  await act(async () => { fireEvent.dragEnd(source, { dataTransfer }); }); // browser emits this on Escape too
  expect(source.classList.contains('is-dragging')).toBe(false);
  expect(source.isConnected).toBe(false);
});

it.each(['calendar', 'board'] as const)('%s flushes a deferred refresh after a successful drop', async view => {
  vi.useFakeTimers();
  await act(async () => { render(<Views />); });
  expect(screen.getByRole('region', { name: '未排期' })).toBeTruthy();
  if (view === 'board') fireEvent.click(screen.getByRole('tab', { name: '看板' }));
  const source = screen.getByRole('article', { name: '给绿萝换盆' });
  const values: Record<string, string> = {};
  const dataTransfer = { setData: (key: string, value: string) => { values[key] = value; }, getData: (key: string) => values[key], types: ['application/x-dotist-task'], effectAllowed: '', dropEffect: '' };
  fireEvent.dragStart(source, { dataTransfer });
  await act(async () => { handlers['tasks-changed'](); await vi.advanceTimersByTimeAsync(6500); });
  expect(source.classList.contains('is-dragging')).toBe(true);
  const date = (await import('../src/dates')).addDays((await import('../src/dates')).localDate().slice(0, 7) + '-01', 1);
  const target = view === 'board' ? screen.getByRole('region', { name: '完成' }) : document.getElementById(`dv-day-${date}`)!;
  await act(async () => { fireEvent.drop(target, { dataTransfer }); });
  expect(document.querySelector('.is-dragging')).toBeNull();
  const plant = (await api.list()).find(task => task.title === '给绿萝换盆')!;
  if (view === 'board') expect(plant.status).toBe('done');
  else expect(plant.due_date).toBe(date);
});

it('defers a read that was already in flight before gantt pointerdown', async () => {
  const dates = await import('../src/dates');
  const start = dates.localDate().slice(0, 7) + '-10';
  await api.setDateRange('demo-0', start, dates.addDays(start, 4));
  vi.useFakeTimers();
  await act(async () => { render(<Views />); });
  expect(screen.getByRole('region', { name: '未排期' })).toBeTruthy();
  fireEvent.click(screen.getByRole('tab', { name: '甘特' }));
  const bar = screen.getByRole('button', { name: '甘特任务 整理本周的工作计划' });
  const next = (await api.list()).filter(task => task.id !== 'demo-0');
  let resolve!: (value: typeof next) => void;
  vi.spyOn(api, 'list').mockImplementationOnce(() => new Promise(done => { resolve = done; }));
  act(() => handlers['tasks-changed']());
  bar.setPointerCapture = vi.fn();
  fireEvent.pointerDown(bar, { button: 0, clientX: 0 });
  await act(async () => { resolve(next); });
  expect(bar.isConnected).toBe(true);
  expect(bar.classList.contains('is-dragging')).toBe(true);
  await act(async () => { fireEvent.pointerCancel(bar); });
  expect(document.querySelector('.dv-gantt-bar.is-dragging')).toBeNull();
});

it('main window stays expanded while held outside and resumes auto-collapse after pointerup', async () => {
  vi.spyOn(document, 'hasFocus').mockReturnValue(false);
  const { settingsApi } = await import('../src/settingsApi');
  const settings = await settingsApi.update({ auto_collapse_secs: 1, auto_collapse: true, locked: false });
  const { App } = await import('../src/App');
  vi.useFakeTimers();
  await act(async () => { render(<App />); });
  act(() => handlers['settings-changed'](settings));
  fireEvent.pointerDown(screen.getByRole('banner'), { button: 0, buttons: 1 });
  act(() => { handlers.pointer(false); document.documentElement.dispatchEvent(new MouseEvent('mouseleave')); fireEvent.blur(window); });
  await act(async () => { await vi.advanceTimersByTimeAsync(6000); });
  expect(screen.getByRole('tab', { name: '今天' })).toBeTruthy();
  fireEvent.pointerUp(window, { button: 0 });
  await act(async () => { await vi.advanceTimersByTimeAsync(3000); });
  expect(screen.queryByRole('tab', { name: '今天' })).toBeNull();
  expect(screen.getByRole('button', { name: /点击展开/ })).toBeTruthy();
});

it('accepts only explicit release payloads', async () => {
  const { isDragRelease } = await import('../src/windowApi');
  expect(isDragRelease({ released: true })).toBe(true);
  for (const payload of [undefined, null, false, true, {}, { released: false }]) expect(isDragRelease(payload)).toBe(false);
});

it('native bubble keeps selection when the OS takes pointer capture, until Rust confirms release', async () => {
  window.history.pushState({}, '', '/');
  vi.resetModules();
  const { windowApi: nativeWindow } = await import('../src/windowApi');
  vi.spyOn(nativeWindow, 'on').mockImplementation((async (event: string, handler: (payload?: unknown) => void) => {
    handlers[event] = handler; return () => {};
  }) as never);
  vi.spyOn(nativeWindow, 'startDragging').mockResolvedValue();
  const { Bubble } = await import('../src/Bubble');
  const expand = vi.fn();
  render(<Bubble tasks={[]} groups={[]} hoverDetails onExpand={expand} />);
  const bubble = screen.getByRole('button'); bubble.setPointerCapture = vi.fn();
  vi.useFakeTimers();
  fireEvent.pointerDown(bubble, { button: 0, clientX: 0, buttons: 1 });
  fireEvent.pointerMove(bubble, { clientX: 20, buttons: 1 });
  fireEvent.lostPointerCapture(bubble); fireEvent.pointerCancel(bubble);
  act(() => { handlers['drag-end'](); vi.advanceTimersByTime(6000); });
  expect(bubble.classList.contains('is-drag')).toBe(true);
  act(() => handlers['drag-end']({ released: true }));
  expect(bubble.classList.contains('is-drag')).toBe(false);
  expect(expand).not.toHaveBeenCalled();
});
