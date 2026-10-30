import { useSyncExternalStore } from 'react';
import { ERROR_PATTERNS, dictionaries } from './locales';

export type Lang = 'zh-CN' | 'en' | 'zh-TW' | 'ja';
export type LangSetting = 'system' | Lang;
export const LANGS: { id: Lang; label: string }[] = [
  { id: 'zh-CN', label: '简体中文' }, { id: 'zh-TW', label: '繁體中文' }, { id: 'en', label: 'English' }, { id: 'ja', label: '日本語' },
];

/** Maps a browser/system locale such as `zh-Hant-TW` or `en-US` to one of the supported languages. */
export function resolveLang(setting: LangSetting, system: string = typeof navigator === 'undefined' ? 'en' : navigator.language): Lang {
  if (setting !== 'system') return setting;
  const tag = system.toLowerCase();
  if (tag.startsWith('zh')) return /hant|-tw|-hk|-mo/.test(tag) ? 'zh-TW' : 'zh-CN';
  if (tag.startsWith('ja')) return 'ja';
  return 'en';
}

let current: Lang = resolveLang('system');
const listeners = new Set<() => void>();

export function getLang(): Lang { return current; }
export function setLanguage(setting: LangSetting) {
  const next = resolveLang(setting);
  if (next === current) return;
  current = next;
  document.documentElement.lang = next;
  listeners.forEach(listener => listener());
}
export function useLang(): Lang {
  return useSyncExternalStore(listener => { listeners.add(listener); return () => { listeners.delete(listener); }; }, getLang);
}

/** BCP 47 tag for Intl formatting. */
export function locale(): string { return { 'zh-CN': 'zh-CN', 'zh-TW': 'zh-TW', en: 'en-US', ja: 'ja-JP' }[current]; }

/**
 * Translates a source string (the Chinese text doubles as the key) and fills `{name}` placeholders.
 * Unknown text, including messages that already arrive in another language, is returned unchanged.
 */
export function t(text: string, params?: Record<string, string | number>): string {
  const table = current === 'zh-CN' ? undefined : dictionaries[current];
  const translated = table?.[text] ?? text;
  return params ? translated.replace(/\{(\w+)\}/g, (whole: string, name: string) => (name in params ? String(params[name]) : whole)) : translated;
}

/** Translates a message that came back from the app core, including ones with a variable part. */
export function tError(message: string): string {
  for (const [pattern, key, names] of ERROR_PATTERNS) {
    const match = pattern.exec(message);
    if (match) return t(key, Object.fromEntries(names.map((name, index) => [name, match[index + 1]])));
  }
  return t(message);
}
