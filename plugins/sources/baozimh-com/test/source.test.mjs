/** Deterministic fixtures cover the full manga chain without an origin or protocol gate. */
import assert from 'node:assert/strict'; import { readFile } from 'node:fs/promises'; import test from 'node:test'; import * as plugin from '../dist/index.mjs'; import { ProjectionCache } from '../dist/projection-cache.js'; import { BaozimhSource } from '../dist/source.js';
test('fixtures cover categories search detail redirected catalog ordered pages and Referer proxy', async () => {
  const fixture = (name) => readFile(new URL(`./fixtures/${name}`, import.meta.url), 'utf8'); const [list, detail, content] = await Promise.all(['list.html', 'detail.html', 'content.html'].map(fixture));
  const calls = []; const resources = [];
  const redirectedResponse = (body, url) => { const response = new Response(body, { headers: { 'content-type': 'text/html' } }); Object.defineProperty(response, 'url', { value: new URL(`${url.pathname}${url.search}`, 'http://mirror.example').toString() }); return response; };
  await plugin.activate({ dataDir: 'fixture-data', cacheDir: 'fixture-cache', app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.baozimh-com', version: '1.0.4' }, log: { debug() {}, info() {}, warn() {}, error() {} }, resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/resource/${resources.length}`; } }, http: { async fetch(input, init = {}) { const url = new URL(input); calls.push({ url, init }); if (url.hostname === 'images.example') return new Response(new Uint8Array([7, 8, 9]), { headers: { 'content-type': 'image/jpeg' } }); if (url.pathname.includes('/comic/chapter/')) return redirectedResponse(content, url); if (url.pathname.startsWith('/comic/')) return redirectedResponse(detail, url); return redirectedResponse(list, url); } } });
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 }); assert.equal(root.document.components[0].children[0].layout, 'coverGrid'); assert.equal(root.document.components[1].children[0].categories.length, 8);
  const discovery = await plugin.discover({ target: 'category:china', cursor: null, collectionId: null, pageSize: 20 }); assert.equal(discovery.document.components[0].children[0].items[0].content.title, 'Fixture Comic');
  await plugin.discover({ target: 'category:china', cursor: null, collectionId: null, pageSize: 20 }); assert.equal(calls.filter(({ url }) => url.pathname === '/classify').length, 1);
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 }); await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 }); assert.equal(calls.filter(({ url }) => url.pathname === '/search').length, 1); const [detailResult, chapters] = await Promise.all([plugin.getDetail({ id: search.items[0].id }), plugin.getChapters({ id: search.items[0].id })]); assert.equal(detailResult.status, 'ongoing'); assert.equal(detailResult.url, 'http://mirror.example/comic/fixture-comic');
  assert.deepEqual(chapters.items.map((chapter) => chapter.title), ['Fixture One', 'Fixture Two']); assert.equal(calls.filter(({ url }) => url.pathname === '/comic/fixture-comic').length, 1);
  const chapter = await plugin.getContent({ id: detailResult.id, chapterId: chapters.items[0].id }); assert.equal(chapter.text, null); assert.deepEqual(chapter.pages.map((page) => [page.index, page.width, page.height]), [[0, 800, 1200], [1, 640, 960]]); assert.ok(chapter.pages.every((page) => page.url.startsWith('http://127.0.0.1/resource/')));
  const resourceRequest = resources.find((request) => request.url.includes('/scomic/fixture/1.jpg')); assert.ok(resourceRequest); assert.equal(resourceRequest.kind, 'image'); assert.equal(resourceRequest.url, 'http://images.example/scomic/fixture/1.jpg'); assert.equal(resourceRequest.headers.Referer, 'http://mirror.example/comic/chapter/fixture-comic_real/0_0.html'); assert.match(resourceRequest.headers.Accept, /^image\//u);
  assert.ok(calls.some(({ url }) => url.hostname === 'www.baozimh.com')); assert.ok(calls.some(({ url }) => url.hostname === 'mirror.example'));
  assert.equal(calls.some(({ url }) => url.hostname === 'images.example'), false);
});
test('cross-book chapter ids are rejected before any resource descriptor is emitted', async () => { const book = (await plugin.search({ query: 'fixture', cursor: null, pageSize: 5 })).items[0]; const chapters = await plugin.getChapters({ id: book.id }); await assert.rejects(plugin.getContent({ id: 'comic:L2NvbWljL290aGVy', chapterId: chapters.items[0].id }), /Chapter ID is invalid/u); });

