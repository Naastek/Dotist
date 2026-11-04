import { createRequire } from 'node:module';
import { existsSync, mkdirSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
const root=dirname(fileURLToPath(import.meta.url));
mkdirSync(join(root,'shots'),{recursive:true});
const require=createRequire(import.meta.url);let playwright;
try{playwright=require('playwright')}catch{const cache=join(homedir(),'.npm/_npx');for(const dir of existsSync(cache)?readdirSync(cache):[]){try{playwright=require(join(cache,dir,'node_modules/playwright'));break}catch{}}}
if(!playwright)throw Error('需要本机已缓存 playwright，或通过 NODE_PATH 指向 playwright 安装目录');
const browser=await playwright.chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
const page=await browser.newPage({viewport:{width:1000,height:850},deviceScaleFactor:1});
const violations={gap:0,distance:0,overlap:0,drop:0};let samples=0;const failingSamples=[];
async function load(){await page.goto(pathToFileURL(join(root,'index.html')).href);await page.locator('#reduce').check();}
async function start(text){let row=page.locator('.row').filter({hasText:text}).first(),box=await row.boundingBox();await page.mouse.move(box.x+45,box.y+box.height/2);await page.mouse.down();return box}
async function sample(x,y){await page.mouse.move(x,y);const s=await page.evaluate(()=>window.__dragState);assert(s,'drag state missing');if(await page.locator('#reduce').isChecked()){const actual=await page.evaluate(()=>{const list=document.querySelector('#list').getBoundingClientRect(),gap=document.querySelector('.gap').getBoundingClientRect(),floating=document.querySelector('.floating').getBoundingClientRect();return {gapTop:gap.top-list.top,gapHeight:gap.height,center:(floating.top+floating.bottom)/2-list.top,height:floating.height}});assert.ok(Math.abs(actual.gapTop-s.target.y)<0.1&&Math.abs(actual.gapHeight-s.height)<0.1,'rendered gap matches target');assert.ok(Math.abs(actual.center-s.center)<0.1&&Math.abs(actual.height-s.height)<0.1,'rendered block matches geometry')}samples++;if(s.gapCount!==1)violations.gap++;if(s.distance>s.limit)violations.distance++;if(s.overlap.length)violations.overlap++;if((s.gapCount!==1||s.distance>s.limit||s.overlap.length)&&failingSamples.length<12){const rects=await page.evaluate(()=>{const rect=e=>{const r=e.getBoundingClientRect();return {top:r.top,bottom:r.bottom,height:r.height}};return {list:rect(document.querySelector('#list')),gap:rect(document.querySelector('.gap')),floating:rect(document.querySelector('.floating')),scrollY,items:[...document.querySelectorAll('.item')].map(e=>({type:e.dataset.type,text:e.textContent, ...rect(e)}))}});failingSamples.push({pointer:{x,y},state:s,rects})}return s}
try{
 await load();const original=await page.evaluate(()=>window.__model().groups);let box=await start('Plan launch');let list=await page.locator('#list').boundingBox();let state=await page.evaluate(()=>window.__dragState);assert.equal(state.height,60,'子树高度');
 for(let y=list.y;y<=list.y+list.height;y+=4)await sample(box.x+45,y);
 for(let y=list.y+list.height;y>=list.y;y-=4)await sample(box.x+45,y);
 await page.screenshot({path:join(root,'shots/subtree-scan.png')});await page.keyboard.press('Escape');await page.waitForTimeout(40);assert.deepEqual(await page.evaluate(()=>window.__model().groups),original,'Escape restores the original tree');
 await load();box=await start('Review copy');list=await page.locator('#list').boundingBox();state=await page.evaluate(()=>window.__dragState);assert.equal(state.height,28,'子行高度');
 for(let y=list.y;y<=list.y+list.height;y+=4)await sample(box.x+45,y);
 for(let i=0;i<8;i++){await sample(box.x+90,list.y+100);await sample(box.x+90,list.y+300)}
 await page.screenshot({path:join(root,'shots/cross-group.png')});await page.mouse.up();await page.waitForTimeout(40);if((await page.evaluate(()=>window.__lastDropDelta))>0.5)violations.drop++;
 await load();box=await start('Ship draft');list=await page.locator('#list').boundingBox();
 let nested=await sample(box.x+90,list.y+185);assert(nested.target.level > 0 && nested.target.level <= 2, 'root can be indented to a valid non-root level');assert.equal(nested.height,28,'floating height matches nested row');
 await page.mouse.up();await page.waitForTimeout(40);assert((await page.evaluate(()=>window.__lastDropDelta))<=0.5,'indented drop must retain its vertical position');
 await load();box=await start('Review copy');list=await page.locator('#list').boundingBox();
 let rootState=await sample(box.x-20,list.y+185);assert.equal(rootState.target.level,0,'child can be outdented');assert.equal(rootState.height,32,'floating height matches root row');
 await page.mouse.up();await page.waitForTimeout(40);assert((await page.evaluate(()=>window.__lastDropDelta))<=0.5,'outdented drop must retain its vertical position');
 await load();await page.locator('#reduce').uncheck();box=await start('Ship draft');list=await page.locator('#list').boundingBox();await sample(box.x+45,list.y+180);await page.waitForTimeout(180);await page.screenshot({path:join(root,'shots/animated-gap.png')});await page.mouse.up();await page.waitForTimeout(180);if((await page.evaluate(()=>window.__lastDropDelta))>0.5)violations.drop++;
 console.log(JSON.stringify({samples,violations,failingSamples,shots:['subtree-scan.png','cross-group.png','animated-gap.png']},null,2));
 assert.deepEqual(violations,{gap:0,distance:0,overlap:0,drop:0},'扫描发现契约违例，见统计');
}finally{await browser.close()}
