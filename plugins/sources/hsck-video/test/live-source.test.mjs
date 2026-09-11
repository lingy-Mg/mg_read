import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live video discovery covers, search, detail and catalog are reachable without playback collection', { timeout: 240_000 }, async () => {
  const liveFetch = (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(180_000) });
  await plugin.activate({ log: { info() {}, warn() {} }, resource: { proxy() { return 'http://127.0.0.1/live-resource'; } }, http: { fetch: liveFetch } });
  const discovery = await plugin.discover({ target: 'category:1', cursor: null, collectionId: null, pageSize: 3 });
  const discoveryItems = discovery.document.components[0].children[0].items;
  assert.ok(discoveryItems.length > 0); assert.ok(discoveryItems.every((item) => item.content.coverUrl !== null));
  const query = discoveryItems[0].content.title.slice(0, 8);
  const result = await plugin.search({ query, cursor: null, pageSize: 1 });
  const matched = result.items.find((item) => item.id === discoveryItems[0].content.id);
  assert.ok(matched); const detail = await plugin.getDetail({ id: matched.id });
  const chapters = await plugin.getChapters({ id: detail.id }); assert.ok(chapters.groups.length > 0); assert.ok(chapters.items.length > 0);
  assert.equal(chapters.items.length, chapters.groups.reduce((count, group) => count + group.episodes.length, 0));
});
