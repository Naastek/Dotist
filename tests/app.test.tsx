import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

let App: typeof import('../src/App').App;

beforeEach(async () => {
  try { localStorage.clear(); } catch { /* ignore */ }
  vi.resetModules();
  window.history.pushState({}, '', '/?demo');
  ({ App } = await import('../src/App'));
});
afterEach(() => { cleanup(); vi.useRealTimers(); });

async function openManager() {
  fireEvent.click(screen.getByRole('button', { name: /分组：/ }));
  fireEvent.click(screen.getByRole('menuitem', { name: '管理分组…' }));
  await screen.findByRole('textbox', { name: '新分组名称' });
}

async function ready() {
  render(<App />);
  await screen.findByText('整理本周的工作计划');
}

describe('Dotist window', () => {
  it('shows groups, the remaining count and a folded completed list', async () => {
    await ready();
    expect(screen.getByRole('tab', { name: '今天' })).toBeTruthy();
    expect(screen.getByText('还有 5 件')).toBeTruthy();
    expect(screen.getByText('演示')).toBeTruthy();
    expect(screen.queryByText('提交周报')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: /已完成 1/ }));
    expect(screen.getByText('提交周报')).toBeTruthy();
  });

  it('a #tag typed into a title shows as a tag, and choosing it filters across groups', async () => {
    await ready();
    const input = screen.getByRole('textbox', { name: '新任务' });
    fireEvent.change(input, { target: { value: '写周报 #sideproject' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    const bar = await screen.findByRole('navigation', { name: '标签' });
    fireEvent.click(within(bar).getByRole('button', { name: '#sideproject' }));
    await waitFor(() => expect(screen.queryByText('整理本周的工作计划')).toBeNull());
    expect(screen.getByText('写周报')).toBeTruthy();
    fireEvent.click(within(screen.getByRole('navigation', { name: '标签' })).getByRole('button', { name: '#sideproject' }));
    await screen.findByText('整理本周的工作计划');
  });

  it('Enter in a task saves it and opens a new sibling; Shift+Enter stays in the task', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '编辑 回复项目消息' }));
    const input = screen.getByRole('textbox', { name: '任务内容' });
    fireEvent.keyDown(input, { key: 'Enter', shiftKey: true });
    expect(screen.getByRole('textbox', { name: '任务内容' })).toBeTruthy();
    fireEvent.keyDown(input, { key: 'Enter' });
    await waitFor(() => expect(screen.queryByRole('textbox', { name: '任务内容' })).toBeNull());
    expect(document.activeElement?.getAttribute('aria-label') ?? '').not.toBe('');
  });

  it('a parent with subtasks draws one arc per subtask in its circle', async () => {
    await ready();
    expect(document.querySelectorAll('.dt-segments circle').length).toBeGreaterThanOrEqual(3);
    expect(document.querySelectorAll('.dt-segments circle.is-done').length).toBe(1);
  });

  it('typing # offers the tags already in use; Tab completes one', async () => {
    await ready();
    const input = screen.getByRole('textbox', { name: '新任务' }) as HTMLInputElement;
    fireEvent.change(input, { target: { value: '写周报 #sideproject' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    await screen.findByRole('navigation', { name: '标签' });
    fireEvent.change(input, { target: { value: '再写一条 #si' } });
    const list = await screen.findByRole('listbox', { name: '标签' });
    expect(within(list).getByRole('option', { name: '#sideproject' })).toBeTruthy();
    fireEvent.keyDown(input, { key: 'Tab' });
    expect(input.value).toBe('再写一条 #sideproject ');
    expect(screen.queryByRole('listbox', { name: '标签' })).toBeNull();
  });

  it('the tag manager lists tags, renames them in every task and removes them', async () => {
    await ready();
    const input = screen.getByRole('textbox', { name: '新任务' });
    fireEvent.change(input, { target: { value: '写周报 #旧名' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    const bar = await screen.findByRole('navigation', { name: '标签' });
    fireEvent.click(within(bar).getByRole('button', { name: '管理…' }));
    fireEvent.click(await screen.findByRole('button', { name: '重命名标签 旧名' }));
    const field = screen.getByRole('textbox', { name: '标签名称' });
    fireEvent.change(field, { target: { value: '新名' } });
    fireEvent.keyDown(field, { key: 'Enter' });
    await screen.findByRole('button', { name: '查看标签 新名' });
    fireEvent.click(screen.getByRole('button', { name: '移除标签 新名' }));
    await waitFor(() => expect(screen.queryByRole('button', { name: '查看标签 新名' })).toBeNull());
    fireEvent.click(screen.getByRole('button', { name: '返回任务列表' }));
    expect(await screen.findByText('写周报')).toBeTruthy();
  });

  it('groups and tags are managed in one place and switch with tabs', async () => {
    await ready();
    await openManager();
    fireEvent.click(screen.getByRole('tab', { name: '标签' }));
    await screen.findByText(/标签写在任务标题里/);
    fireEvent.click(screen.getByRole('tab', { name: '分组' }));
    await screen.findByRole('textbox', { name: '新分组名称' });
  });

  it('edits a task in place: Enter saves, Esc cancels, IME Enter is ignored', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '编辑 回复项目消息' }));
    let input = screen.getByRole('textbox', { name: '任务内容' }) as HTMLInputElement;
    fireEvent.change(input, { target: { value: '放弃的改动' } });
    fireEvent.keyDown(input, { key: 'Escape' });
    expect(screen.getByText('回复项目消息')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: '编辑 回复项目消息' }));
    input = screen.getByRole('textbox', { name: '任务内容' }) as HTMLInputElement;
    fireEvent.change(input, { target: { value: '回复客户消息' } });
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 229, isComposing: true });
    expect(screen.getByRole('textbox', { name: '任务内容' })).toBeTruthy();
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
    await screen.findByText('回复客户消息');
    expect(screen.queryByRole('textbox', { name: '任务内容' })).toBeNull();
  });

  it('changes the group from the edit row dropdown without losing the edit', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '编辑 给绿萝换盆' }));
    fireEvent.click(screen.getByRole('button', { name: /分组：生活/ }));
    fireEvent.click(screen.getByRole('menuitem', { name: '学习' }));
    fireEvent.keyDown(screen.getByRole('textbox', { name: '任务内容' }), { key: 'Enter', keyCode: 13 });
    await waitFor(() => expect(within(document.getElementById('group-study')!.closest('section')!).getByText('给绿萝换盆')).toBeTruthy());
  });

  it('right-click on a task opens a menu with edit, subtask, due date, move and delete', async () => {
    await ready();
    fireEvent.contextMenu(screen.getByText('回复项目消息'));
    expect(screen.queryByRole('menuitem', { name: '编辑' })).toBeNull();
    expect(screen.queryByRole('menuitem', { name: '标为完成' })).toBeNull();
    const names = screen.getAllByRole('menuitem').map(item => item.textContent);
    expect(names).toEqual(expect.arrayContaining(['添加子任务', '修改到期日…', '缩进为上一条的子任务', '上移', '下移', '移到「生活」', '移到「学习」', '删除']));
    fireEvent.click(screen.getByRole('menuitem', { name: '缩进为上一条的子任务' }));
    await screen.findByRole('button', { name: '子任务 1/4' });
    fireEvent.contextMenu(screen.getByText('回复项目消息'));
    expect(screen.getByRole('menuitem', { name: '取消缩进' })).toBeTruthy();
    expect(screen.queryByRole('menuitem', { name: '添加子任务' })).toBeNull();
    fireEvent.keyDown(window, { key: 'Escape' });
    expect(screen.queryByRole('menu')).toBeNull();
  });

  it('the task menu can move to another group, set a due date and delete', async () => {
    await ready();
    fireEvent.contextMenu(screen.getByText('给绿萝换盆'));
    fireEvent.click(screen.getByRole('menuitem', { name: '移到「学习」' }));
    await waitFor(() => expect(within(document.getElementById('group-study')!.closest('section')!).getByText('给绿萝换盆')).toBeTruthy());
    fireEvent.contextMenu(screen.getByText('给绿萝换盆'));
    fireEvent.click(screen.getByRole('menuitem', { name: '设置到期日…' }));
    expect(screen.getByRole('group', { name: '到期日' })).toBeTruthy();
    fireEvent.contextMenu(screen.getByText('给绿萝换盆'));
    fireEvent.click(screen.getByRole('menuitem', { name: '删除' }));
    await waitFor(() => expect(screen.queryByText('给绿萝换盆')).toBeNull());
    expect(screen.getByRole('status').textContent).toContain('已删除');
  });

  it('right-click on a group label offers add, rename, recolor, reorder and delete', async () => {
    await ready();
    fireEvent.contextMenu(screen.getByText('学习', { selector: 'b' }));
    expect(screen.getAllByRole('menuitem').map(item => item.textContent)).toEqual(['添加任务', '重命名…', '换颜色', '上移', '下移', '删除分组']);
    expect((screen.getByRole('menuitem', { name: '下移' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole('menuitem', { name: '添加任务' }));
    await screen.findByRole('textbox', { name: '新任务（学习）' });
    fireEvent.contextMenu(screen.getByText('生活', { selector: 'b' }));
    fireEvent.click(screen.getByRole('menuitem', { name: '重命名…' }));
    const rename = await screen.findByRole('textbox', { name: '分组名称' });
    fireEvent.change(rename, { target: { value: '日常' } });
    fireEvent.keyDown(rename, { key: 'Enter', keyCode: 13 });
    await screen.findByRole('button', { name: '重命名「日常」' });
  });

  it('right-click on empty space offers new group, manage, settings and collapse', async () => {
    await ready();
    fireEvent.contextMenu(document.querySelector('.dt-scroll')!);
    expect(screen.getAllByRole('menuitem').map(item => item.textContent)).toEqual(['新建分组…', '管理分组…', '管理标签…', '查看今天', '任务视图', '收起为悬浮球']);
    fireEvent.click(screen.getByRole('menuitem', { name: '新建分组…' }));
    await screen.findByRole('textbox', { name: '新分组名称' });
  });

  it('the composer dropdown leads to the group manager', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: /分组：工作/ }));
    fireEvent.click(screen.getByRole('menuitem', { name: '管理分组…' }));
    await screen.findByRole('textbox', { name: '新分组名称' });
  });

  it('deletes without a dialog and restores through the undo toast', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '删除 给绿萝换盆' }));
    await waitFor(() => expect(screen.queryByText('给绿萝换盆')).toBeNull());
    expect(screen.queryByRole('alertdialog')).toBeNull();
    expect(screen.getByRole('status').textContent).toContain('已删除「给绿萝换盆」');
    fireEvent.click(screen.getByRole('button', { name: '撤销' }));
    await screen.findByText('给绿萝换盆');
  });

  it('dismisses the undo toast after five seconds', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '删除 给绿萝换盆' }));
    await screen.findByRole('status');
    await waitFor(() => expect(screen.queryByRole('status')).toBeNull(), { timeout: 6000 });
  }, 8000);

  it('shows subtask progress and lets the count toggle the subtasks', async () => {
    await ready();
    const toggle = screen.getByRole('button', { name: '子任务 1/3' });
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    fireEvent.click(toggle);
    expect(toggle.getAttribute('aria-expanded')).toBe('true');
    expect(screen.getByText('排进日历').closest('ul')!.hasAttribute('hidden')).toBe(false);
  });

  it('adds a subtask from the plus button and keeps one level only', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '添加子任务 回复项目消息' }));
    const input = screen.getByRole('textbox', { name: '新子任务' });
    fireEvent.change(input, { target: { value: '先看附件' } });
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
    await screen.findByText('先看附件');
    expect(screen.getByRole('button', { name: '子任务 0/1' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: '添加子任务 先看附件' })).toBeNull();
  });

  it('Shift+Tab in a new subtask promotes it to a top-level task', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '添加子任务 回复项目消息' }));
    const input = screen.getByRole('textbox', { name: '新子任务' });
    fireEvent.change(input, { target: { value: '升级成主任务' } });
    fireEvent.keyDown(input, { key: 'Tab', shiftKey: true });
    await screen.findByText('升级成主任务');
    expect(screen.queryByRole('textbox', { name: '新子任务' })).toBeNull();
    expect(screen.getByRole('button', { name: '添加子任务 升级成主任务' })).toBeTruthy();
  });

  it('Tab while editing indents the task under the one above; Shift+Tab brings it back out', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '编辑 回复项目消息' }));
    fireEvent.keyDown(screen.getByRole('textbox', { name: '任务内容' }), { key: 'Tab' });
    await screen.findByRole('button', { name: '子任务 1/4' });
    expect(screen.getByText('回复项目消息').closest('ul')!.classList.contains('dt-sub')).toBe(true);
    fireEvent.click(screen.getByRole('button', { name: '编辑 回复项目消息' }));
    fireEvent.keyDown(screen.getByRole('textbox', { name: '任务内容' }), { key: 'Tab', shiftKey: true });
    await screen.findByRole('button', { name: '子任务 1/3' });
    expect(screen.getByText('回复项目消息').closest('ul')!.classList.contains('dt-list')).toBe(true);
  });

  it('Tab on the first task of a group does nothing because there is nothing above it', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '编辑 整理本周的工作计划' }));
    fireEvent.keyDown(screen.getByRole('textbox', { name: '任务内容' }), { key: 'Tab' });
    expect(screen.getByRole('textbox', { name: '任务内容' })).toBeTruthy();
    fireEvent.keyDown(screen.getByRole('textbox', { name: '任务内容' }), { key: 'Escape' });
    expect(screen.getByRole('button', { name: '子任务 1/3' })).toBeTruthy();
  });

  it('adds a task from the row at the bottom of a group, and Tab makes it a subtask of the last task', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '在「学习」下添加任务' }));
    const input = screen.getByRole('textbox', { name: '新任务（学习）' });
    fireEvent.change(input, { target: { value: '做笔记' } });
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
    await screen.findByText('做笔记');
    expect(screen.getByRole('textbox', { name: '新任务（学习）' })).toBeTruthy();
    fireEvent.change(screen.getByRole('textbox', { name: '新任务（学习）' }), { target: { value: '整理摘要' } });
    fireEvent.keyDown(screen.getByRole('textbox', { name: '新任务（学习）' }), { key: 'Tab' });
    fireEvent.keyDown(screen.getByRole('textbox', { name: '新任务（学习）' }), { key: 'Enter', keyCode: 13 });
    await screen.findByRole('button', { name: '子任务 0/1' });
    expect(screen.getByText('整理摘要').closest('ul')!.classList.contains('dt-sub')).toBe(true);
  });

  it('hover actions are + subtask, due date and delete only; Alt+Arrow moves the focused task and there is no extra row under it', async () => {
    await ready();
    const row = screen.getByText('回复项目消息').closest('.dt-row') as HTMLElement;
    expect(within(row).getAllByRole('button').map(button => button.getAttribute('aria-label'))).toEqual(expect.not.arrayContaining(['上移 回复项目消息', '下移 回复项目消息']));
    expect(screen.queryByRole('button', { name: '在「给绿萝换盆」下添加子任务' })).toBeNull();
    const first = screen.getByRole('button', { name: '编辑 整理本周的工作计划' });
    const second = screen.getByRole('button', { name: '编辑 回复项目消息' });
    fireEvent.keyDown(second, { key: 'ArrowUp', altKey: true });
    await waitFor(() => expect(([...document.querySelectorAll('.dt-group.work .dt-list > .dt-item > .dt-row .dt-text')].map(el => el.textContent))).toEqual(['回复项目消息', '整理本周的工作计划']));
    expect(first).toBeTruthy();
    fireEvent.keyDown(screen.getByRole('button', { name: '编辑 回复项目消息' }), { key: 'ArrowUp', altKey: true });
    expect(([...document.querySelectorAll('.dt-group.work .dt-list > .dt-item > .dt-row .dt-text')].map(el => el.textContent))).toEqual(['回复项目消息', '整理本周的工作计划']);
    fireEvent.click(within(screen.getByText('给绿萝换盆').closest('.dt-row') as HTMLElement).getByRole('button', { name: '添加子任务 给绿萝换盆' }));
    const input = await screen.findByRole('textbox', { name: '新子任务' });
    fireEvent.change(input, { target: { value: '买新盆' } });
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
    await screen.findByText('买新盆');
    expect(screen.getByRole('button', { name: '子任务 0/1' })).toBeTruthy();
  });

  it('completing a parent completes its subtasks and moves it to the completed fold', async () => {
    await ready();
    fireEvent.click(screen.getByRole('checkbox', { name: '完成 整理本周的工作计划' }));
    await waitFor(() => expect(screen.queryByText('整理本周的工作计划')).toBeNull());
    expect(screen.getByRole('button', { name: /已完成 2/ })).toBeTruthy();
  });

  it('completing the last subtask does not complete the parent', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '子任务 1/3' }));
    fireEvent.click(screen.getByRole('checkbox', { name: '完成 排进日历' }));
    await screen.findByRole('button', { name: '子任务 2/3' });
    fireEvent.click(screen.getByRole('checkbox', { name: '完成 同步给团队' }));
    await screen.findByRole('button', { name: '子任务 3/3' });
    expect(screen.getByRole('checkbox', { name: '完成 整理本周的工作计划' }).getAttribute('aria-checked')).toBe('false');
  });

  it('collapses into the floating bubble, hover shows details, and only a click expands', async () => {
    const { windowApi } = await import('../src/windowApi');
    const handlers: Record<string, (payload: unknown) => void> = {};
    vi.spyOn(windowApi, 'on').mockImplementation((async (event: string, handler: (payload: unknown) => void) => { handlers[event] = handler; return () => {}; }) as never);
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '收起为悬浮球' }));
    const bubble = await screen.findByRole('button', { name: '还有 5 件，点击展开' }, { timeout: 2000 });
    expect(screen.queryByRole('tab', { name: '今天' })).toBeNull();
    const detail = bubble.querySelector('.dt-bubble-text')!;
    expect(detail.classList.contains('is-open')).toBe(false);
    act(() => handlers['pointer'](true));
    expect(detail.classList.contains('is-open')).toBe(true);
    expect(detail.textContent).toContain('整理本周的工作计划');
    await new Promise(resolve => setTimeout(resolve, 400));
    expect(screen.queryByRole('tab', { name: '今天' })).toBeNull();
    act(() => handlers['pointer'](false));
    await waitFor(() => expect(detail.classList.contains('is-open')).toBe(false));
    fireEvent.pointerDown(bubble, { clientX: 5, clientY: 5, buttons: 1 });
    fireEvent.pointerUp(bubble);
    await screen.findByRole('tab', { name: '今天' });
  });

  it('collapses on its own once the pointer has been away without activity', async () => {
    const { settingsApi } = await import('../src/settingsApi');
    await settingsApi.update({ auto_collapse_secs: 1 });
    await ready();
    await new Promise(resolve => setTimeout(resolve, 100));
    document.documentElement.dispatchEvent(new MouseEvent('mouseleave'));
    await screen.findByRole('button', { name: /点击展开/ }, { timeout: 5000 });
    expect(screen.queryByRole('tab', { name: '今天' })).toBeNull();
  }, 10000);

  it('does not auto-collapse while typing in the window', async () => {
    const { settingsApi } = await import('../src/settingsApi');
    await settingsApi.update({ auto_collapse_secs: 1 });
    vi.spyOn(document, 'hasFocus').mockReturnValue(true);
    await ready();
    screen.getByRole('textbox', { name: '新任务' }).focus();
    document.documentElement.dispatchEvent(new MouseEvent('mouseleave'));
    await new Promise(resolve => setTimeout(resolve, 3200));
    expect(screen.getByRole('tab', { name: '今天' })).toBeTruthy();
  }, 10000);

  it('does not auto-collapse when the setting is off', async () => {
    const { settingsApi } = await import('../src/settingsApi');
    await settingsApi.update({ auto_collapse_secs: 1, auto_collapse: false });
    await ready();
    await new Promise(resolve => setTimeout(resolve, 100));
    document.documentElement.dispatchEvent(new MouseEvent('mouseleave'));
    await new Promise(resolve => setTimeout(resolve, 3200));
    expect(screen.getByRole('tab', { name: '今天' })).toBeTruthy();
  }, 10000);

  it('the Calendar tab opens a calendar with week numbers; a day shows that day\'s tasks and new tasks are due that day', async () => {
    const { localDate, addDays, fullDate, isoWeek } = await import('../src/dates');
    const target = addDays(localDate(), 3);
    await ready();
    fireEvent.click(screen.getByRole('button', { name: /日历/ }));
    const dialog = await screen.findByRole('dialog', { name: '日历' });
    expect(within(dialog).getAllByRole('rowheader').some(cell => cell.textContent === String(isoWeek(localDate())))).toBe(true);
    for (let i = 0; i < 3 && !within(dialog).queryByRole('gridcell', { name: fullDate(target) }); i += 1) fireEvent.click(within(dialog).getByRole('button', { name: '下个月' }));
    fireEvent.click(within(dialog).getByRole('gridcell', { name: fullDate(target) }));
    const section = await screen.findByRole('region', { name: /·/ });
    expect(within(section).getByText('读完《人类简史》第三章')).toBeTruthy();
    expect(screen.queryByText('整理本周的工作计划')).toBeNull();
    expect(screen.getByText('还有 1 件')).toBeTruthy();
    const input = screen.getByRole('textbox', { name: '新任务' });
    fireEvent.change(input, { target: { value: '那天的事' } });
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
    await within(await screen.findByRole('region', { name: /·/ })).findByText('那天的事');
    fireEvent.click(screen.getByRole('tab', { name: '今天' }));
    await screen.findByRole('region', { name: '今天' });
  });

  it('picks a range in the calendar: the tab shows the range and tasks are listed per day', async () => {
    const { localDate, addDays, fullDate } = await import('../src/dates');
    const today = localDate();
    await ready();
    fireEvent.click(screen.getByRole('button', { name: /日历/ }));
    const dialog = await screen.findByRole('dialog', { name: '日历' });
    fireEvent.click(within(dialog).getByRole('gridcell', { name: fullDate(today) }));
    fireEvent.click(within(dialog).getByRole('gridcell', { name: fullDate(addDays(today, 3)) }));
    await screen.findAllByRole('region', { name: /·/ });
    expect(screen.getAllByRole('region', { name: /·/ }).length).toBeGreaterThanOrEqual(2);
    expect(screen.getByText('读完《人类简史》第三章')).toBeTruthy();
    expect(screen.getByText('整理本周的工作计划')).toBeTruthy();
  });

  it('the header filter strip has many filters; each one switches the view', async () => {
    await ready();
    const strip = screen.getByRole('tablist', { name: '视图' });
    expect(within(strip).getAllByRole('tab').map(tab => tab.textContent?.replace(/\d+$/, ''))).toEqual(['今天', '全部', '明天', '本周', '下周', '未来 7 天', '已逾期', '无日期', '已完成']);
    fireEvent.click(within(strip).getByRole('tab', { name: '明天' }));
    await screen.findByText(/没有安排/);
    expect(within(strip).getByRole('tab', { name: '明天' }).getAttribute('aria-selected')).toBe('true');
    fireEvent.click(within(strip).getByRole('tab', { name: /已逾期/ }));
    const overdue = await screen.findByRole('region', { name: '已逾期' });
    expect(within(overdue).getByText('回复项目消息')).toBeTruthy();
    expect(screen.queryByText('整理本周的工作计划')).toBeNull();
    fireEvent.click(within(strip).getByRole('tab', { name: '无日期' }));
    await screen.findByText('给绿萝换盆');
    expect(screen.queryByText('回复项目消息')).toBeNull();
    fireEvent.click(within(strip).getByRole('tab', { name: '已完成' }));
    await within(await screen.findByRole('region', { name: '已完成' })).findByText('提交周报');
    fireEvent.click(within(strip).getByRole('tab', { name: '本周' }));
    fireEvent.click(within(strip).getByRole('tab', { name: '全部' }));
    await screen.findByText('给绿萝换盆');
  });

  it('the Calendar tab shows a custom range as its label and its quick ranges match the filters', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: /日历/ }));
    const dialog = await screen.findByRole('dialog', { name: '日历' });
    fireEvent.click(within(dialog).getByRole('button', { name: '下周' }));
    await waitFor(() => expect(screen.getByRole('tab', { name: '下周' }).getAttribute('aria-selected')).toBe('true'));
  });

  it('the bubble opens its detail bar from native pointer events even without DOM hover', async () => {
    const { windowApi } = await import('../src/windowApi');
    const handlers: Record<string, (payload: unknown) => void> = {};
    vi.spyOn(windowApi, 'on').mockImplementation((async (event: string, handler: (payload: unknown) => void) => { handlers[event] = handler; return () => {}; }) as never);
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '收起为悬浮球' }));
    const bubble = await screen.findByRole('button', { name: /点击展开/ }, { timeout: 2000 });
    const detail = bubble.querySelector('.dt-bubble-text')!;
    expect(detail.classList.contains('is-open')).toBe(false);
    act(() => handlers['pointer'](true));
    expect(detail.classList.contains('is-open')).toBe(true);
    act(() => handlers['pointer'](false));
    await waitFor(() => expect(detail.classList.contains('is-open')).toBe(false));
  });

  it('every group has a + beside its name that adds a task to that group', async () => {
  await ready();
  fireEvent.click(screen.getByRole('button', { name: '添加到「学习」' }));
  const input = await screen.findByRole('textbox', { name: '新任务（学习）' });
  fireEvent.change(input, { target: { value: '从加号添加' } });
  fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
  await within(document.getElementById('group-study')!.closest('section')!).findByText('从加号添加');
  expect(screen.getAllByRole('button', { name: /^添加到「/ })).toHaveLength(3);
});

