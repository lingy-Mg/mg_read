import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live search, 34-part catalog, and current playback URL', async (t) => {
  const media = [];
  await plugin.activate({
    log: { info() {}, warn() {}, error() {}, debug() {} },
    resource: { proxy(value) { media.push(value); return 'http://127.0.0.1/resource/live'; } },
    http: { fetch: (input, init) => fetch(input, init) },
  });
  let result;
  try {
    result = await plugin.search({ query: '逃荒路上带飞全家', cursor: null, pageSize: 10 });
  } catch (error) {
    if (error instanceof Error && /HTTP 412/u.test(error.message)) {
      t.skip('Bilibili rejected the current automated HTTP session with 412.');
      return;
    }
    throw error;
  }
  const target = result.items.find((item) => item.id === 'bvid:BV1tGe36YEap');
  assert.ok(target, 'search should find the video shown in the request screenshots');
  const detail = await plugin.getDetail({ id: target.id });
  assert.match(detail.title, /逃荒.*全家/u);
  const catalog = await plugin.getChapters({ id: target.id });
  assert.equal(catalog.items.length, 34);
  assert.equal(catalog.items[27].title, '541-560');
  assert.equal(catalog.items[33].title, '711-760完结');
  await plugin.getContent({ id: target.id, chapterId: catalog.items[0].id });
  assert.equal(media.at(-1)?.kind, 'audio');
  assert.match(media.at(-1)?.url ?? '', /^https:\/\//u);
});
