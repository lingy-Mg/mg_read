import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('Qingting GraphQL, detail and live audio are native and stable', async () => {
  const calls = [];
  const resources = [];
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: {
      proxy(value) {
        resources.push(value);
        return 'http://127.0.0.1/resource/opaque';
      },
    },
    http: {
      async fetch(input, init = {}) {
        const url = String(input);
        calls.push({ url, init });
        if (url.includes('/api/pc/radio/')) {
          return Response.json({ data: { id: 101, title: '测试电台', description: '详情' } });
        }
        const body = JSON.parse(init.body);
        if (body.query.includes('searchResultsPage')) {
          return Response.json({ data: { searchResultsPage: { searchData: [{ id: 101, title: '测试电台' }], numFound: 1 } } });
        }
        return Response.json({ data: { radioPage: { contents: [{ id: 101, title: '测试电台', imgUrl: '/cover.jpg' }] } } });
      },
    },
  });

  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 5 });
  assert.ok(root.document.components.flatMap(section => section.children).flatMap(child => child.categories ?? []).length > 40);
  const list = await plugin.discover({ target: 'category:217', cursor: null, collectionId: null, pageSize: 5 });
  const id = list.document.components[0].children[0].items[0].content.id;
  assert.equal(id, 'radio:MTAx');
  const found = await plugin.search({ query: '测试', cursor: null, pageSize: 5 });
  assert.equal(found.totalCount, 1);
  const detail = await plugin.getDetail({ id });
  assert.equal(detail.description, '详情');
  assert.equal(detail.coverUrl, 'http://127.0.0.1/resource/opaque');
  const chapters = await plugin.getChapters({ id });
  const content = await plugin.getContent({ id, chapterId: chapters.items[0].id });
  assert.equal(content.media.resourceType, 'audio');
  assert.equal(content.media.resourcePolicy, 'refreshable');
  assert.ok(Date.parse(content.media.expiresAt) > Date.now());
  const audio = resources.find((resource) => resource.kind === 'audio');
  const audioUrl = new URL(audio.url);
  assert.equal(`${audioUrl.origin}${audioUrl.pathname}`, 'https://lhttp-hw.qtfm.cn/live/101/64k.mp3');
  assert.equal(audioUrl.searchParams.get('app_id'), 'web');
  const timestamp = audioUrl.searchParams.get('ts');
  const canonical = `app_id=web&path=${encodeURIComponent(audioUrl.pathname)}&ts=${timestamp}`;
  assert.equal(audioUrl.searchParams.get('sign'), createHmac('md5', 'Lwrpu$K5oP').update(canonical).digest('hex'));
  assert.equal(new Date(Number.parseInt(timestamp, 16) * 1000).toISOString(), content.media.expiresAt);
  assert.ok(calls.some((call) => call.url === 'https://webbff.qtfm.cn/www' && call.init.method === 'POST'));
});

function discoveryCollections(result) {const found=[]; const visit=node=>{if(node.type==='contentCollection')found.push(node);for(const child of node.children??[])visit(child);};for(const node of result.document?.components??[])visit(node);return found;}
test('radio discovery separates navigation and retains an upstream page remainder',async()=>{
 await plugin.activate({log:{info(){}},resource:{proxy:v=>v.url},http:{fetch:async(_url,init)=>Response.json({data:{radioPage:{contents:init.body.includes('page:2')?[]:Array.from({length:7},(_,i)=>({id:i+1,title:'Radio '+i}))}}})}});
 const root=await plugin.discover({target:null,cursor:null,collectionId:null,pageSize:3});assert.equal(root.document.components.length,3);const first=discoveryCollections(root)[0];
 let page=first;const seen=page.items.map(x=>x.content.id);for(let i=0;page.continuation&&i<5;i++){page=await plugin.discover({...page.continuation,collectionId:first.id,pageSize:3});seen.push(...page.items.map(x=>x.content.id));}
 assert.equal(seen.length,7);assert.equal(new Set(seen).size,7);assert.equal(page.continuation,null);
 await assert.rejects(plugin.discover({target:'category:3',cursor:null,collectionId:'radio:99',pageSize:3}));
});