import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup } from '@testing-library/react';
import { TaskComposer } from '../src/TaskComposer';

const groups = [{ id: 'work', name: '工作', color: 'work', position: 0 }, { id: 'life', name: '生活', color: 'life', position: 1 }];

afterEach(cleanup);

describe('task input', () => {
  it('does not add a task when Enter confirms an IME composition', async () => {
    const add = vi.fn();
    render(<TaskComposer groups={groups} onAdd={add} />);
    const input = screen.getByRole('textbox', { name: '新任务' });
    fireEvent.compositionStart(input);
    fireEvent.change(input, { target: { value: 'zhong' } });
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 229, isComposing: true });
    expect(add).not.toHaveBeenCalled();
    fireEvent.change(input, { target: { value: '中文任务' } });
    fireEvent.compositionEnd(input, { data: '中文任务' });
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
    expect(add).toHaveBeenCalledTimes(1);
    expect(add).toHaveBeenCalledWith('中文任务', 'work');
    await waitFor(() => expect((input as HTMLInputElement).value).toBe(''));
  });

  it('picks the group from a dropdown menu and offers new/manage entries', () => {
    const add = vi.fn(); const onNew = vi.fn(); const onManage = vi.fn();
    render(<TaskComposer groups={groups} onNewGroup={onNew} onManageGroups={onManage} onAdd={add} />);
    fireEvent.click(screen.getByRole('button', { name: /分组：工作/ }));
    expect(screen.getAllByRole('menuitem').map(item => item.textContent)).toEqual(['管理分组…', '工作', '生活', '新建分组…']);
    fireEvent.click(screen.getByRole('menuitem', { name: '生活' }));
    expect(screen.queryByRole('menu')).toBeNull();
    const input = screen.getByRole('textbox', { name: '新任务' });
    fireEvent.change(input, { target: { value: '去超市' } });
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
    expect(add).toHaveBeenCalledWith('去超市', 'life');
    fireEvent.click(screen.getByRole('button', { name: /分组：生活/ }));
    fireEvent.click(screen.getByRole('menuitem', { name: '新建分组…' }));
    expect(onNew).toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: /分组：生活/ }));
    fireEvent.click(screen.getByRole('menuitem', { name: '管理分组…' }));
    expect(onManage).toHaveBeenCalled();
  });

  it('attaches a due date picked from the calendar popover, and the default due date otherwise', async () => {
    const add = vi.fn();
    const { rerender } = render(<TaskComposer groups={groups} today="2026-10-30" onAdd={add} />);
    const input = screen.getByRole('textbox', { name: '新任务' });
    fireEvent.click(screen.getByRole('button', { name: '设置到期日' }));
    const dialog = screen.getByRole('dialog', { name: '到期日' });
    expect(within(dialog).getByRole('group', { name: '日历' })).toBeTruthy();
    fireEvent.click(within(dialog).getByRole('button', { name: '明天' }));
    expect(screen.queryByRole('dialog')).toBeNull();
    fireEvent.change(input, { target: { value: '寄快递' } });
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
    expect(add).toHaveBeenLastCalledWith('寄快递', 'work', '2026-10-31');
    await waitFor(() => expect((input as HTMLInputElement).value).toBe(''));
    rerender(<TaskComposer groups={groups} today="2026-10-30" defaultDue="2026-10-30" onAdd={add} />);
    fireEvent.change(input, { target: { value: '今天的事' } });
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
    expect(add).toHaveBeenLastCalledWith('今天的事', 'work', '2026-10-30');
  });

  it('picks any day from the calendar grid', () => {
    const add = vi.fn();
    render(<TaskComposer groups={groups} today="2026-10-30" onAdd={add} />);
    fireEvent.click(screen.getByRole('button', { name: '设置到期日' }));
    fireEvent.click(screen.getByRole('gridcell', { name: /2026年11月5日/ }));
    expect(screen.getByRole('button', { name: /到期日：/ })).toBeTruthy();
    const input = screen.getByRole('textbox', { name: '新任务' });
    fireEvent.change(input, { target: { value: '开会' } });
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
    expect(add).toHaveBeenCalledWith('开会', 'work', '2026-11-05');
  });

  it('Escape closes the dropdown without choosing', () => {
    render(<TaskComposer groups={groups} onAdd={vi.fn()} />);
    fireEvent.click(screen.getByRole('button', { name: /分组：工作/ }));
    expect(screen.getByRole('menu')).toBeTruthy();
    fireEvent.keyDown(window, { key: 'Escape' });
    expect(screen.queryByRole('menu')).toBeNull();
  });

  it('ignores empty tasks', () => {
    const add = vi.fn();
    render(<TaskComposer groups={groups} onAdd={add} />);
    fireEvent.keyDown(screen.getByRole('textbox', { name: '新任务' }), { key: 'Enter', keyCode: 13 });
    expect(add).not.toHaveBeenCalled();
  });
});
