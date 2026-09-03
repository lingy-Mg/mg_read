import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live Xiaowei tags and category endpoint remain reachable', { timeout: 60_000 }, async () => {
  await plugin.activate({ log: { info() {}, warn() {} }, resource: { proxy() { return 'http://127.0.0.1/live-resource'; } }, http: { fetch: (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(15_000) }) } });
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 5 });
  const target = root.document.components[0].children[0].categories[0]?.target; assert.ok(target);
  const result = await plugin.discover({ target, cursor: null, collectionId: null, pageSize: 3 });
  assert.ok(result.document.components[0].children[0].items.length > 0);
});