it('the lock keeps the window from collapsing on its own, unlike pin which only keeps it on top', async () => {
  const { settingsApi } = await import('../src/settingsApi');
  await settingsApi.update({ auto_collapse_secs: 1, locked: true });
  await ready();
  const lock = screen.getByRole('button', { name: '取消固定' });
  expect(lock.getAttribute('aria-pressed')).toBe('true');
  expect(screen.getByRole('button', { name: '取消置顶' }).getAttribute('aria-pressed')).toBe('true');
  await new Promise(resolve => setTimeout(resolve, 100));
  document.documentElement.dispatchEvent(new MouseEvent('mouseleave'));
  await new Promise(resolve => setTimeout(resolve, 3200));
  expect(screen.getByRole('tab', { name: '全部' })).toBeTruthy();
  fireEvent.click(lock);
  await screen.findByRole('button', { name: '固定窗口' });
  expect((await settingsApi.get()).locked).toBe(false);
}, 10000);

it('the menu bar submenus jump into a perspective or a group (also when the window was collapsed)', async () => {
  const { windowApi } = await import('../src/windowApi');
  const handlers: Record<string, (payload: unknown) => void> = {};
  vi.spyOn(windowApi, 'on').mockImplementation((async (event: string, handler: (payload: unknown) => void) => { handlers[event] = handler; return () => {}; }) as never);
  const sent = vi.spyOn(windowApi, 'setTrayGroups').mockResolvedValue();
  const scroll = vi.fn();
  Element.prototype.scrollIntoView = scroll;
  await ready();
  await waitFor(() => expect(sent).toHaveBeenCalledWith([['work', '工作'], ['life', '生活'], ['study', '学习']]));
  act(() => handlers['goto']({ filter: 'overdue', group: null }));
  await screen.findByRole('region', { name: '已逾期' });
  expect(screen.getByRole('tab', { name: /已逾期/ }).getAttribute('aria-selected')).toBe('true');
  act(() => handlers['goto']({ filter: null, group: 'study' }));
  await screen.findByText('给绿萝换盆');
  await waitFor(() => expect(scroll).toHaveBeenCalled());
  expect(document.getElementById('group-study')!.closest('section')!.className).toContain('is-flash');
  fireEvent.click(screen.getByRole('button', { name: '收起为悬浮球' }));
  await screen.findByRole('button', { name: /点击展开/ }, { timeout: 2000 });
  act(() => handlers['goto']({ filter: 'undated', group: null }));
  act(() => handlers['expand'](undefined));
  await screen.findByRole('tab', { name: '无日期' }, { timeout: 3000 });
  await waitFor(() => expect(screen.getByRole('tab', { name: '无日期' }).getAttribute('aria-selected')).toBe('true'));
}, 15000);

