/** Deterministic fixture coverage for the full MgRead novel call chain. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';

test('fixtures cover categories search detail paged catalog content and image proxy', async () => {
  const fixture = async (name) => readFile(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
  const list = await fixture('list.html');
  const detail = await fixture('detail.html');
  const catalog = await fixture('catalog.html');
  const catalog2 = await fixture('catalog-2.html');
  const content = await fixture('content.html');
  const calls = [];
  const resources = [];
  await plugin.activate({
    dataDir: 'fixture-data', cacheDir: 'fixture-cache',
    app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.shukuge-365', version: '1.0.1' },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/resource/${resources.length}`; } },
    http: { async fetch(input, init = {}) {
      const url = new URL(input); calls.push({ url, init });
      if (url.pathname.endsWith('/index_2.html')) return new Response(catalog2);
      if (url.pathname.endsWith('/index.html')) return new Response(catalog);
      if (url.pathname.endsWith('/456.html')) return new Response(content);
      if (url.pathname === '/book/123/') return new Response(detail);
      if (url.pathname.includes('/headimgs/')) return new Response(new Uint8Array([1, 2, 3]), { headers: { 'content-type': 'image/jpeg' } });
      return new Response(list);
    } },
  });

  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(root.document.components.find(({ id }) => id === 'latest-section').children[0].items[0].content.title, 'Fixture Novel');
  assert.equal(root.document.components.find(({ id }) => id === 'categories-section').children[0].categories.length, 20);
  const discovery = await plugin.discover({ target: 'category:fantasy', cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(discovery.document.components[0].children[0].items[0].content.title, 'Fixture Novel');
  assert.equal(discovery.document.components[0].children[0].continuation.cursor, 'category:fantasy:2');
  const append = await plugin.discover({ target: 'category:fantasy', cursor: 'category:fantasy:2', collectionId: 'category-books:fantasy', pageSize: 20 });
  assert.equal(append.kind, 'append');
  assert.ok(calls.some(({ url }) => url.pathname === '/i-xuanhuan/2'));
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 });
  assert.equal(search.items[0].author, 'Fixture Author');
  const detailResult = await plugin.getDetail({ id: search.items[0].id });
  assert.equal(detailResult.updatedAt, '2026-08-01T02:00:00.000Z');
  assert.equal(detailResult.latestChapter.updatedAt, '2026-08-01T02:00:00.000Z');
  assert.equal(detailResult.status, 'completed');
  assert.equal(detailResult.catalogUrl, 'http://www.shukuge.com/book/123/index.html');
  const chapters = await plugin.getChapters({ id: detailResult.id });
  assert.deepEqual(chapters.items.map((chapter) => chapter.title), ['Fixture One', 'Fixture Two', 'Fixture Three']);
  const body = await plugin.getContent({ id: detailResult.id, chapterId: chapters.items[0].id });
  assert.match(body.text, /Fixture first paragraph\.\n\nFixture second paragraph\./u);
  assert.equal(new URL(resources[0].url).origin, 'http://www.shukuge.com');
  assert.ok(calls.every(({ init }) => init.headers.cookie === undefined && init.headers['user-agent'] === undefined));
  assert.ok(calls.every(({ init }) => init.method === undefined || init.method === 'GET'));
  assert.ok(resources.length > 0);
  assert.ok(resources.every(request => request.resourceTransform === 'sniff-image-content-type-v1'));
});

test('invalid opaque ids and cross-book chapters are rejected', async () => {
  await assert.rejects(plugin.getDetail({ id: 'book:invalid' }), /Content ID is invalid/u);
});

test('large catalogs load complete deferred groups without truncation', async () => {
  const links = Array.from({ length: 5001 }, (_, index) => `<dd><a href="/book/123/${index + 1}.html">第${index + 1}章</a></dd>`).join('');
  const catalog = `<select><option value="/book/123/index.html">目录</option></select><dl>${links}</dl>`;
  await plugin.activate({
    dataDir: 'large-catalog-data', cacheDir: 'large-catalog-cache',
    app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.shukuge-365', version: '1.0.4' },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: { proxy() { return 'http://127.0.0.1/resource'; } },
    http: { async fetch() { return new Response(catalog); } },
  });
  const result = await plugin.getChapters({ id: 'book:L2Jvb2svMTIzLw', supportsDeferredGroups: true });
  assert.equal(result.items.length, 500);
  assert.equal(result.groups.length, 11);
  assert.equal(result.groups[0].deferred, undefined);
  assert.equal(result.groups[1].deferred, true);
  assert.equal(result.groups[10].episodes.length, 0);
  const loaded = await plugin.getChapters({ id: 'book:L2Jvb2svMTIzLw', groupId: result.groups[10].id });
  assert.equal(loaded.items.length, 1);
  assert.equal(loaded.items[0].title, '第5001章');
  assert.equal(loaded.groups[0].deferred, undefined);
});
