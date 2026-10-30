import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { afterEach, expect, it } from 'vitest';
import { dictionaries } from '../src/locales';
import { getLang, resolveLang, setLanguage, t, tError } from '../src/i18n';

afterEach(() => setLanguage('zh-CN'));

/** Every source string passed to t('…') plus the labels translated indirectly. */
function sourceKeys(): string[] {
  const dir = join(__dirname, '../src');
  const keys = new Set<string>();
  for (const file of readdirSync(dir).filter(name => /\.tsx?$/.test(name) && !/^(locales|i18n)\./.test(name))) {
    const text = readFileSync(join(dir, file), 'utf8');
    for (const match of text.matchAll(/\bt\(\s*'((?:[^'\\\n]|\\.)*)'/g)) keys.add(match[1]);
    for (const match of text.matchAll(/\bt\([^'\n]*\?\s*'([^']*)'\s*:\s*'([^']*)'/g)) { keys.add(match[1]); keys.add(match[2]); }
    for (const match of text.matchAll(/label: '([^']*[一-龥][^']*)'/g)) keys.add(match[1]);
  }
  return [...keys].filter(key => /[一-龥]/.test(key));
}

it('every translated string in the source has an entry in English, Traditional Chinese and Japanese', () => {
  const missing: string[] = [];
  for (const key of sourceKeys()) for (const lang of ['en', 'zh-TW', 'ja'] as const) if (!dictionaries[lang][key]) missing.push(`${lang}: ${key}`);
  expect(missing).toEqual([]);
});

it('translations keep the same {placeholders} as the source', () => {
  for (const [key, value] of Object.entries(dictionaries.en)) {
    const names = (text: string) => [...text.matchAll(/\{(\w+)\}/g)].map(m => m[1]).sort();
    for (const lang of ['en', 'zh-TW', 'ja'] as const) expect(names(dictionaries[lang][key] ?? ''), `${lang}: ${key}`).toEqual(names(key));
    expect(value.length).toBeGreaterThan(0);
  }
});

it('resolves system locales to the supported languages', () => {
  expect(resolveLang('system', 'zh-Hans-CN')).toBe('zh-CN');
  expect(resolveLang('system', 'zh-CN')).toBe('zh-CN');
  expect(resolveLang('system', 'zh-Hant-TW')).toBe('zh-TW');
  expect(resolveLang('system', 'zh-HK')).toBe('zh-TW');
  expect(resolveLang('system', 'ja-JP')).toBe('ja');
  expect(resolveLang('system', 'fr-FR')).toBe('en');
  expect(resolveLang('ja', 'en-US')).toBe('ja');
});

it('translates with placeholders, falls back to the source text, and leaves Chinese untouched', () => {
  setLanguage('en');
  expect(getLang()).toBe('en');
  expect(t('还有 {n} 件', { n: 3 })).toBe('3 left');
  expect(t('这条没有翻译')).toBe('这条没有翻译');
  setLanguage('ja');
  expect(t('今天')).toBe('今日');
  setLanguage('zh-CN');
  expect(t('还有 {n} 件', { n: 3 })).toBe('还有 3 件');
});

it('translates messages from the app core, including ones with a variable part', () => {
  setLanguage('en');
  expect(tError('至少保留一个分组')).toBe('Keep at least one group');
  expect(tError('快捷键「⌘ K」不可用，可能已被其他应用占用（oops）')).toContain('“⌘ K”');
  expect(tError('无法识别快捷键「x」')).toBe('Unrecognised shortcut “x”');
  setLanguage('zh-CN');
  expect(tError('至少保留一个分组')).toBe('至少保留一个分组');
});
