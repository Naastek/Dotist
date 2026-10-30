import { beforeEach } from 'vitest';
import { setLanguage } from '../src/i18n';

// The tests read Chinese labels; individual tests switch language explicitly.
beforeEach(() => { setLanguage('zh-CN'); });
