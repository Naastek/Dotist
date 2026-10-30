import { expect, it } from 'vitest';
import { acceleratorFromEvent, formatAccelerator } from '../src/shortcut';

const key = (code: string, mods: Partial<{ metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean }> = {}) =>
  ({ code, metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...mods });

it('builds accelerators from key events and requires a real modifier', () => {
  expect(acceleratorFromEvent(key('KeyD', { metaKey: true, altKey: true }))).toBe('Command+Alt+D');
  expect(acceleratorFromEvent(key('Digit1', { ctrlKey: true, shiftKey: true }))).toBe('Control+Shift+1');
  expect(acceleratorFromEvent(key('Space', { altKey: true }))).toBe('Alt+Space');
  expect(acceleratorFromEvent(key('F5'))).toBe('F5');
  expect(acceleratorFromEvent(key('KeyD'))).toBeNull();
  expect(acceleratorFromEvent(key('KeyD', { shiftKey: true }))).toBeNull();
  expect(acceleratorFromEvent(key('MetaLeft', { metaKey: true }))).toBeNull();
});

it('formats accelerators with Mac symbols', () => {
  expect(formatAccelerator('CommandOrControl+Alt+D')).toBe('⌘ ⌥ D');
  expect(formatAccelerator('Control+Shift+Up')).toBe('⌃ ⇧ ↑');
  expect(formatAccelerator('')).toBe('未设置');
});
