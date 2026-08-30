/** Real-network smoke stays separate from deterministic fixtures. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live search and category discovery return reachable covers', { timeout: 120_000 }, async () => {
  const cacheDir = new URL('../.live-cache/', import.meta.url).pathname;
  const proxied = [];
  await plugin.activate({ dataDir: cacheDir, cacheDir, app: { runtimeVersion: 'live', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.xiezhenji2', version: '1.0.2' }, log: { debug() {}, info() {}, warn() {}, error() {} }, resource: { proxy(request) { proxied.push(request); return `http://127.0.0.1/live-resource/${proxied.length}`; } }, browser: { sessionV1: { async request() { const error = new Error('interactive browser provider unavailable'); error.code = 'unsupported'; throw error; } } }, http: { fetch } });
  const result = await plugin.search({ query: 'navia', cursor: null, pageSize: 5 }); assert.ok(result.items.length > 0); assert.ok(result.items.every((item) => item.id && item.title && item.coverUrl));
  const category = await plugin.discover({ target: 'category:cosplay', cursor: null, collectionId: null, pageSize: 5 }); const categoryItems = category.document.components[0].children[0].items; assert.ok(categoryItems.length > 0); assert.ok(categoryItems.every((item) => item.content.coverUrl));
  const cover = proxied.find((request) => request.kind === 'image'); assert.ok(cover); const response = await fetch(cover.url, { headers: cover.headers }); assert.equal(response.status, 200); assert.match(response.headers.get('content-type') ?? '', /^image\//u); await response.body?.cancel();
});
