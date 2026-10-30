const FONT_BODY = '500 13px "Source Sans 3", "Noto Sans SC", sans-serif';
const FONT_SMALL = '12px "Source Sans 3", "Noto Sans SC", sans-serif';
let context: CanvasRenderingContext2D | null | undefined;

function canvas(): CanvasRenderingContext2D | null {
  if (context !== undefined) return context;
  try { context = navigator.userAgent.includes('jsdom') ? null : document.createElement('canvas').getContext('2d'); } catch { context = null; }
  return context;
}

/** Rendered width in CSS px; falls back to a per-character estimate where canvas text measuring is unavailable. */
export function textWidth(text: string, font: string, size: number): number {
  const ctx = canvas();
  if (ctx) { ctx.font = font; return ctx.measureText(text).width; }
  return [...text].reduce((sum, char) => sum + (/[⺀-鿿＀-￯]/.test(char) ? size : size * 0.55), 0);
}

const CORE = 48;
const LEFT_GAP = 12;
const RIGHT_PAD = 18;

/** Width of the hover capsule for a title line and a detail line, including the 48px bubble core. */
export function capsuleWidth(title: string, detail: string): number {
  const text = Math.max(textWidth(title, FONT_BODY, 13), textWidth(detail, FONT_SMALL, 12));
  return Math.ceil(CORE + LEFT_GAP + text + RIGHT_PAD);
}
