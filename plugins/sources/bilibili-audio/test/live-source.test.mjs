import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live search, 34-part catalog, and current playback URL', async (t) => {
  const media = [];
  await plugin.activate({
    log: { info() {}, warn() {}, error() {}, debug() {} },
    resource: { proxy(value) { media.push(value); return 'http://127.0.0.1/resource/live'; } },
    errors: { raise(value) { throw Object.assign(new Error(value.message), { code: value.code }); } },
    http: { fetch: (input, init) => fetch(input, init) },
  });
  let result;
  try {
    result = await plugin.search({ query: '逃荒路上带飞全家', cursor: null, pageSize: 10 });
  } catch (error) {
    if (error?.code === 'source_access_blocked') {
      t.skip(error.message);
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

test('live pasted video URL resolves independently of keyword search', async (t) => {
  await plugin.activate({
    log: { info() {} },
    resource: { proxy() { return 'http://127.0.0.1/resource/live'; } },
    errors: { raise(value) { throw Object.assign(new Error(value.message), { code: value.code }); } },
    http: { fetch: (input, init) => fetch(input, init) },
  });
  try {
    const result = await plugin.search({ query: 'https://www.bilibili.com/video/BV1tGe36YEap/?_from=333.337.search-card.all.click', cursor: null, pageSize: 20 });
    assert.equal(result.items[0].id, 'bvid:BV1tGe36YEap');
    const catalog = await plugin.getChapters({ id: result.items[0].id });
    assert.equal(catalog.items.length, 34);
  } catch (error) {
    if (error?.code === 'source_access_blocked') { t.skip(error.message); return; }
    throw error;
  }
});
