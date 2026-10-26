/** Actual Bilibili source output must pass production Runtime validators. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as source from '../../../plugins/sources/bilibili-audio/dist/index.mjs';
import {
  validateDiscoverResult, validateSearchResult, validateDetailResult,
  validateChaptersResult, validateContentResult,
} from '../dist/plugin-content.js';

test('Bilibili search, details, chapters and audio satisfy the production schema', async () => {
  const pluginId = 'org.mgread.bilibili-audio';
  const sourceName = '哔哩哔哩';
  const bvid = 'BV1tGe36YEap';
  const id = `bvid:${bvid}`;
  const video = { bvid, title: '真实契约回归', duration: 120, pic: '', desc: '', owner: { name: '测试作者' },
    pages: [{ cid: 123, page: 1, part: '第一集', duration: 120 }] };
  await source.activate({
    log: { info() {} },
    errors: { raise(value) { throw new Error(value.code); } },
    resource: { proxy() { return `http://127.0.0.1/v1/source-resource/${'x'.repeat(24)}`; } },
    http: { async fetch(input) {
      const data = String(input).includes('/playurl?')
        ? { dash: { audio: [{ codecs: 'mp4a.40.2', bandwidth: 192000, baseUrl: 'https://media.example/audio.m4s' }] } }
        : String(input).includes('/search/type?')
          ? { numResults: 1, result: [{ bvid, title: video.title, duration: '2:00', author: '测试作者', pic: '' }] }
          : video;
      return new Response(JSON.stringify({ code: 0, data }));
    } },
  });
  validateDiscoverResult(pluginId, sourceName, await source.discover({ target: null, cursor: null, collectionId: null }));
  for (const query of [bvid, 'https://www.bilibili.com/video/BV1tGe36YEap/?_from=333.337.search-card.all.click', '契约回归']) {
    const search = validateSearchResult(pluginId, sourceName, await source.search({ query, cursor: null, pageSize: 20 }));
    assert.deepEqual(search.items[0].attributes, [{ key: 'durationSeconds', label: '时长（秒）', value: '120' }]);
  }
  const detail = validateDetailResult(pluginId, sourceName, await source.getDetail({ id }));
  assert.equal(detail.id, id);
  const catalog = validateChaptersResult(pluginId, sourceName, await source.getChapters({ id }));
  assert.equal(catalog.items[0].attributes[0].value, '120');
  const media = validateContentResult(pluginId, sourceName, await source.getContent({ id, chapterId: catalog.items[0].id }));
  assert.equal(media.media.resourceType, 'audio');
});