it('the frameless window has eight resize handles, and dragging one starts a native resize in that direction', async () => {
  const { windowApi } = await import('../src/windowApi');
  const resize = vi.spyOn(windowApi, 'startResize').mockResolvedValue();
  await ready();
  const grips = [...document.querySelectorAll<HTMLElement>('.dt-edge')];
  expect(grips.map(grip => grip.dataset.dir).sort()).toEqual(['East', 'North', 'NorthEast', 'NorthWest', 'South', 'SouthEast', 'SouthWest', 'West']);
  fireEvent.pointerDown(document.querySelector('.dt-edge[data-dir="SouthEast"]')!, { button: 0 });
  fireEvent.pointerDown(document.querySelector('.dt-edge[data-dir="West"]')!, { button: 0 });
  fireEvent.pointerDown(document.querySelector('.dt-edge[data-dir="North"]')!, { button: 2 });
  expect(resize.mock.calls.map(call => call[0])).toEqual(['SouthEast', 'West']);
});

it('the pin button toggles always-on-top', async () => {
    await ready();
    const pin = screen.getByRole('button', { name: '取消置顶' });
    expect(pin.getAttribute('aria-pressed')).toBe('true');
    fireEvent.click(pin);
    await screen.findByRole('button', { name: '置顶窗口' });
    expect((await (await import('../src/settingsApi')).settingsApi.get()).always_on_top).toBe(false);
  });

  it('manages groups: add, rename, recolor, reorder, delete with undo', async () => {
    await ready();
    await openManager();
    const add = screen.getByRole('textbox', { name: '新分组名称' });
    fireEvent.change(add, { target: { value: '健身' } });
    fireEvent.keyDown(add, { key: 'Enter', keyCode: 13 });
    await screen.findByRole('button', { name: '重命名「健身」' });
    fireEvent.click(screen.getByRole('button', { name: '重命名「健身」' }));
    const rename = screen.getByRole('textbox', { name: '分组名称' });
    fireEvent.change(rename, { target: { value: '运动' } });
    fireEvent.keyDown(rename, { key: 'Enter', keyCode: 13 });
    await screen.findByRole('button', { name: '重命名「运动」' });
    fireEvent.click(screen.getByRole('button', { name: '更改「运动」的颜色' }));
    await waitFor(() => expect(screen.getByRole('button', { name: '更改「运动」的颜色' }).closest('li')!.className).toContain('rose'));
    fireEvent.click(screen.getByRole('button', { name: '上移分组 运动' }));
    await waitFor(() => expect([...document.querySelectorAll('.dt-group-name')].map(el => el.textContent)).toEqual(['工作', '生活', '运动', '学习']));
    fireEvent.click(screen.getByRole('button', { name: '删除分组 生活' }));
    await waitFor(() => expect(screen.queryByRole('button', { name: '重命名「生活」' })).toBeNull());
    expect(screen.getByRole('status').textContent).toContain('已删除「分组 生活」');
    fireEvent.click(screen.getByRole('button', { name: '撤销' }));
    await screen.findByRole('button', { name: '重命名「生活」' });
    fireEvent.click(screen.getByRole('button', { name: '返回任务列表' }));
    await screen.findByText('下班后散步，顺路买些水果');
    expect(screen.getByText('运动')).toBeTruthy();
  });

  it('rejects duplicate group names and keeps the last group', async () => {
    await ready();
    await openManager();
    const add = screen.getByRole('textbox', { name: '新分组名称' });
    fireEvent.change(add, { target: { value: '工作' } });
    fireEvent.keyDown(add, { key: 'Enter', keyCode: 13 });
    await waitFor(() => expect(screen.getByRole('alert').textContent).toContain('同名'));
  });

  it('shows due date chips, with overdue ones marked', async () => {
    await ready();
    expect(screen.getByRole('button', { name: '到期日 昨天，点击修改' }).className).toContain('is-overdue');
    expect(screen.getAllByRole('button', { name: '到期日 今天，点击修改' }).length).toBeGreaterThan(0);
    expect(screen.getByRole('button', { name: /到期日 周.，点击修改|到期日 明天，点击修改|到期日 \d+月\d+日，点击修改/ })).toBeTruthy();
  });

  it('sets a due date from the picker shortcuts and the calendar, and clears it', async () => {
    const { fullDate } = await import('../src/dates');
    await ready();
    fireEvent.click(screen.getByRole('button', { name: '设置到期日 给绿萝换盆' }));
    fireEvent.click(within(screen.getByRole('group', { name: '到期日' })).getByRole('button', { name: '明天' }));
    await screen.findByRole('button', { name: '到期日 明天，点击修改' });
    fireEvent.click(screen.getByRole('button', { name: '到期日 明天，点击修改' }));
    const target = fullDate('2031-03-09');
    fireEvent.click(within(screen.getByRole('group', { name: '到期日' })).getByRole('button', { name: '下个月' }));
    for (let i = 0; i < 60 && !screen.queryByRole('gridcell', { name: target }); i += 1) fireEvent.click(within(screen.getByRole('group', { name: '到期日' })).getByRole('button', { name: '下个月' }));
    fireEvent.click(screen.getByRole('gridcell', { name: target }));
    await screen.findByRole('button', { name: '到期日 2031年3月9日，点击修改' });
    fireEvent.click(screen.getByRole('button', { name: '到期日 2031年3月9日，点击修改' }));
    fireEvent.click(within(screen.getByRole('group', { name: '到期日' })).getByRole('button', { name: '清除' }));
    await waitFor(() => expect(screen.queryByRole('button', { name: /到期日 2031/ })).toBeNull());
  });

  it('the Today scope lists overdue and due-today tasks across groups and hides the rest', async () => {
    await ready();
    fireEvent.click(screen.getByRole('tab', { name: '今天' }));
    await screen.findByRole('region', { name: '已逾期' });
    expect(within(screen.getByRole('region', { name: '已逾期' })).getByText('回复项目消息')).toBeTruthy();
    const today = screen.getByRole('region', { name: '今天' });
    expect(within(today).getByText('整理本周的工作计划')).toBeTruthy();
    expect(within(today).getByText('下班后散步，顺路买些水果')).toBeTruthy();
    expect(within(today).getByText('生活')).toBeTruthy();
    expect(screen.queryByText('给绿萝换盆')).toBeNull();
    expect(screen.queryByText('读完《人类简史》第三章')).toBeNull();
    expect(screen.getByText('还有 4 件')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /接下来 7 天 1/ }));
    expect(screen.getByText('读完《人类简史》第三章')).toBeTruthy();
    fireEvent.click(screen.getByRole('tab', { name: '全部' }));
    await screen.findByText('给绿萝换盆');
  });

  it('tasks added in the Today scope are due today, completing removes them from the list', async () => {
    await ready();
    fireEvent.click(screen.getByRole('tab', { name: '今天' }));
    const input = await screen.findByRole('textbox', { name: '新任务' });
    fireEvent.change(input, { target: { value: '今天新增的事' } });
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
    await within(await screen.findByRole('region', { name: '今天' })).findByText('今天新增的事');
    fireEvent.click(screen.getByRole('checkbox', { name: '完成 今天新增的事' }));
    await waitFor(() => expect(within(screen.getByRole('region', { name: '今天' })).queryByText('今天新增的事')).toBeNull());
    fireEvent.click(screen.getByRole('button', { name: /已完成/ }));
    expect(screen.getByText('今天新增的事')).toBeTruthy();
  });

  it('the Today scope hints when nothing is scheduled', async () => {
    const api = (await import('../src/taskApi')).taskApi;
    for (const task of await api.list()) await api.setDue(task.id, null);
    render(<App />);
    fireEvent.click(await screen.findByRole('tab', { name: '今天' }));
    await screen.findByText(/今天没有安排/);
  });

  it('shows the empty sentence when there are no tasks', async () => {
    const api = (await import('../src/taskApi')).taskApi;
    for (const task of await api.list()) if (!task.parent_id) await api.remove(task.id);
    render(<App />);
    await screen.findByText('把要做的事，放在这里。');
  });
});


it('opens task views from the header and background menu', async () => {
  const { windowApi } = await import('../src/windowApi');
  const open = vi.spyOn(windowApi, 'openViews').mockResolvedValue();
  await ready();
  fireEvent.click(screen.getByRole('button', { name: '任务视图' }));
  fireEvent.contextMenu(document.querySelector('.dt-scroll')!);
  fireEvent.click(screen.getByRole('menuitem', { name: '任务视图' }));
  expect(open).toHaveBeenCalledTimes(2);
});
