import test from 'node:test';
import assert from 'node:assert/strict';
import * as plugin from '../dist/index.mjs';

test('live Wogg discovery reaches an indexed entry', { timeout: 45_000 }, async () => {
  await plugin.activate({ dataDir: '.live-data', cacheDir: '.live-cache', app: { runtimeVersion: 'live', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.wanou-wangpan', version: '1.0.0' }, log: { debug() {}, info() {}, warn() {}, error() {} }, webview: { async open() { throw new Error('WebView is not needed for listing smoke.'); } }, resource: { proxy() { return 'http://127.0.0.1/resource'; } }, http: { fetch } });
  const result = await plugin.discover({ target: 'category:movie', cursor: null, collectionId: null, pageSize: 3 });
  assert.ok(result.document.components[0].children[0].items.length > 0);
});
