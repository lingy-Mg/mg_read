/** Real-network smoke stays separate from deterministic fixtures. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live search returns contract-shaped content when the source is reachable', { timeout: 120_000 }, async () => {
  const cacheDir = new URL('../.live-cache/', import.meta.url).pathname;
  await plugin.activate({ dataDir: cacheDir, cacheDir, app: { runtimeVersion: 'live', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.xiezhenji2', version: '1.0.0' }, log: { debug() {}, info() {}, warn() {}, error() {} }, resource: { proxy() { return 'http://127.0.0.1/live-resource'; } }, browser: { sessionV1: { async request() { const error = new Error('interactive browser provider unavailable'); error.code = 'unsupported'; throw error; } } }, http: { fetch } });
  const result = await plugin.search({ query: 'navia', cursor: null, pageSize: 5 }); assert.ok(result.items.length > 0); assert.ok(result.items.every((item) => item.id && item.title));
});
