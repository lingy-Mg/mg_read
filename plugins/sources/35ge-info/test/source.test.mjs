/** Deterministic fixture coverage for the full MgRead novel call chain. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('fixtures cover categories search detail catalog content cover enrichment and resource proxy', async () => {
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
  assert.equal(root.document.components[0].children[0].categories.length, 8);
  const discovery = await plugin.discover({ target: 'category:fantasy', cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(discovery.document.components[0].children[0].items[0].content.coverUrl, 'http://127.0.0.1/resource/1');
  const append = await plugin.discover({ target: 'category:fantasy', cursor: 'category:fantasy:2', collectionId: 'category-books:fantasy', pageSize: 20 });
  assert.equal(append.kind, 'append'); assert.ok(calls.some(({ url }) => url.pathname.endsWith('-2.html')));
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 });
  assert.equal(search.items[0].status, 'completed');
  const detail = await plugin.getDetail({ id: search.items[0].id });
  assert.equal(detail.author, 'Fixture Author'); assert.equal(detail.latestChapter.id !== null, true);
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.deepEqual(chapters.items.map((chapter) => chapter.title), ['Fixture One', 'Fixture Two']);
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.equal(content.text, 'Fixture first paragraph.\n\nFixture second paragraph.');
  const image = await plugin.resource(resources[0]); assert.equal(image.status, 200); assert.deepEqual([...image.body], [4, 5, 6]);
  assert.ok(calls.every(({ init }) => init.headers.cookie === undefined && init.headers['user-agent'] === undefined));
});

test('invalid ids and foreign image origins are rejected', async () => {
  await assert.rejects(plugin.getDetail({ id: 'book:invalid' }), /Content ID is invalid/u);
  const result = await plugin.resource({ kind: 'image', url: 'http://example.test/a.jpg', referer: 'http://www.35ge.info/' });
  assert.equal(result.status, 400);
});
