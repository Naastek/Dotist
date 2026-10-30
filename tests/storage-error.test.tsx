import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';

const api = vi.hoisted(() => ({
  list: vi.fn(async () => []),
  groups: vi.fn(async () => [{ id: 'work', name: '工作', color: 'work', position: 0 }]),
  add: vi.fn(async () => { throw new Error('磁盘写入失败'); }),
  patch: vi.fn(), remove: vi.fn(), restore: vi.fn(), move: vi.fn(),
}));
vi.mock('../src/taskApi', () => ({ taskApi: api, isDemo: true }));
import { App } from '../src/App';

afterEach(() => { cleanup(); vi.useRealTimers(); });

it('retains the input and the error when a database write fails, including after refresh', async () => {
  render(<App />);
  await waitFor(() => expect(api.list).toHaveBeenCalled());
  const input = screen.getByRole('textbox', { name: '新任务' }) as HTMLInputElement;
  fireEvent.change(input, { target: { value: '不能丢失的文字' } });
  fireEvent.click(screen.getByRole('button', { name: '添加任务' }));
  await waitFor(() => expect(screen.getByRole('alert').textContent).toContain('磁盘写入失败'));
  expect(input.value).toBe('不能丢失的文字');
  vi.useFakeTimers();
  await act(async () => { await vi.advanceTimersByTimeAsync(3000); });
  expect(screen.getByRole('alert').textContent).toContain('磁盘写入失败');
});
