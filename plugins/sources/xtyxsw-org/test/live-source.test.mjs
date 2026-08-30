/** Live smoke uses only public PC HTTP pages; no browser fallback is available. */
import assert from 'node:assert/strict';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';

test('live bounded search fallback and one public content chain remain reachable', { timeout: 120_000 }, async () => {
  await plugin.activate({
    dataDir: '.live-data', cacheDir: '.live-cache',
    app: { runtimeVersion: 'live', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.xtyxsw-org', version: '1.0.1' },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: { proxy() { return 'http://127.0.0.1/live-resource'; } },
    http: { fetch },
  });
  const discovery = await plugin.discover({ target: 'category:fantasy', cursor: null, collectionId: null, pageSize: 5 });
  const seed = discovery.document.components[0].children[0].items[0]?.content;
  assert.ok(seed);
  const search = await plugin.search({ query: seed.title, cursor: null, pageSize: 5 });
  assert.ok(search.items.length > 0);
  const detail = await plugin.getDetail({ id: search.items[0].id });
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.ok(chapters.items.length > 0);
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.ok(content.text.length > 100);
});
