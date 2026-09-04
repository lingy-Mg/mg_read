/** Live smoke validates the bounded public Midu search-to-text chain. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live search, detail, catalog and chapter text remain reachable', { timeout: 120_000 }, async () => {
  await plugin.activate({
    dataDir: '.live-data', cacheDir: '.live-cache',
    app: { runtimeVersion: 'live', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.midu-novel', version: '1.0.0' },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: { proxy() { return 'http://127.0.0.1/live-resource'; } },
    http: { fetch },
  });
  const search = await plugin.search({ query: '斗破苍穹', cursor: null, pageSize: 5 });
  assert.ok(search.items.length > 0);
  const detail = await plugin.getDetail({ id: search.items[0].id });
  assert.ok(detail.title.length > 0);
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.ok(chapters.items.length > 100);
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.ok(content.text.length > 100);
});
