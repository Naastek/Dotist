import { Check } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { t } from './i18n';
import { capsuleWidth } from './measure';
import { nextTask, remainingCount, totalCount } from './taskTree';
import type { GroupInfo, TodoTask } from './types';
import { isDragRelease, windowApi } from './windowApi';
import { isDemo } from './taskApi';

const RADIUS = 15;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

/** The floating bubble: hovering widens it into a capsule with details, clicking expands the window. */
export function Bubble({ tasks, groups, hoverDetails, onExpand }: { tasks: TodoTask[]; groups: GroupInfo[]; hoverDetails: boolean; onExpand: () => void }) {
  const remaining = remainingCount(tasks);
  const total = totalCount(tasks);
  const progress = total ? (total - remaining) / total : 0;
  const next = nextTask(tasks, groups);
  const [open, setOpen] = useState(false);
  const [drag, setDrag] = useState(false);
  const [side, setSide] = useState<'left' | 'right'>('right');
  const origin = useRef<{ x: number; y: number } | null>(null);
  const moved = useRef(false);
  const nativeInside = useRef(false);

  const title = next ? next.title : total ? t('今天的事都做完了') : t('把要做的事，放在这里。');
  const detail = next ? t('还有 {n} 件', { n: remaining }) : '';
  const hovering = useRef(false);
  const setHover = (value: boolean) => {
    if (!value && moved.current) return;
    if (value && !hoverDetails) return;
    if (hovering.current === value) return;
    hovering.current = value;
    if (value) setSide(window.screenX + window.innerWidth / 2 > window.screen.width / 2 ? 'right' : 'left');
    setOpen(value);
    void windowApi.setBubbleOpen(value, capsuleWidth(title, detail), window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ? 1 : undefined);
  };

  // The webview gets no hover events while the app is in the background; the native side reports the pointer too.
  const finish = (expand = false) => {
    const hadPointer = origin.current !== null;
    const wasDrag = moved.current;
    origin.current = null; moved.current = false; setDrag(false);
    if (wasDrag) setHover(nativeInside.current);
    if (expand && hadPointer && !wasDrag) onExpand();
  };
  const latest = useRef({ setHover, finish });
  latest.current = { setHover, finish };
  useEffect(() => {
    // Only the native pointer report drives the capsule: DOM hover events fire spuriously while the window resizes under the
    // pointer, which made it open and close in a loop. Closing waits a moment so a brief flicker never counts.
    let closing = 0;
    const offEnd = windowApi.on<unknown>('drag-end', payload => { if (moved.current && isDragRelease(payload)) latest.current.finish(); });
    const release = () => latest.current.finish();
    window.addEventListener('pointerup', release);
    const off = windowApi.on<boolean>('pointer', inside => {
      nativeInside.current = inside;
      window.clearTimeout(closing);
      if (moved.current) return;
      if (inside) latest.current.setHover(true);
      else closing = window.setTimeout(() => { if (!moved.current) latest.current.setHover(false); }, 220);
    });
    return () => { window.removeEventListener('pointerup', release); window.clearTimeout(closing); void off.then(stop => stop()); void offEnd.then(stop => stop()); };
  }, []);

  return <button type="button" className={`dt-bubble ${side === 'right' ? 'is-right' : ''} ${drag ? 'is-drag' : ''} `}
    aria-label={remaining ? t('还有 {n} 件，点击展开', { n: remaining }) : t('全部完成，点击展开')}
    onPointerDown={event => { if (event.button !== 0) return; origin.current = { x: event.clientX, y: event.clientY }; moved.current = false; event.currentTarget.setPointerCapture?.(event.pointerId); }}
    onPointerMove={event => {
      if (!origin.current || moved.current || event.buttons !== 1) return;
      if (Math.hypot(event.clientX - origin.current.x, event.clientY - origin.current.y) > 4) {
        moved.current = true; setDrag(true); void windowApi.startDragging().catch(() => latest.current.finish());
      }
    }}
    onPointerUp={() => finish(true)}
    // Native dragging takes capture away from the webview. Rust confirms its release independently.
    onPointerCancel={() => { if (isDemo || !moved.current) finish(); }}
    onLostPointerCapture={() => { if (isDemo || !moved.current) finish(); }}
    onKeyDown={event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); onExpand(); } }}>
    <span className="dt-bubble-core">
      <svg className="ring" viewBox="0 0 34 34" aria-hidden="true">
        <circle className="track" cx="17" cy="17" r={RADIUS} />
        <circle className="arc" cx="17" cy="17" r={RADIUS} strokeDasharray={`${CIRCUMFERENCE * progress} ${CIRCUMFERENCE}`} />
      </svg>
      {remaining === 0 && total > 0 ? <Check className="dt-svg" /> : <b>{remaining}</b>}
    </span>
    <span className={`dt-bubble-text ${open ? 'is-open' : ''}`} aria-hidden={!open}>
      <strong>{title}</strong>{detail}
    </span>
  </button>;
}
