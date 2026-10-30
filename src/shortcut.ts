const NAMED: Record<string, string> = {
  Space: 'Space', Enter: 'Enter', Tab: 'Tab', Backspace: 'Backspace', Delete: 'Delete', Home: 'Home', End: 'End', PageUp: 'PageUp', PageDown: 'PageDown',
  ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right',
  Minus: 'Minus', Equal: 'Equal', Comma: 'Comma', Period: 'Period', Slash: 'Slash', Semicolon: 'Semicolon', Quote: 'Quote',
  Backquote: 'Backquote', BracketLeft: 'BracketLeft', BracketRight: 'BracketRight', Backslash: 'Backslash',
};

interface KeyLike { code: string; metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean }

/** Turns a keydown into a Tauri global-shortcut accelerator, or null while no valid combination is held. */
export function acceleratorFromEvent(event: KeyLike): string | null {
  const letter = /^Key([A-Z])$/.exec(event.code)?.[1];
  const digit = /^Digit(\d)$/.exec(event.code)?.[1];
  const fkey = /^F\d{1,2}$/.test(event.code) ? event.code : undefined;
  const key = letter ?? digit ?? fkey ?? NAMED[event.code];
  if (!key) return null;
  if (!fkey && !event.metaKey && !event.ctrlKey && !event.altKey) return null;
  return [event.metaKey && 'Command', event.ctrlKey && 'Control', event.altKey && 'Alt', event.shiftKey && 'Shift', key].filter(Boolean).join('+');
}

const SYMBOLS: Record<string, string> = { CommandOrControl: '⌘', Command: '⌘', Control: '⌃', Alt: '⌥', Shift: '⇧', Up: '↑', Down: '↓', Left: '←', Right: '→', Space: '空格', Minus: '-', Equal: '=', Comma: ',', Period: '.', Slash: '/', Semicolon: ';', Quote: "'", Backquote: '`', BracketLeft: '[', BracketRight: ']', Backslash: '\\' };

export function formatAccelerator(accelerator: string): string {
  if (!accelerator) return '未设置';
  return accelerator.split('+').map(part => SYMBOLS[part] ?? part).join(' ');
}
