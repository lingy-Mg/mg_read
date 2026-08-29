/** Opt-in online structural smoke. It writes neither HTML nor content to disk. */
import assert from 'node:assert/strict';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';

test('live source completes discovery, search, detail, catalog, and content', { timeout: 120000 }, async () => {
  const proxyRequests = [];
  await plugin.activate({
    dataDir: 'live-data-unused',
    cacheDir: 'live-cache-unused',
    http: { fetch },
    resource: {
      proxy(request) {
        proxyRequests.push(request);
        return `http://127.0.0.1:1234/v1/source-resource/live-${proxyRequests.length}`;
      },
    },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    app: { runtimeVersion: 'live-test', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.elkoparts-net', version: '0.1.0' },
  });

  const initial = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(initial.kind, 'document');
  assert.ok(initial.document.components[0].children[0].items.length > 0);
  const category = await plugin.discover({ target: 'category:1', cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(category.kind, 'document');
  assert.ok(category.document.components[0].children[0].items.length > 0);

  const search = await plugin.search({ query: '斗破苍穹', cursor: null, pageSize: 5 });
  assert.ok(search.items.length > 0);
  const book = search.items.find((item) => item.id === 'novel:92:92836') ?? search.items[0];
  const detail = await plugin.getDetail({ id: book.id });
  assert.equal(detail.id, book.id);
  assert.ok(detail.title.length > 0);
  assert.ok(proxyRequests.length > 0);
  const chapters = await plugin.getChapters({ id: book.id });
  assert.ok(chapters.items.length > 0);
  assert.deepEqual(chapters.items.map((item) => item.order), chapters.items.map((_, index) => index));
  const content = await plugin.getContent({ id: book.id, chapterId: chapters.items[0].id });
  assert.equal(content.chapterId, chapters.items[0].id);
  assert.ok((content.text ?? '').length > 100);
});
