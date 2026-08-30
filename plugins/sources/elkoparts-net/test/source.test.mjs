/** Deterministic parser and full content-flow fixtures; no live response data is persisted. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';

const fixture = async (name) => readFile(new URL(`fixtures/${name}`, import.meta.url), 'utf8');

test('projects discovery, search, detail, catalog, content, and cover resources', async () => {
  const [home, category, search, detail, catalog2, content] = await Promise.all([
    fixture('home.html'), fixture('category.html'), fixture('search.html'), fixture('detail.html'),
    fixture('catalog-page-2.html'), fixture('content.html'),
  ]);
  const proxyRequests = [];
  const logEvents = [];
  await plugin.activate({
    dataDir: 'data',
    cacheDir: 'cache',
    http: {
      async fetch(input) {
        const url = new URL(input);
        if (url.pathname === '/') return new Response(home);
        if (url.pathname === '/ksl/1/1.html') return new Response(category);
        if (url.pathname === '/search.php') return new Response(search);
        if (url.pathname === '/kanshu/10/1001/') return new Response(detail);
        if (url.pathname === '/kanshu/10/1001/index_2.html') return new Response(catalog2);
        if (url.pathname === '/kanshu/10/1001/2000.html') return new Response(content);
        if (url.pathname === '/files/article/image/10/1001/1001s.jpg') {
          return new Response(Uint8Array.from([1, 2, 3]), { headers: { 'content-type': 'image/jpeg' } });
        }
        return new Response('missing', { status: 404 });
      },
    },
    resource: {
      proxy(request) {
        proxyRequests.push(request);
        return `http://127.0.0.1:1234/v1/source-resource/${proxyRequests.length}`;
      },
    },
    log: {
      debug(event) { logEvents.push(event); },
      info(event) { logEvents.push(event); },
      warn(event) { logEvents.push(event); },
      error(event) { logEvents.push(event); },
    },
    app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.elkoparts-net', version: '0.1.0' },
  });

  const initial = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 10 });
  assert.equal(initial.kind, 'document');
  assert.equal(initial.document.components[0].children[0].items[0].content.id, 'novel:10:1001');
  assert.equal(initial.document.components[1].children[0].categories.length, 7);

  const categoryResult = await plugin.discover({ target: 'category:1', cursor: null, collectionId: null, pageSize: 10 });
  assert.equal(categoryResult.kind, 'document');
  const categoryCollection = categoryResult.document.components[0].children[0];
  assert.equal(categoryCollection.layout, 'coverGrid');
  assert.equal(categoryCollection.items[0].content.description, '脱敏的测试简介。');
  assert.deepEqual(categoryCollection.continuation, { target: 'category:1', cursor: '2' });

  const searchResult = await plugin.search({ query: '测试', cursor: null, pageSize: 10 });
  assert.equal(searchResult.items.length, 1);
  assert.equal(searchResult.items[0].latestChapter.id, 'chapter:10:1001:2001');
  assert.deepEqual(await plugin.searchSuggestions({ cursor: null, pageSize: 10 }), { items: [], nextCursor: null });

  const detailResult = await plugin.getDetail({ id: 'novel:10:1001' });
  assert.equal(detailResult.status, 'completed');
  assert.equal(detailResult.chapterCount, 3);
  assert.equal(detailResult.latestChapter.id, 'chapter:10:1001:2002');
  assert.match(detailResult.coverUrl, /^http:\/\/127\.0\.0\.1:1234\/v1\/source-resource\//u);

  const chapters = await plugin.getChapters({ id: 'novel:10:1001' });
  assert.deepEqual(chapters.items.map(({ id, order }) => ({ id, order })), [
    { id: 'chapter:10:1001:2000', order: 0 },
    { id: 'chapter:10:1001:2001', order: 1 },
    { id: 'chapter:10:1001:2002', order: 2 },
  ]);
  const chapter = await plugin.getContent({ id: 'novel:10:1001', chapterId: chapters.items[0].id });
  assert.equal(chapter.title, '第一章');
  assert.equal(chapter.text, '第一段。\n\n第二段。\n\n第三段。');
  assert.deepEqual(chapter.pages, []);

  assert.deepEqual(proxyRequests[0].headers, { Accept: 'image/*' });
  assert.equal(new URL(proxyRequests[0].url).origin, 'http://www.elkoparts.net');
  assert.ok(logEvents.every((event) => /^[a-z_]+$/u.test(event)));
});
