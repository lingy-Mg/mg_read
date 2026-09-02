/** Deterministic fixtures cover the public HTTP-only novel chain and request budgets. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';
import { ProjectionCache } from '../dist/projection-cache.js';
import { TianyueSource } from '../dist/source.js';

test('fixtures cover POST search, cached GET projections, paged content, and cover Referer', async () => {
  const fixture = (name) => readFile(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
  const [list, searchPage, detail, catalog, content, content2] = await Promise.all(
    ['list.html', 'search.html', 'detail.html', 'catalog.html', 'content.html', 'content-2.html'].map(fixture),
  );
  const calls = []; const resources = [];
  await plugin.activate({
    dataDir: 'fixture-data', cacheDir: 'fixture-cache',
    app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.xtyxsw-org', version: '1.0.1' },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/resource/${resources.length}`; } },
    http: { async fetch(input, init = {}) {
      const url = new URL(input); calls.push({ url, init });
      if (url.pathname === '/search.html') return new Response(searchPage);
      if (url.pathname === '/book/123.html') return new Response(detail);
      if (url.pathname === '/read/123/') return new Response(catalog);
      if (url.pathname.endsWith('/789_2.html')) return new Response(content2);
      if (url.pathname.endsWith('/789.html')) return new Response(content);
      if (url.hostname === 'img.xtyxsw.org') return new Response(new Uint8Array([1, 2, 3]), { headers: { 'content-type': 'image/jpeg' } });
      return new Response(list);
    } },
  });
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 30 });
  assert.equal(root.document.components.find(({ id }) => id === 'latest-section').children[0].items[0].content.title, 'Fixture Novel');
  assert.equal(root.document.components.find(({ id }) => id === 'categories-section').children[0].categories.length, 22);
  const discovery = await plugin.discover({ target: 'category:fantasy', cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(discovery.document.components[0].children[0].items[0].content.title, 'Fixture Novel');
  await plugin.discover({ target: 'category:fantasy', cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(calls.filter(({ url }) => url.pathname === '/sort/1_1/').length, 1);
  const append = await plugin.discover({ target: 'category:fantasy', cursor: 'category:fantasy:2', collectionId: 'category-books:fantasy', pageSize: 20 });
  assert.equal(append.kind, 'append'); assert.ok(calls.some(({ url }) => url.pathname === '/sort/1/2.html'));
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 });
  assert.equal(search.items[0].author, 'Fixture Author');
  const [detailResult, chapters] = await Promise.all([
    plugin.getDetail({ id: search.items[0].id }),
    plugin.getChapters({ id: search.items[0].id }),
  ]);
  assert.equal(detailResult.status, 'completed');
  assert.deepEqual(chapters.items.map((chapter) => chapter.title), ['Fixture One', 'Fixture Two']);
  await Promise.all([plugin.getDetail({ id: detailResult.id }), plugin.getChapters({ id: detailResult.id })]);
  assert.equal(calls.filter(({ url }) => url.pathname === '/book/123.html').length, 1);
  assert.equal(calls.filter(({ url }) => url.pathname === '/read/123/').length, 1);
  const body = await plugin.getContent({ id: detailResult.id, chapterId: chapters.items[0].id });
  assert.equal(body.text, 'Fixture first paragraph.\n\nFixture second paragraph.');
  assert.ok(calls.some(({ url }) => url.pathname.endsWith('/789_2.html')));
  const categoryResource = resources.find(({ headers }) => headers?.Referer === 'https://www.xtyxsw.org/sort/1_1/');
  assert.equal(new URL(categoryResource.url).hostname, 'img.xtyxsw.org');
  assert.equal(calls.some(({ url }) => url.hostname === 'img.xtyxsw.org'), false);
});

test('empty direct search is capped at four category requests with concurrency two', async () => {
  const list = await readFile(new URL('./fixtures/list.html', import.meta.url), 'utf8');
  const calls = []; let active = 0; let peak = 0;
  const source = new TianyueSource(fixtureContext(async (input) => {
    const url = new URL(input); calls.push(url);
    if (url.pathname === '/search.html') return new Response('<p>找不到您要搜索的内容</p>');
    active += 1; peak = Math.max(peak, active); await new Promise(setImmediate); active -= 1;
    return new Response(list);
  }));
  const result = await source.search('absent');
  assert.deepEqual(result, []);
  assert.equal(calls.filter((url) => url.pathname === '/search.html').length, 1);
  assert.equal(calls.filter((url) => url.pathname !== '/search.html').length, 4);
  assert.equal(peak, 2);
});

test('fallback search includes the new-book list used by root discovery', async () => {
  const calls = [];
  const source = new TianyueSource(fixtureContext(async (input) => {
    const url = new URL(input); calls.push(url);
    if (url.pathname === '/search.html') return new Response('<p>找不到您要搜索的内容</p>');
    if (url.pathname === '/postdate/') {
      return new Response('<ul class="list"><li><p class="bookname"><a href="/read/398958/">Fresh Needle</a></p><p class="data"><a class="layui-btn">Author</a></p></li></ul>');
    }
    return new Response('<ul class="list"></ul>');
  }));
  const result = await source.search('Fresh Needle');
  assert.equal(result.length, 1);
  assert.equal(result[0].id, 'book:398958');
  assert.ok(calls.some((url) => url.pathname === '/postdate/'));
});

test('fallback search stops launching work and aborts its sibling after reaching 20 matches', async () => {
  const cards = Array.from({ length: 20 }, (_, index) => `<li><p class="bookname"><a href="/read/${100 + index}/">Needle ${index}</a></p><p class="data"><a class="layui-btn">Author</a></p></li>`).join('');
  let categoryCalls = 0; let aborted = 0;
  const source = new TianyueSource(fixtureContext(async (input, init = {}) => {
    const url = new URL(input);
    if (url.pathname === '/search.html') return new Response('<p>找不到您要搜索的内容</p>');
    categoryCalls += 1;
    if (categoryCalls === 1) return new Response(`<ul class="list">${cards}</ul>`);
    return new Promise((_, reject) => init.signal.addEventListener('abort', () => {
      aborted += 1; reject(new DOMException('aborted', 'AbortError'));
    }, { once: true }));
  }));
  const result = await source.search('needle');
  assert.equal(result.length, 20);
  assert.equal(categoryCalls, 2);
  assert.equal(aborted, 1);
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

test('invalid ids are rejected', async () => {
  await assert.rejects(plugin.getDetail({ id: 'book:invalid' }), /Content ID is invalid/u);
});

function fixtureContext(fetch) {
  return {
    dataDir: 'fixture-data', cacheDir: 'fixture-cache',
    app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.xtyxsw-org', version: '1.0.1' },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: { proxy() { return 'http://127.0.0.1/resource'; } },
    http: { fetch },
  };
}
