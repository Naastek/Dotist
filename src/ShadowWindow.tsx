import { useEffect, useState } from 'react';
import { windowApi } from './windowApi';

const PAD = 80;

/** The soft shadow behind the main window. The native window around it is larger than the main window; the shape is inset by the padding. */
export function ShadowWindow() {
  const [top, setTop] = useState(PAD);
  const [size, setSize] = useState({ w: window.innerWidth, h: window.innerHeight });
  useEffect(() => {
    const off = windowApi.on<{ top: number }>('shadow-radius', next => setTop(next.top));
    const resize = () => setSize({ w: window.innerWidth, h: window.innerHeight });
    window.addEventListener('resize', resize);
    return () => { window.removeEventListener('resize', resize); void off.then(stop => stop()); };
  }, []);
  // The shape follows the real size of the window it sits behind (never a stale report): a small window is a circle or capsule.
  const w = Math.max(size.w - 2 * PAD, 0);
  const h = Math.max(size.h - top - PAD, 0);
  const radius = Math.min(w, h) <= 70 ? Math.round(Math.min(w, h) / 2) : 16;
  return <div className="dt-shadow-fill" style={{ borderRadius: radius, top, left: PAD, right: PAD, bottom: PAD }} />;
}
