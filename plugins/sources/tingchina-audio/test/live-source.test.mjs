import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live audio search, detail and catalog are reachable without playback collection', { timeout: 60_000 }, async () => {
  const liveFetch = (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(15_000) });
  await plugin.activate({ log: { info() {}, warn() {} }, resource: { proxy() { return 'http://127.0.0.1/live-resource'; } }, http: { fetch: liveFetch } });
  const search = await plugin.search({ query: '有声', cursor: null, pageSize: 1 });
  assert.ok(search.items.length > 0); const detail = await plugin.getDetail({ id: search.items[0].id });
  const chapters = await plugin.getChapters({ id: detail.id }); assert.ok(chapters.items.length > 0);
});
