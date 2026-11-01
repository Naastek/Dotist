import { useCallback, useEffect, useRef } from 'react';

/** Keeps a dragged task moving through a long list while the pointer stays near an edge. */
export function useDragScroll(selector: string, onScroll: (x: number, y: number) => void) {
  const callback = useRef(onScroll);
  callback.current = onScroll;
  const state = useRef<{ x: number; y: number; frame: number | null } | null>(null);
  const stop = useCallback(() => {
    if (state.current?.frame != null) cancelAnimationFrame(state.current.frame);
    state.current = null;
  }, []);
  useEffect(() => stop, [stop]);
  useEffect(() => {
    const onScroll = (event: Event) => {
      const current = state.current;
      const container = document.querySelector(selector);
      if (!current || !container || !(event.target instanceof Element)) return;
      if (event.target === container || container.contains(event.target)) callback.current(current.x, current.y);
    };
    document.addEventListener('scroll', onScroll, true);
    return () => document.removeEventListener('scroll', onScroll, true);
  }, [selector]);
  const update = (x: number, y: number) => {
    if (!state.current) state.current = { x, y, frame: null };
    else { state.current.x = x; state.current.y = y; }
    if (state.current.frame !== null) return;
    const step = () => {
      const current = state.current;
      if (!current) return;
      current.frame = null;
      const container = document.querySelector<HTMLElement>(selector);
      if (!container || container.scrollHeight <= container.clientHeight) return;
      const rect = container.getBoundingClientRect();
      if (current.x < rect.left || current.x > rect.right) return;
      const edge = Math.min(32, rect.height / 4);
      if (current.y < rect.top - edge || current.y > rect.bottom + edge) return;
      const direction = current.y < rect.top + edge ? -1 : current.y > rect.bottom - edge ? 1 : 0;
      if (!direction) return;
      const before = container.scrollTop;
      container.scrollTop += direction * 12;
      if (container.scrollTop === before) return;
      callback.current(current.x, current.y);
      current.frame = requestAnimationFrame(step);
    };
    state.current.frame = requestAnimationFrame(step);
  };
  return { update, stop };
}
