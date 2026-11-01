import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';

let App: typeof import('../src/App').App;
let taskApi: typeof import('../src/taskApi').taskApi;
const originalPointer = window.PointerEvent;

beforeEach(async () => {
  try { localStorage.clear(); } catch { /* storage is unavailable in some test runtimes */ }
  vi.resetModules();
  window.PointerEvent = MouseEvent as typeof PointerEvent;
  window.history.pushState({}, '', '/?demo');
  ({ App } = await import('../src/App'));
  ({ taskApi } = await import('../src/taskApi'));
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); window.PointerEvent = originalPointer; });

async function dragBefore(sourceTitle: string, targetTitle: string) {
  const source = screen.getByRole('button', { name: `编辑 ${sourceTitle}` });
  const target = screen.getByRole('button', { name: `编辑 ${targetTitle}` }).closest('.dt-row')!;
  target.getBoundingClientRect = () => new DOMRect(0, 0, 200, 40);
  const original = document.elementFromPoint;
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => target });
  try {
    await act(async () => {
      fireEvent.pointerDown(source, { button: 0, buttons: 1, clientX: 10, clientY: 70 });
      fireEvent.pointerMove(source, { buttons: 1, clientX: 10, clientY: 10 });
      fireEvent.pointerUp(source, { button: 0, clientX: 10, clientY: 10 });
    });
  } finally {
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: original });
  }
}

it('reorders using captured pointer movement and keeps a drag from opening the editor', async () => {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  const source = screen.getByRole('button', { name: '编辑 回复项目消息' });
  const target = screen.getByRole('button', { name: '编辑 整理本周的工作计划' }).closest('.dt-row')!;
  target.getBoundingClientRect = () => new DOMRect(0, 0, 200, 40);
  const original = document.elementFromPoint;
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => target });
  try {
    fireEvent.pointerDown(source, { button: 0, buttons: 1, clientX: 10, clientY: 70 });
    fireEvent.pointerMove(source, { buttons: 1, clientX: 10, clientY: 10 });
    fireEvent.pointerUp(source, { button: 0, clientX: 10, clientY: 10 });
    fireEvent.click(source);
    const group = document.getElementById('group-work')!.closest('section')!;
    await waitFor(() => expect(within(group).getAllByRole('button', { name: /^编辑 / })[0].getAttribute('aria-label')).toBe('编辑 回复项目消息'));
    expect(screen.queryByRole('textbox', { name: '任务内容' })).toBeNull();
  } finally {
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: original });
  }
});

it('drags a task before a sibling and keeps its children attached after refreshing', async () => {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  await dragBefore('回复项目消息', '整理本周的工作计划');
  const group = document.getElementById('group-work')!.closest('section')!;
  await waitFor(() => expect(within(group).getAllByRole('button', { name: /^编辑 / }).slice(0, 2).map(item => item.getAttribute('aria-label'))).toEqual(['编辑 回复项目消息', '编辑 整理本周的工作计划']));
  fireEvent.focus(window);
  await waitFor(() => expect(within(group).getAllByRole('button', { name: /^编辑 / })[0].getAttribute('aria-label')).toBe('编辑 回复项目消息'));
  expect((await taskApi.list()).filter(task => task.parent_id === 'demo-0')).toHaveLength(3);
  fireEvent.click(screen.getByRole('button', { name: '编辑 回复项目消息' }));
  expect(screen.getByRole('textbox', { name: '任务内容' })).toBeTruthy();
});

it('reorders subtasks without changing their parent', async () => {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  fireEvent.click(screen.getByRole('button', { name: '子任务 1/3' }));
  await dragBefore('同步给团队', '列出三件最重要的事');
  const sub = screen.getByText('同步给团队').closest('ul')!;
  await waitFor(() => expect(within(sub).getAllByRole('button', { name: /^编辑 / }).map(item => item.getAttribute('aria-label'))).toEqual(['编辑 同步给团队', '编辑 列出三件最重要的事', '编辑 排进日历']));
  expect((await taskApi.list()).find(task => task.title === '同步给团队')?.parent_id).toBe('demo-0');
});

