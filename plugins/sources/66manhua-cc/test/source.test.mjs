import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('synthetic fixture covers public discovery, search, detail, catalog, image manifest, proxy and restricted chapter refusal', async (t) => {
  const cacheDir = await mkdtemp(join(tmpdir(), '66manhua-cache-')); t.after(() => rm(cacheDir, { recursive: true, force: true }));
  const [list, detail, chapter, locked] = await Promise.all(['list.html', 'detail.html', 'chapter.html', 'locked-chapter.html'].map((name) => readFile(new URL(`./fixtures/${name}`, import.meta.url), 'utf8')));
  const proxied = []; const requests = [];
  await plugin.activate({ dataDir: cacheDir, cacheDir, app: {}, plugin: {}, log: { debug(){}, info(){}, warn(){}, error(){} }, resource: { proxy(request) { proxied.push(request); return `http://127.0.0.1/resource/${proxied.length}`; } }, http: { async fetch(input, init) { const url = new URL(input); requests.push({ url, init }); if (url.hostname === 'mh.aikanhanman.top') return new Response(new Uint8Array([7, 8]), { headers: { 'content-type': 'image/jpeg' } }); if (url.pathname === '/index.php/comic/sample') return new Response(detail); if (url.pathname === '/index.php/chapter/123') return new Response(chapter); if (url.pathname === '/index.php/chapter/124') return new Response(locked); return new Response(list); } } });
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 }); assert.equal(search.items.length, 1); assert.equal(search.nextCursor, null);
  const discover = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 }); assert.equal(discover.kind, 'document');
  const detailResult = await plugin.getDetail({ id: search.items[0].id }); const chapters = await plugin.getChapters({ id: detailResult.id });
  assert.equal(chapters.items.length, 2); assert.equal(chapters.items[1].isLocked, true);
  const content = await plugin.getContent({ id: detailResult.id, chapterId: chapters.items[0].id }); assert.equal(content.text, null); assert.equal(content.pages.length, 2);
  await assert.rejects(plugin.getContent({ id: detailResult.id, chapterId: chapters.items[1].id }), /requires public access/u);
  const image = await plugin.resource(proxied.at(-1)); assert.equal(image.status, 200); assert.deepEqual([...image.body], [7, 8]);
  const rejected = await plugin.resource({ kind: 'image', url: 'https://invalid.example/image.jpg', referer: 'https://66manhua.cc/index.php/chapter/123' }); assert.equal(rejected.status, 400);
  assert.ok(requests.every(({ init }) => init?.headers?.cookie === undefined && init?.headers?.['user-agent'] === undefined));
});
