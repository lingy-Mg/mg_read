import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('public target chain remains readable without credentials', async () => {
  await plugin.activate({ dataDir: 'unused', app: {}, plugin: {}, log: { debug() {}, info() {}, warn() {}, error() {} }, resource: { proxy(request) { assert.equal(request.kind, 'rehanman-image'); assert.equal(typeof request.url, 'string'); assert.equal(typeof request.referer, 'string'); return request.url; } }, http: { fetch(input, init) { return fetch(input, init); } } });
  const search = await plugin.search({ query: '美女咨商师', cursor: null, pageSize: 20 }); assert.ok(search.items.some((item) => item.id === 'webtoon:5701606'));
  const discovery = await plugin.discover({ target: null, collectionId: null, cursor: null, pageSize: 20 }); assert.ok(discovery.document.components[0].children[0].items.length > 0);
  const id = 'webtoon:5701606'; const detail = await plugin.getDetail({ id }); const chapters = await plugin.getChapters({ id }); const content = await plugin.getContent({ id, chapterId: chapters.items[0].id });
  assert.equal(detail.id, id); assert.ok(chapters.items.length > 0); assert.ok(content.pages.length > 0); assert.equal(content.text, null); assert.equal(content.pages[0].resourcePolicy, undefined);
  const image = await fetch(content.pages[0].url); assert.equal(image.ok, true); assert.match(image.headers.get('content-type') ?? '', /^image\//u); assert.ok((await image.arrayBuffer()).byteLength > 0);
});