it('reorders across groups and levels in the today list without changing task data', async () => {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  const before = (await taskApi.list()).find(task => task.title === '下班后散步，顺路买些水果')!;
  fireEvent.click(screen.getByRole('tab', { name: '今天' }));
  await dragBefore('下班后散步，顺路买些水果', '整理本周的工作计划');
  const section = screen.getByRole('region', { name: '今天' });
  await waitFor(() => expect(within(section).getAllByRole('button', { name: /^编辑 / })[0].getAttribute('aria-label')).toBe('编辑 下班后散步，顺路买些水果'));
  const after = (await taskApi.list()).find(task => task.id === before.id)!;
  expect([after.category, after.parent_id, after.due_date]).toEqual([before.category, before.parent_id, before.due_date]);
  fireEvent.focus(window);
  await waitFor(() => expect(within(section).getAllByRole('button', { name: /^编辑 / })[0].getAttribute('aria-label')).toBe('编辑 下班后散步，顺路买些水果'));
});

it('does not move a grouped task into another group by dropping it there', async () => {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  const before = await taskApi.list();
  await dragBefore('回复项目消息', '给绿萝换盆');
  expect(await taskApi.list()).toEqual(before);
});

it('keeps the drag source mounted during an in-flight refresh and applies it after cancellation', async () => {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  let resolve!: (tasks: Awaited<ReturnType<typeof taskApi.list>>) => void;
  const updated = (await taskApi.list()).filter(task => task.id !== 'demo-1');
  vi.spyOn(taskApi, 'list').mockImplementationOnce(() => new Promise(done => { resolve = done; })).mockResolvedValue(updated);
  fireEvent.focus(window);
  const source = screen.getByRole('button', { name: '编辑 回复项目消息' });
  const original = document.elementFromPoint;
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => source.closest('.dt-row') });
  fireEvent.pointerDown(source, { button: 0, buttons: 1, clientY: 70 });
  fireEvent.pointerMove(source, { buttons: 1, clientY: 10 });
  await act(async () => { resolve(updated); });
  expect(source.isConnected).toBe(true);
  expect(source.closest('.dt-row')?.classList.contains('is-dragging')).toBe(true);
  fireEvent.pointerCancel(source);
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: original });
  await waitFor(() => expect(screen.queryByRole('button', { name: '编辑 回复项目消息' })).toBeNull());
});

it('Escape cancels a pointer drag without moving a task or opening the editor', async () => {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  const before = await taskApi.list();
  const source = screen.getByRole('button', { name: '编辑 回复项目消息' });
  const target = screen.getByRole('button', { name: '编辑 整理本周的工作计划' }).closest('.dt-row')!;
  target.getBoundingClientRect = () => new DOMRect(0, 0, 200, 40);
  const original = document.elementFromPoint;
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => target });
  try {
    fireEvent.pointerDown(source, { button: 0, buttons: 1, clientY: 70 });
    fireEvent.pointerMove(source, { buttons: 1, clientY: 10 });
    fireEvent.keyDown(window, { key: 'Escape' });
    fireEvent.pointerUp(source, { button: 0, clientY: 10 });
    fireEvent.click(source);
    expect(await taskApi.list()).toEqual(before);
    expect(screen.queryByRole('textbox', { name: '任务内容' })).toBeNull();
    expect(document.querySelector('.dt-row.is-dragging')).toBeNull();
  } finally {
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: original });
  }
});

it('scrolls a long task list while dragging near the edge and stops on Escape', async () => {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  const scroller = document.querySelector<HTMLElement>('.dt-scroll')!;
  Object.defineProperties(scroller, { clientHeight: { value: 200 }, scrollHeight: { value: 1000 } });
  scroller.getBoundingClientRect = () => new DOMRect(0, 0, 200, 200);
  const source = screen.getByRole('button', { name: '编辑 回复项目消息' });
  const target = screen.getByRole('button', { name: '编辑 整理本周的工作计划' }).closest('.dt-row')!;
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
    fireEvent.keyDown(window, { key: 'Escape' });
    expect(cancel).toHaveBeenCalledWith(123);
    const stoppedAt = scroller.scrollTop;
    act(() => frame(16));
    expect(scroller.scrollTop).toBe(stoppedAt);
  } finally {
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: original });
  }
});

