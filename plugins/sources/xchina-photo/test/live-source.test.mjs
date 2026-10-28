/** Live mixed-source structure checks; counts only, never print reading text or images. */
import assert from 'node:assert/strict';
import test, { after } from 'node:test';
import { createSourceTestHarness } from '../../../../packages/mg_read_source_testkit/index.js';
import * as plugin from '../dist/index.mjs';
const harness=await createSourceTestHarness({plugin,pluginId:'org.mgread.xchina-photo',version:'1.0.5',fetch:globalThis.fetch});
after(()=>harness.cleanup());
const resources=harness.resourceRequests;
async function items(target){const r=await plugin.discover({target,cursor:null,collectionId:null,pageSize:10});return r.document.components.flatMap(x=>x.children??[]).flatMap(x=>x.items??[]).map(x=>x.content);}
test('live photo discovery resolves preserved identity and actual page URLs',{timeout:60000},async()=>{
  const list=await items('channel:latest');assert.ok(list.length);const book=list[0];const d=await plugin.getDetail({id:book.id});assert.equal(d.contentKind,'manga');
  const c=await plugin.getChapters({id:book.id});const body=await plugin.getContent({id:book.id,chapterId:c.items[0].id});assert.ok(body.pages.length>0);
  console.log(JSON.stringify({surface:'photo',items:list.length,chapters:c.items.length,pages:body.pages.length}));
});
for(const shape of ['short','long']) test(`live ${shape} fiction keeps real chapter structure and readable text`,{timeout:120000},async(t)=>{
  const list=await items('channel:fiction');assert.ok(list.length);
  for(const book of list){const c=await plugin.getChapters({id:book.id});const actual=c.items.length===1&&c.items[0].title==='全文'?'short':'long';if(actual!==shape)continue;
    assert.ok(c.items.length);assert.equal(new Set(c.items.map(x=>x.id)).size,c.items.length);assert.deepEqual(c.items.map(x=>x.order),c.items.map((_,i)=>i));
    const d=await plugin.getDetail({id:book.id});assert.equal(d.contentKind,'novel');assert.equal(d.chapterCount,c.items.length);
    const samples=[...new Set([0,Math.floor(c.items.length/2),c.items.length-1])];const lengths=[];
    try{for(const i of samples){const b=await plugin.getContent({id:book.id,chapterId:c.items[i].id});assert.equal(b.contentKind,'novel');assert.ok(b.text.length>0);lengths.push(b.text.length);}}
    catch(e){if(/source_webview.*unsupported/u.test(e.code??'')||/source_webview.*unsupported/u.test(e.message??'')){t.skip('Long chapter requires the actual App WebView; static testkit cannot execute site scripts.');return;}throw e;}
    console.log(JSON.stringify({surface:'fiction',shape,chapters:c.items.length,samples:lengths.length,textLengths:lengths}));return;
  }
  assert.fail(`No ${shape} fiction in the observed live list`);
});
test('live video discovery resolves a public HLS descriptor without synthesizing a stream path',{timeout:60000},async()=>{
  const list=await items('channel:video');assert.ok(list.length);const book=list[0];const d=await plugin.getDetail({id:book.id});assert.equal(d.contentKind,'video');
  const c=await plugin.getChapters({id:book.id});const b=await plugin.getContent({id:book.id,chapterId:c.items[0].id});assert.equal(b.media.resourceType,'hls');
  const r=resources.map(x=>x.descriptor??x.request??x).find(x=>x.kind==='hls');assert.ok(r);const response=await fetch(r.url,{headers:r.headers,signal:AbortSignal.timeout(15000)});assert.ok(response.ok);assert.match(await response.text(),/^#EXTM3U/u);
  console.log(JSON.stringify({surface:'video',items:list.length,chapters:c.items.length,manifest:'passed',playback:'notTested'}));
});
