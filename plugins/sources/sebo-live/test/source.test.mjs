import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('Sebo index and channel files yield stable proxied media', async () => {
  const resources = [];
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(value) { resources.push(value); return `http://127.0.0.1/resource/${resources.length}`; } },
    http: { async fetch(input) {
      const url = String(input);
      if (url.endsWith('/json.txt')) return Response.json({ pingtai: [{ title: 'Test%20Live', address: 'test.txt', xinimg: 'https://img.example/platform.jpg', Number: '1' }] });
      if (url.endsWith('/test.txt')) return Response.json({ zhubo: [{ title: 'Channel%201', address: 'https://media.example/live.m3u8', img: '' }] });
      return new Response('not found', { status: 404 });
    } },
  });
  const listing = await plugin.discover({ target: 'category:all', cursor: null, collectionId: null, pageSize: 10 });
  const item = listing.document.components[0].children[0].items[0].content;
  assert.equal(item.title, 'Test Live');
  assert.ok(!item.id.includes('test.txt'));
  const detail = await plugin.getDetail({ id: item.id });
  assert.equal(detail.chapterCount, 1);
  const chapters = await plugin.getChapters({ id: item.id });
  assert.equal(chapters.items[0].title, 'Channel 1');
  const content = await plugin.getContent({ id: item.id, chapterId: chapters.items[0].id });
  assert.equal(content.media.resourceType, 'hls');
  assert.equal(resources.find((value) => value.kind === 'hls').url, 'https://media.example/live.m3u8');
});
