/** Deterministic fixture coverage for the full MgRead novel call chain. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { ProjectionCache } from '../dist/projection-cache.js';

test('fixtures cover categories search detail catalog content bounded list requests and resource proxy', async () => {
  const fixture = (name) => readFile(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
  const [list, searchPage, detailPage, contentPage] = await Promise.all(['list.html', 'search.html', 'detail.html', 'content.html'].map(fixture));
  const calls = []; const resources = [];
  await plugin.activate({
    dataDir: 'fixture-data', cacheDir: 'fixture-cache',
    app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.35ge-info', version: '1.0.0' },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/resource/${resources.length}`; } },
    http: { async fetch(input, init = {}) { const url = new URL(input); calls.push({ url, init });
      if (url.pathname.includes('/modules/article/search.php')) return new Response(searchPage);
      if (url.pathname.endsWith('/789.html')) return new Response(contentPage);
      if (url.pathname.includes('/images/')) return new Response(new Uint8Array([4, 5, 6]), { headers: { 'content-type': 'image/jpeg' } });
      if (/\/xs\/123\/456\/$/u.test(url.pathname)) return new Response(detailPage);
      return new Response(list);
    } },
  });
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 });
  const featured = root.document.components.find(({ id }) => id === 'featured-section').children[0];
  assert.equal(featured.layout, 'shelf');
  assert.equal(featured.items[0].content.coverUrl, 'http://127.0.0.1/resource/1');
  assert.equal(root.document.components.find(({ id }) => id === 'categories-section').children[0].categories.length, 8);
  const discovery = await plugin.discover({ target: 'category:fantasy', cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(discovery.document.components[0].children[0].items[0].content.coverUrl, 'http://127.0.0.1/resource/1');
  await plugin.discover({ target: 'category:fantasy', cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(calls.filter(({ url }) => url.pathname.includes('1-default')).length, 1);
  const append = await plugin.discover({ target: 'category:fantasy', cursor: 'category:fantasy:2', collectionId: 'category-books:fantasy', pageSize: 20 });
  assert.equal(append.kind, 'append'); assert.equal(append.items[0].content.coverUrl, 'http://127.0.0.1/resource/2');
  assert.ok(calls.some(({ url }) => url.pathname.endsWith('-2.html')));
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 });
  assert.equal(search.items[0].status, 'completed');
  assert.equal(search.items[0].coverUrl, 'http://127.0.0.1/resource/3');
  await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 });
  assert.equal(calls.filter(({ url }) => url.pathname.includes('/modules/article/search.php')).length, 1);
  const [detail, chapters] = await Promise.all([
    plugin.getDetail({ id: search.items[0].id }),
    plugin.getChapters({ id: search.items[0].id }),
  ]);
  assert.equal(detail.author, 'Fixture Author'); assert.equal(detail.latestChapter.id !== null, true);
  assert.equal(detail.updatedAt, '2026-08-01T02:00:00.000Z');
  assert.equal(detail.latestChapter.updatedAt, '2026-08-01T02:00:00.000Z');
  assert.deepEqual(chapters.items.map((chapter) => chapter.title), ['Fixture One', 'Fixture Two']);
  assert.equal(calls.filter(({ url }) => /\/xs\/123\/456\/$/u.test(url.pathname)).length, 1);
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.equal(content.text, 'Fixture first paragraph.\n\nFixture second paragraph.');
  assert.deepEqual(resources.map(({ url }) => new URL(url).pathname), [
    '/files/article/image/123/456/456s.jpg',
    '/files/article/image/123/456/456s.jpg',
    '/files/article/image/123/456/456s.jpg',
    '/images/fixture.jpg',
  ]);
  assert.ok(resources.every(({ url }) => new URL(url).origin === 'http://www.35ge.info'));
  assert.equal(calls.some(({ url }) => url.pathname.endsWith('.jpg')), false);
  assert.ok(calls.every(({ init }) => init.headers.cookie === undefined && init.headers['user-agent'] === undefined));
});

test('projection cache is single-flight, stale-readable, failure-cleaning, concurrent across keys, and LRU bounded', async () => {
  let now = 0; let loads = 0;
  const cache = new ProjectionCache({ capacity: 2, freshTtlMs: 10, staleTtlMs: 30 }, () => now);
  assert.equal(await cache.get('a', async () => { loads += 1; return 'a1'; }), 'a1');
  assert.equal(await cache.get('a', async () => { loads += 1; return 'a2'; }), 'a1');
  assert.equal(loads, 1);

  const gate = Promise.withResolvers(); let sameKeyLoads = 0;
  const singleFlight = new ProjectionCache({ capacity: 2, freshTtlMs: 10, staleTtlMs: 30 });
  const first = singleFlight.get('same', async () => { sameKeyLoads += 1; return gate.promise; });
  const second = singleFlight.get('same', async () => { sameKeyLoads += 1; return 'wrong'; });
  await Promise.resolve(); assert.equal(sameKeyLoads, 1); gate.resolve('shared');
  assert.deepEqual(await Promise.all([first, second]), ['shared', 'shared']);

  now = 11; const refresh = Promise.withResolvers(); let refreshLoads = 0;
  assert.equal(await cache.get('a', async () => { refreshLoads += 1; return refresh.promise; }), 'a1');
  assert.equal(await cache.get('a', async () => { refreshLoads += 1; return 'wrong'; }), 'a1');
  await Promise.resolve(); assert.equal(refreshLoads, 1); refresh.resolve('a2'); await new Promise(setImmediate);
  assert.equal(await cache.get('a', async () => 'wrong'), 'a2');

  now = 22; let failedRefreshes = 0;
  assert.equal(await cache.get('a', async () => { failedRefreshes += 1; throw new Error('refresh failed'); }), 'a2');
  await new Promise(setImmediate); assert.equal(failedRefreshes, 1);
  assert.equal(await cache.get('a', async () => { failedRefreshes += 1; return 'a3'; }), 'a2');
  await new Promise(setImmediate); assert.equal(failedRefreshes, 2);
  assert.equal(await cache.get('a', async () => 'wrong'), 'a3');

  now = 100; let hardMissLoads = 0;
  await assert.rejects(cache.get('a', async () => { hardMissLoads += 1; throw new Error('hard miss'); }), /hard miss/u);
  assert.equal(await cache.get('a', async () => { hardMissLoads += 1; return 'a4'; }), 'a4');
  assert.equal(hardMissLoads, 2);

  let active = 0; let peak = 0; const differentKeys = new ProjectionCache({ capacity: 2, freshTtlMs: 10, staleTtlMs: 30 });
  const loadKey = async (value) => { active += 1; peak = Math.max(peak, active); await new Promise(setImmediate); active -= 1; return value; };
  assert.deepEqual(await Promise.all([differentKeys.get('x', () => loadKey('x')), differentKeys.get('y', () => loadKey('y'))]), ['x', 'y']);
  assert.equal(peak, 2);
  await differentKeys.get('x', () => loadKey('wrong'));
  await differentKeys.get('z', () => loadKey('z'));
  let evictedLoads = 0; assert.equal(await differentKeys.get('y', async () => { evictedLoads += 1; return 'y2'; }), 'y2');
  assert.equal(evictedLoads, 1);
});

test('invalid ids are rejected', async () => {
  await assert.rejects(plugin.getDetail({ id: 'book:invalid' }), /Content ID is invalid/u);
});