it('uses the task currently under the pointer after a manual scroll', async () => {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  await taskApi.add('第三个工作任务', 'work');
  fireEvent.focus(window);
  const source = await screen.findByRole('button', { name: '编辑 第三个工作任务' });
  const first = screen.getByRole('button', { name: '编辑 整理本周的工作计划' }).closest('.dt-row')!;
  const second = screen.getByRole('button', { name: '编辑 回复项目消息' }).closest('.dt-row')!;
  first.getBoundingClientRect = second.getBoundingClientRect = () => new DOMRect(0, 0, 200, 40);
  const original = document.elementFromPoint;
  let hit: Element = first;
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => hit });
  try {
    fireEvent.pointerDown(source, { button: 0, buttons: 1, clientX: 10, clientY: 70 });
    fireEvent.pointerMove(source, { buttons: 1, clientX: 10, clientY: 10 });
    hit = second;
    fireEvent.scroll(document.querySelector('.dt-scroll')!);
    fireEvent.pointerUp(source, { button: 0, clientX: 10, clientY: 10 });
    const group = document.getElementById('group-work')!.closest('section')!;
    await waitFor(() => expect(within(group).getAllByRole('button', { name: /^编辑 / }).map(item => item.getAttribute('aria-label'))).toEqual(['编辑 整理本周的工作计划', '编辑 第三个工作任务', '编辑 回复项目消息']));
  } finally {
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: original });
  }
});

it('clears a drag and refreshes when the window collapses and expands', async () => {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  const updated = (await taskApi.list()).filter(task => task.id !== 'demo-1');
  const list = vi.spyOn(taskApi, 'list').mockResolvedValue(updated);
  const source = screen.getByRole('button', { name: '编辑 回复项目消息' });
  const original = document.elementFromPoint;
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => source.closest('.dt-row') });
  try {
    fireEvent.pointerDown(source, { button: 0, buttons: 1, clientY: 70 });
    fireEvent.pointerMove(source, { buttons: 1, clientY: 10 });
    fireEvent.focus(window);
    expect(list).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: '收起为悬浮球' }));
    const bubble = await screen.findByRole('button', { name: /点击展开/ }, { timeout: 2000 });
    expect(list).toHaveBeenCalled();
    fireEvent.pointerDown(bubble, { clientX: 5, clientY: 5, buttons: 1 });
    fireEvent.pointerUp(bubble);
    await screen.findByRole('tab', { name: '今天' });
    expect(screen.queryByRole('button', { name: '编辑 回复项目消息' })).toBeNull();
  } finally {
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: original });
  }
});

it('clears a drag if changing the perspective removes its source row', async () => {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  const source = screen.getByRole('button', { name: '编辑 回复项目消息' });
  const original = document.elementFromPoint;
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => source.closest('.dt-row') });
  const list = vi.spyOn(taskApi, 'list');
  try {
    fireEvent.pointerDown(source, { button: 0, buttons: 1, clientY: 70 });
    fireEvent.pointerMove(source, { buttons: 1, clientY: 10 });
    fireEvent.click(screen.getByRole('tab', { name: '无日期' }));
    expect(source.isConnected).toBe(false);
    fireEvent.focus(window);
    await waitFor(() => expect(list).toHaveBeenCalled());
  } finally {
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: original });
  }
});

it('uses the visible neighbor for keyboard ordering when a completed task is folded away', async () => {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  await taskApi.add('新的工作任务', 'work');
  fireEvent.focus(window);
  const source = await screen.findByRole('button', { name: '编辑 新的工作任务' });
  fireEvent.keyDown(source, { key: 'ArrowUp', altKey: true });
  const group = document.getElementById('group-work')!.closest('section')!;
  await waitFor(() => expect(within(group).getAllByRole('button', { name: /^编辑 / }).map(item => item.getAttribute('aria-label'))).toEqual(['编辑 整理本周的工作计划', '编辑 新的工作任务', '编辑 回复项目消息']));
});

it('supports keyboard ordering in a cross-group perspective', async () => {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
  fireEvent.click(screen.getByRole('tab', { name: '今天' }));
  const section = screen.getByRole('region', { name: '今天' });
  const titles = within(section).getAllByRole('button', { name: /^编辑 / });
  const first = titles[0].getAttribute('aria-label');
  const second = titles[1].getAttribute('aria-label');
  fireEvent.keyDown(titles[1], { key: 'ArrowUp', altKey: true });
  await waitFor(() => expect(within(section).getAllByRole('button', { name: /^编辑 / }).slice(0, 2).map(item => item.getAttribute('aria-label'))).toEqual([second, first]));
});
