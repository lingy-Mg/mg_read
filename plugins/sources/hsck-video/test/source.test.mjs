import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('video fixture retains neutral groups, episodes and HLS proxy metadata', async () => {
  const detail = await readFile(new URL('./fixtures/detail.html', import.meta.url), 'utf8');
  const list = await readFile(new URL('./fixtures/list.html', import.meta.url), 'utf8');
  const player = await readFile(new URL('./fixtures/player.html', import.meta.url), 'utf8');
  const resources = [];
  await plugin.activate({ log: { info() {}, warn() {} }, resource: { proxy(value) { resources.push(value); return 'http://127.0.0.1:9000/v1/source-resource/token123456789012'; } }, http: { async fetch(input) {
    const url = String(input); if (url.includes('/ajax/suggest')) return Response.json({ list: [{ id: 101, name: 'Fixture detail', pic: '/cover.jpg' }] });
    return new Response(url.includes('/type/id/') ? list : url.includes('/play/') ? player : detail);
  } } });
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(root.document.components[0].title, '热门视频');
  assert.equal(root.document.components[0].children[0].layout, 'coverGrid');
  assert.equal(root.document.components[0].children[0].items[0].content.contentKind, 'video');
  assert.equal(root.document.components[1].children[0].layout, 'chips');
  assert.equal(root.document.components[1].children[0].categories.length, 5);
  assert.ok(root.document.components[1].children[0].categories.every((category) => category.icon === 'video'));
  const discovery = await plugin.discover({ target: 'category:1', cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(discovery.document.components[0].children[0].items.length, 1);
  assert.equal(discovery.document.components[0].children[0].items[0].content.coverUrl, 'https://hsck.la/upload/fixture-cover.jpg');
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 5 }); const detailResult = await plugin.getDetail({ id: search.items[0].id });
  const catalog = await plugin.getChapters({ id: detailResult.id });
  assert.equal(catalog.groups.length, 2); assert.deepEqual(catalog.groups.map((group) => group.episodes.length), [2, 2]);
  assert.equal(catalog.items.length, 4); assert.equal(catalog.groups[1].title, 'Group Beta');
  const content = await plugin.getContent({ id: 'video:101', chapterId: catalog.groups[1].episodes[1].id });
  assert.equal(content.media.resourceType, 'hls'); assert.equal(content.media.resourcePolicy, 'sessionOnly');
  assert.equal(content.media.url.startsWith('http://127.0.0.1:'), true); assert.equal(resources[0].kind, 'hls');
  assert.equal(resources[0].headers.Range, undefined); assert.equal(resources[0].headers.Referer.includes('/sid/2/nid/2'), true);
});
