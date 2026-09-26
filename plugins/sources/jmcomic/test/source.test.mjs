import assert from 'node:assert/strict';
import { createCipheriv, createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import decodePng, { init as initPng } from '@jsquash/png/decode.js';
import * as plugin from '../dist/index.mjs';

const wasm = await readFile(new URL('../node_modules/@jsquash/png/codec/pkg/squoosh_png_bg.wasm', import.meta.url));
await initPng(wasm);

function encrypted(data, timestamp) {
  const key = Buffer.from(createHash('md5').update(timestamp + '185Hcomic3PAPP7R').digest('hex'));
  const cipher = createCipheriv('aes-256-ecb', key, null);
  return { data: Buffer.concat([cipher.update(JSON.stringify(data)), cipher.final()]).toString('base64') };
}

test('search, discovery, detail and chapter pages carry source-owned decoded proxy descriptors', async () => {
  const proxies = [];
  await plugin.activate({ log: { info() {} }, resource: { proxy(request) { proxies.push(request); return `http://127.0.0.1/resource/${proxies.length}`; } },
    http: { async fetch(input, init) {
      const url = String(input);
      if (url.includes('/chapter_view_template')) return new Response('var scramble_id = 220980;');
      const timestamp = init.headers.tokenparam.split(',')[0];
      if (url.includes('/search?') || url.includes('/categories/filter?')) return Response.json(encrypted({ content: [
        { id: 302560, name: '测试漫画', author: ['作者'] }, { id: 302561, name: '第二部' }, { id: 302562, name: '第三部' },
      ], total: 3 }, timestamp));
      if (url.includes('/album?')) return Response.json(encrypted({ id: 302560, name: '测试漫画', author: ['作者'], series: [] }, timestamp));
      if (url.includes('/chapter?')) return Response.json(encrypted({ name: '正篇', images: ['00001.webp', '00002.jpg'] }, timestamp));
      throw new Error('Unexpected URL');
    } } });
  const search = await plugin.search({ query: '测试', cursor: null, pageSize: 20 });
  assert.equal(search.items[0].id, 'manga:302560');
  assert.equal(search.items[0].url, 'https://18comic.vip/album/302560');
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(root.document.components.flatMap(value => value.children).find(value => value.type === 'categoryCollection').categories.length, 8);
  assert.equal(root.document.components[0].children[0].items[0].content.id, 'manga:302560');
  const listing = await plugin.discover({ target: 'category:doujin', cursor: null, collectionId: null, pageSize: 1 });
  assert.equal(listing.document.components[0].children[0].items[0].content.id, 'manga:302560');
  assert.equal(listing.document.components[0].children[0].items[0].content.url, 'https://18comic.vip/album/302560');
  const continuation = listing.document.components[0].children[0].continuation;
  const append = await plugin.discover({ ...continuation, collectionId: 'jm:doujin', pageSize: 1 });
  assert.equal(append.items[0].content.id, 'manga:302561');
  const detail = await plugin.getDetail({ id: 'manga:302560' });
  assert.equal(detail.title, '测试漫画');
  assert.equal(detail.url, 'https://18comic.vip/album/302560');
  assert.equal(detail.catalogUrl, 'https://18comic.vip/album/302560');
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.equal(chapters.items[0].id, 'manga:302560:302560');
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.equal(content.pages.length, 2);
  assert.equal(content.pages[0].mimeType, 'image/png');
  assert.equal(proxies.at(-2).handler, 'jm-stripes-v1');
  assert.ok(proxies.at(-2).params.segments >= 2 && proxies.at(-2).params.segments % 2 === 0);
  assert.match(proxies.at(-2).params.url, /\/media\/photos\/302560\/00001\.webp$/u);
});

test('image handler restores horizontal rows and rejects foreign hosts', async () => {
  const scrambled = await makePngRows([0, 1, 2, 3, 4]);
  await plugin.activate({ log: { info() {} }, http: { async fetch() { return new Response(scrambled, { status: 200, headers: { 'content-type': 'image/png' } }); } } });
  const request = { handler: 'jm-stripes-v1', params: { url: 'https://cdn-msp.jmapiproxy1.cc/media/photos/302560/00001.png', segments: 2 } };
  const result = await plugin.getResource(request);
  assert.equal(result.mimeType, 'image/png');
  const image = await decodePng(result.bytes.buffer);
  assert.deepEqual([0, 1, 2, 3, 4].map(index => image.data[index * 4]), [2, 3, 4, 0, 1]);
  await assert.rejects(() => plugin.getResource({ ...request, params: { ...request.params, url: 'https://other.example/image.png' } }), /invalid/u);
  await assert.rejects(() => plugin.getResource({ ...request, params: { ...request.params,
    url: 'https://cdn-msp.jmapiproxy1.cc:8443/media/photos/302560/00001.png' } }), /invalid/u);
});

async function makePngRows(rows) {
  const { default: encodePng, init } = await import('@jsquash/png/encode.js');
  await init(wasm);
  const data = new Uint8ClampedArray(rows.flatMap(row => [row, 0, 0, 255]));
  return new Uint8Array(await encodePng({ data, width: 1, height: rows.length }));
}
