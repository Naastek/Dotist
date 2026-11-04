import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
const height = html.match(/const height=r=>r\.level\?28:32;/)?.[0];
const block = html.split('\n').find(line => line.startsWith('function blockHeight('));
assert.ok(height && block, 'geometry helpers must remain available');
const measure = runInNewContext(`${height}\n${block}\nblockHeight`);
for (const [rows, base, level, expected] of [
  [[{level: 0}], 0, 0, 32], [[{level: 0}], 0, 1, 28],
  [[{level: 1}], 1, 0, 32], [[{level: 0},{level: 1}], 0, 1, 56],
  [[{level: 1},{level: 2}], 1, 0, 60],
]) assert.equal(measure(rows, base, level), expected);
assert.match(html, /d\.h=blockHeight\(d\.block,d\.base,level\)/);
assert.match(html, /classList\.toggle\('sub',l>0\)/);
console.log('drag block geometry: 5 indentation cases passed');

const source = ['function layout(', 'function gapLimit(', 'function boundedCenter(']
  .map(prefix => html.split('\n').find(line => line.startsWith(prefix)));
assert.ok(source.every(Boolean), 'position helpers must remain available');
const geometry = runInNewContext(`${height}\n${source.join('\n')}\n({layout,gapLimit,boundedCenter})`);
const model = geometry.layout([
  {name:'A',rows:[{level:0},{level:1}]},
  {name:'B',rows:[{level:0},{level:0}]},
  {name:'C',rows:[]},
]);
let cases = 0;
for (const target of model.bounds) for (const h of [28,32,56,60]) {
  const limit = geometry.gapLimit(model.items,target);
  for (let pointer = -100; pointer <= model.height+h+100; pointer += 2) {
    const center = geometry.boundedCenter(pointer,target.y,h,limit);
    assert.ok(Math.abs(center-(target.y+h/2)) <= limit, 'gap distance');
    for (const item of model.items) {
      const top = item.y+(item.y>=target.y?h:0);
      const overlap = Math.max(0,Math.min(center+h/2,top+item.h)-Math.max(center-h/2,top));
      assert.ok(overlap<=h/2, 'block overlaps an item by more than half');
    }
    cases++;
  }
  const middle = target.y+h/2;
  assert.equal(geometry.boundedCenter(middle+3,target.y,h,limit),middle+3,'pointer follows within gap');
}
assert.ok(Math.abs((-100)-(model.bounds[0].y+14)) > geometry.gapLimit(model.items,model.bounds[0]),'unbounded pointer is a negative control');
console.log(`drag position geometry: ${cases} samples passed`);
