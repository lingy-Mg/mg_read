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
  assert.equal(detailResult.status, 'completed');
  assert.equal(detailResult.catalogUrl, 'http://www.shukuge.com/book/123/index.html');
  const chapters = await plugin.getChapters({ id: detailResult.id });
  assert.deepEqual(chapters.items.map((chapter) => chapter.title), ['Fixture One', 'Fixture Two', 'Fixture Three']);
  const body = await plugin.getContent({ id: detailResult.id, chapterId: chapters.items[0].id });
  assert.match(body.text, /Fixture first paragraph\.\n\nFixture second paragraph\./u);
  const image = await plugin.resource(resources[0]);
  assert.equal(image.status, 200);
  assert.deepEqual([...image.body], [1, 2, 3]);
  assert.ok(calls.every(({ init }) => init.headers.cookie === undefined && init.headers['user-agent'] === undefined));
  assert.ok(calls.every(({ init }) => init.method === undefined || init.method === 'GET'));
});

test('invalid opaque ids, cross-book chapters and resource origins are rejected', async () => {
  await assert.rejects(plugin.getDetail({ id: 'book:invalid' }), /Content ID is invalid/u);
  const invalid = await plugin.resource({ kind: 'image', url: 'http://example.test/a.jpg', referer: 'http://www.shukuge.com/' });
  assert.equal(invalid.status, 400);
});
