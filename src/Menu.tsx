import { Check } from 'lucide-react';
import { useEffect, useLayoutEffect, useRef, useState, type MouseEvent } from 'react';

export interface MenuItem { label: string; onSelect: () => void; disabled?: boolean; danger?: boolean; checked?: boolean; dot?: string; }
export type MenuEntry = MenuItem | 'separator';
export interface MenuState {
  x: number; y: number; items: MenuEntry[];
  /** `above`: the menu's bottom edge sits at y (used for the composer). */
  placement?: 'below' | 'above';
  /** When false the menu never takes keyboard focus, so an input being edited keeps it. */
  keyboard?: boolean;
}
export type OpenMenu = (event: MouseEvent, items: MenuEntry[]) => void;

const MARGIN = 6;

/** A small floating menu for right-clicks and dropdowns: closes on outside click, Escape and blur; arrow keys move. */
export function Menu({ state, onClose }: { state: MenuState; onClose: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState({ left: state.x, top: state.y, ready: false });
  const hasMarks = state.items.some(entry => entry !== 'separator' && (entry.checked || entry.dot));

  useLayoutEffect(() => {
    const box = ref.current?.getBoundingClientRect();
    if (!box) return;
    const left = Math.max(MARGIN, Math.min(state.x, window.innerWidth - box.width - MARGIN));
    let top = state.placement === 'above' ? state.y - box.height - 4 : state.y;
    if (top + box.height > window.innerHeight - MARGIN) top = Math.max(MARGIN, state.placement === 'above' ? top : state.y - box.height);
    setPosition({ left, top: Math.max(MARGIN, top), ready: true });
  }, [state]);

  useEffect(() => {
    const outside = (event: PointerEvent) => { if (!ref.current?.contains(event.target as Node)) onClose(); };
    const key = (event: KeyboardEvent) => { if (event.key === 'Escape') { event.preventDefault(); onClose(); } };
    const away = () => onClose();
    document.addEventListener('pointerdown', outside, true);
    document.addEventListener('contextmenu', away, true);
    window.addEventListener('keydown', key);
    window.addEventListener('blur', away);
    return () => { document.removeEventListener('pointerdown', outside, true); document.removeEventListener('contextmenu', away, true); window.removeEventListener('keydown', key); window.removeEventListener('blur', away); };
  }, [onClose]);

  useEffect(() => { if (state.keyboard !== false) ref.current?.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus(); }, [state]);

  const move = (event: React.KeyboardEvent) => {
    const buttons = [...(ref.current?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)') ?? [])];
    if (!buttons.length) return;
    const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
    const next = event.key === 'ArrowDown' ? (index + 1) % buttons.length : event.key === 'ArrowUp' ? (index - 1 + buttons.length) % buttons.length : event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : -1;
    if (next >= 0) { event.preventDefault(); buttons[next].focus(); }
  };

  return <div ref={ref} className={`dt-menu ${hasMarks ? 'has-marks' : ''}`} role="menu" style={{ left: position.left, top: position.top, visibility: position.ready ? 'visible' : 'hidden', transformOrigin: state.placement === 'above' ? 'bottom left' : 'top left' }}
    // Keep focus where it is, so an input being edited does not lose it (and save) when a menu item is pressed.
    onMouseDown={event => event.preventDefault()} onKeyDown={move} onContextMenu={event => event.preventDefault()}>
    {state.items.map((entry, index) => entry === 'separator'
      ? <div key={index} className="dt-menu-sep" role="separator" />
      : <button key={index} type="button" role="menuitem" className={`dt-menu-item ${entry.danger ? 'is-danger' : ''}`} disabled={entry.disabled} onClick={() => { onClose(); entry.onSelect(); }}>
        {hasMarks && <span className="dt-menu-mark">{entry.checked ? <Check className="dt-svg" strokeWidth={2} /> : entry.dot ? <i className={`dt-menu-dot ${entry.dot}`} /> : null}</span>}
        {entry.label}
      </button>)}
  </div>;
}