test('classify combines all four dimensions without dropping the current Korean region', async () => {
 const urls=[];const list=await readFile(new URL('./fixtures/list.html',import.meta.url),'utf8');
 await plugin.activate({log:{info(){},warn(){}},resource:{proxy:r=>r.url},http:{fetch:async input=>{urls.push(new URL(input));return new Response(list);}}});
 const root=await plugin.discover({target:'category:korea',cursor:null,collectionId:null,pageSize:2});
 const group=id=>root.document.components.find(x=>x.id==='filter-'+id).children[0].categories;
 assert.equal(group('type').length,26);assert.equal(group('region').length,5);assert.equal(group('state').length,3);assert.equal(group('filter').length,9);
 const finished=group('state').find(x=>x.id==='pub');
 const child=await plugin.discover({target:finished.target,cursor:null,collectionId:null,pageSize:2});
 const genre=child.document.components.find(x=>x.id==='filter-type').children[0].categories.find(x=>x.id==='hanman');
 await plugin.discover({target:genre.target,cursor:null,collectionId:null,pageSize:2});
 assert.equal(urls.at(-1).searchParams.get('region'),'kr');assert.equal(urls.at(-1).searchParams.get('state'),'pub');assert.equal(urls.at(-1).searchParams.get('type'),'hanman');
 await assert.rejects(plugin.discover({target:'filter:bad',cursor:null,collectionId:null,pageSize:2}));
});

test('AMP continuation drains each page, follows next URLs and excludes already rendered amp-list cards',async()=>{
 const base='/api/bzmhq/amp_comic_list?type=all&region=kr&state=all&filter=*&limit=36&language=tw&page=';
 const list=await readFile(new URL('./fixtures/list.html',import.meta.url),'utf8');const calls=[];
 await plugin.activate({log:{info(){},warn(){}},resource:{proxy:r=>r.url},http:{fetch:async input=>{
   const url=new URL(input);calls.push(url);if(url.pathname==='/classify')return new Response(list+`<amp-list src="${base}2" load-more-bookmark="next">${list.replaceAll('fixture-comic','already-rendered')}</amp-list>`);
   const p=Number(url.searchParams.get('page'));return Response.json({items:Array.from({length:3},(_,i)=>({comic_id:'page-'+p+'-'+i,name:'Comic '+i,author:'Author',topic_img:'test.jpg',type_names:['題材']})),next:p===2?base+'3':null});
 }}});
 const first=await plugin.discover({target:'category:korea',cursor:null,collectionId:null,pageSize:2});let listResult=first.document.components[0].children[0];assert.equal(listResult.items.length,1);
 const ids=listResult.items.map(x=>x.content.id),id=listResult.id;
 for(let guard=0;listResult.continuation&&guard<8;guard++){listResult=await plugin.discover({...listResult.continuation,collectionId:id,pageSize:2});ids.push(...listResult.items.map(x=>x.content.id));}
 assert.equal(ids.length,7);assert.equal(new Set(ids).size,7);assert.equal(listResult.continuation,null);
 assert.deepEqual(calls.filter(x=>x.pathname.includes('/api/')).map(x=>x.searchParams.get('page')),['2','3']);
});

