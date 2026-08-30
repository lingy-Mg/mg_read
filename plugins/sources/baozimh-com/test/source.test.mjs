/** Deterministic fixtures cover the full manga chain and image security boundary. */
import assert from 'node:assert/strict'; import { readFile } from 'node:fs/promises'; import test from 'node:test'; import * as plugin from '../dist/index.mjs'; import { ProjectionCache } from '../dist/projection-cache.js';
test('fixtures cover categories search detail redirected catalog ordered pages and Referer proxy', async () => {
  const fixture = (name) => readFile(new URL(`./fixtures/${name}`, import.meta.url), 'utf8'); const [list, detail, content] = await Promise.all(['list.html', 'detail.html', 'content.html'].map(fixture));
  const calls = []; const resources = [];
  await plugin.activate({ dataDir: 'fixture-data', cacheDir: 'fixture-cache', app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.baozimh-com', version: '1.0.0' }, log: { debug() {}, info() {}, warn() {}, error() {} }, resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/resource/${resources.length}`; } }, http: { async fetch(input, init = {}) { const url = new URL(input); calls.push({ url, init }); if (url.hostname.endsWith('.bzcdn.net') || url.hostname === 'static-tw.baozimh.com') return new Response(new Uint8Array([7, 8, 9]), { headers: { 'content-type': 'image/jpeg' } }); if (url.pathname.includes('/comic/chapter/')) return new Response(content, { headers: { 'content-type': 'text/html' } }); if (url.pathname.startsWith('/comic/')) return new Response(detail, { headers: { 'content-type': 'text/html' } }); return new Response(list, { headers: { 'content-type': 'text/html' } }); } } });
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 }); assert.equal(root.document.components[0].children[0].layout, 'coverGrid'); assert.equal(root.document.components[1].children[0].categories.length, 8);
  const discovery = await plugin.discover({ target: 'category:china', cursor: null, collectionId: null, pageSize: 20 }); assert.equal(discovery.document.components[0].children[0].items[0].content.title, 'Fixture Comic');
  await plugin.discover({ target: 'category:china', cursor: null, collectionId: null, pageSize: 20 }); assert.equal(calls.filter(({ url }) => url.pathname === '/classify').length, 1);
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 }); await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 }); assert.equal(calls.filter(({ url }) => url.pathname === '/search').length, 1); const [detailResult, chapters] = await Promise.all([plugin.getDetail({ id: search.items[0].id }), plugin.getChapters({ id: search.items[0].id })]); assert.equal(detailResult.status, 'ongoing');
  assert.deepEqual(chapters.items.map((chapter) => chapter.title), ['Fixture One', 'Fixture Two']); assert.equal(calls.filter(({ url }) => url.pathname === '/comic/fixture-comic').length, 1);
  const chapter = await plugin.getContent({ id: detailResult.id, chapterId: chapters.items[0].id }); assert.equal(chapter.text, null); assert.deepEqual(chapter.pages.map((page) => [page.index, page.width, page.height]), [[0, 800, 1200], [1, 640, 960]]); assert.ok(chapter.pages.every((page) => page.url.startsWith('http://127.0.0.1/resource/')));
  const resourceRequest = resources.find((request) => request.url.includes('s1.bzcdn.net')); const image = await plugin.resource(resourceRequest); assert.equal(image.status, 200); assert.deepEqual([...image.body], [7, 8, 9]);
  const imageCall = calls.find(({ url }) => url.hostname === 's1.bzcdn.net'); assert.equal(imageCall.init.headers.referer, 'https://www.baozimh.com/comic/chapter/fixture-comic_real/0_0.html'); assert.equal(imageCall.init.headers.cookie, undefined); assert.equal(imageCall.init.headers['user-agent'], undefined);
});
test('cross-book chapter ids and unapproved image hosts are rejected', async () => { const book = (await plugin.search({ query: 'fixture', cursor: null, pageSize: 5 })).items[0]; const chapters = await plugin.getChapters({ id: book.id }); await assert.rejects(plugin.getContent({ id: 'comic:L2NvbWljL290aGVy', chapterId: chapters.items[0].id }), /Chapter ID is invalid/u); const response = await plugin.resource({ kind: 'image', url: 'https://example.test/a.jpg', referer: 'https://www.baozimh.com/' }); assert.equal(response.status, 400); });

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
