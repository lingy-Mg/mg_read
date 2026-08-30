/** Real-network smoke stays separate from deterministic fixtures. */
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

const runtimeUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36';

test('live search and category discovery return reachable covers', { timeout: 120_000 }, async (t) => {
  const cacheDir = await mkdtemp(join(tmpdir(), 'xiezhenji2-live-cache-')); t.after(() => rm(cacheDir, { recursive: true, force: true }));
  const proxied = [];
  await plugin.activate({ dataDir: cacheDir, cacheDir, app: { runtimeVersion: 'live', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.xiezhenji2', version: '1.0.3' }, log: { debug() {}, info() {}, warn() {}, error() {} }, resource: { proxy(request) { const headers = new Headers(request.headers); assert.equal(headers.has('user-agent'), false); headers.set('user-agent', runtimeUserAgent); proxied.push({ ...request, headers: Object.fromEntries(headers) }); return `http://127.0.0.1/live-resource/${proxied.length}`; } }, http: { async fetch(input, init) { const headers = new Headers(init?.headers); assert.equal(headers.has('user-agent'), false); headers.set('user-agent', runtimeUserAgent); return fetch(input, { ...init, headers }); } } });
  const result = await plugin.search({ query: 'navia', cursor: null, pageSize: 5 }); assert.ok(result.items.length > 0); assert.ok(result.items.every((item) => item.id && item.title && item.coverUrl));
  const category = await plugin.discover({ target: 'category:cosplay', cursor: null, collectionId: null, pageSize: 5 }); const categoryItems = category.document.components[0].children[0].items; assert.ok(categoryItems.length > 0); assert.ok(categoryItems.every((item) => item.content.coverUrl));
  const cover = proxied.find((request) => request.kind === 'image'); assert.ok(cover); const response = await fetch(cover.url, { headers: cover.headers }); assert.equal(response.status, 200); assert.match(response.headers.get('content-type') ?? '', /^image\//u); await response.body?.cancel();
});