test('gatekeeper responses fall back to the public WebView page', async () => {
  const list = await readFile(new URL('./fixtures/list.html', import.meta.url), 'utf8');
  const calls = []; const navigations = []; let currentUrl = 'https://www.baozimh.com/verified';
  const source = new BaozimhSource({
    http: { async fetch(input) { calls.push(new URL(input).toString()); return new Response(JSON.stringify({ challenge_url: '/__gatekeeper_challenge/start?token=fixture', error: 'challenge_required' }), { status: 403 }); } },
    webview: { async open(options) { assert.deepEqual(options, { visible: false, timeoutMs: 30_000 }); return {
      async navigate(url) { navigations.push(url); currentUrl = url.includes('/__gatekeeper_challenge/') ? 'https://www.baozimh.com/verified' : url; }, async getHtml() { return list; }, async getUrl() { return currentUrl; },
    }; } },
    errors: { raise(error) { throw new Error(`${error.code}:${error.message}`); } },
    resource: { proxy() { return 'http://127.0.0.1/resource'; } },
  });
  const results = await source.search('fixture');
  assert.equal(results[0].title, 'Fixture Comic'); assert.equal(calls.length, 1); assert.match(navigations[0], /^https:\/\/www\.baozimh\.com\/__gatekeeper_challenge\/start\?token=fixture/u); assert.match(navigations[1], /^https:\/\/www\.baozimh\.com\/search\?q=fixture/u);
});

test('projection cache is single-flight, stale-readable, failure-cleaning, concurrent across keys, and LRU bounded', async () => {
  let now = 0; let loads = 0;
  const cache = new ProjectionCache({ capacity: 2, freshTtlMs: 10, staleTtlMs: 30 }, () => now);
  assert.equal(await cache.get('a', async () => { loads += 1; return 'a1'; }), 'a1');
  assert.equal(await cache.get('a', async () => { loads += 1; return 'a2'; }), 'a1'); assert.equal(loads, 1);
  const gate = Promise.withResolvers(); let sameKeyLoads = 0; const singleFlight = new ProjectionCache({ capacity: 2, freshTtlMs: 10, staleTtlMs: 30 });
  const first = singleFlight.get('same', async () => { sameKeyLoads += 1; return gate.promise; }); const second = singleFlight.get('same', async () => { sameKeyLoads += 1; return 'wrong'; });
  await Promise.resolve(); assert.equal(sameKeyLoads, 1); gate.resolve('shared'); assert.deepEqual(await Promise.all([first, second]), ['shared', 'shared']);
  now = 11; const refresh = Promise.withResolvers(); let refreshLoads = 0;
  assert.equal(await cache.get('a', async () => { refreshLoads += 1; return refresh.promise; }), 'a1'); assert.equal(await cache.get('a', async () => { refreshLoads += 1; return 'wrong'; }), 'a1');
  await Promise.resolve(); assert.equal(refreshLoads, 1); refresh.resolve('a2'); await new Promise(setImmediate); assert.equal(await cache.get('a', async () => 'wrong'), 'a2');
  now = 22; let failedRefreshes = 0; assert.equal(await cache.get('a', async () => { failedRefreshes += 1; throw new Error('refresh failed'); }), 'a2');
  await new Promise(setImmediate); assert.equal(failedRefreshes, 1); assert.equal(await cache.get('a', async () => { failedRefreshes += 1; return 'a3'; }), 'a2');
  await new Promise(setImmediate); assert.equal(failedRefreshes, 2); assert.equal(await cache.get('a', async () => 'wrong'), 'a3');
  now = 100; let hardMissLoads = 0; await assert.rejects(cache.get('a', async () => { hardMissLoads += 1; throw new Error('hard miss'); }), /hard miss/u);
  assert.equal(await cache.get('a', async () => { hardMissLoads += 1; return 'a4'; }), 'a4'); assert.equal(hardMissLoads, 2);
  let active = 0; let peak = 0; const differentKeys = new ProjectionCache({ capacity: 2, freshTtlMs: 10, staleTtlMs: 30 });
  const loadKey = async (value) => { active += 1; peak = Math.max(peak, active); await new Promise(setImmediate); active -= 1; return value; };
  assert.deepEqual(await Promise.all([differentKeys.get('x', () => loadKey('x')), differentKeys.get('y', () => loadKey('y'))]), ['x', 'y']); assert.equal(peak, 2);
  await differentKeys.get('x', () => loadKey('wrong')); await differentKeys.get('z', () => loadKey('z'));
  let evictedLoads = 0; assert.equal(await differentKeys.get('y', async () => { evictedLoads += 1; return 'y2'; }), 'y2'); assert.equal(evictedLoads, 1);
});
