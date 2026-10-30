import { expect, it } from 'vitest';
import { capsuleWidth } from '../src/measure';

it('sizes the hover capsule to its content: longer titles are wider, always more than the bubble', () => {
  const short = capsuleWidth('买菜', '还有 3 件');
  const long = capsuleWidth('整理本周的工作计划并同步给整个团队确认', '还有 3 件');
  expect(short).toBeGreaterThan(48);
  expect(long).toBeGreaterThan(short);
  expect(capsuleWidth('Buy milk', '还有 1 件')).toBeGreaterThan(48);
});
