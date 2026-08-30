/** Deterministic fixture test for the converted Cosplaytele source. */
import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import * as plugin from '../dist/index.mjs';

test('fixture chain covers discovery, search, detail, complete gallery and resource proxy', async (t) => {
  const cacheDir = await mkdtemp(join(tmpdir(), 'xiezhenji2-cache-')); t.after(() => rm(cacheDir, { recursive: true, force: true }));
  const list = await readFile(new URL('./fixtures/list.html', import.meta.url), 'utf8'); const detail = await readFile(new URL('./fixtures/detail.html', import.meta.url), 'utf8'); const second = await readFile(new URL('./fixtures/page-2.html', import.meta.url), 'utf8');
  const proxied = [];
  await plugin.activate({ dataDir: cacheDir, cacheDir, app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.xiezhenji2', version: '1.0.0' }, log: { debug() {}, info() {}, warn() {}, error() {} }, resource: { proxy(request) { proxied.push(request); return `http://127.0.0.1/resource/${proxied.length}`; } }, browser: { sessionV1: { async request() { throw new Error('Browser must not be used by the 200 fixture.'); } } }, http: { async fetch(input) { const url = new URL(input); if (url.pathname.endsWith('/2/')) return new Response(second); if (url.pathname === '/fixture-post/') return new Response(detail); if (url.pathname.includes('/wp-content/')) return new Response(new Uint8Array([1, 2, 3]), { headers: { 'content-type': 'image/jpeg' } }); return new Response(list); } } });
  const home = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 }); assert.equal(home.document.components[0].children[0].layout, 'coverGrid'); assert.equal(home.document.components[1].children[0].categories.length, 9);
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 }); assert.equal(search.items[0].title, 'Fixture Gallery'); assert.match(search.items[0].id, /^post:/u);
  const detailResult = await plugin.getDetail({ id: search.items[0].id }); assert.equal(detailResult.author, 'Fixture Author'); assert.equal(detailResult.chapterCount, 1);
  const chapters = await plugin.getChapters({ id: detailResult.id }); assert.equal(chapters.items.length, 1);
  const content = await plugin.getContent({ id: detailResult.id, chapterId: chapters.items[0].id }); assert.equal(content.text, null); assert.equal(content.pages.length, 2); assert.ok(content.pages.every((page) => page.url.startsWith('http://127.0.0.1/resource/')));
  const image = await plugin.resource(proxied.at(-1)); assert.equal(image.status, 200); assert.deepEqual([...image.body], [1, 2, 3]);
});
