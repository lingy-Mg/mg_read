/** Video-specific playback, stable multipart identities and source error contracts. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

const bvid = 'BV1tGe36YEap';
const pages = Array.from({ length: 34 }, (_, index) => ({
  cid: String(41977906364 + index),
  page: index + 1,
  part: ['1-20', '21-40', '41-60'][index] ?? `${index * 20 + 1}-${index * 20 + 20}`,
  duration: 6840,
}));
pages[27].part = '541-560';
pages[28].part = '561-580';
pages[31].part = '611-660';
pages[32].part = '661-710';
pages[33].part = '711-760完结';
const video = {
  bvid,
  title: '超爽逃荒群像多人有声《恶嫂逃荒带飞全家》完本畅听',
  pic: '//i1.hdslb.com/bfs/archive/cover.jpg',
  desc: '逃荒路上带飞全家',
  duration: 262333,
  owner: { name: '哥听的是寂寞' },
  pages,
};

test('Bilibili source declares inline discovery input, searches and resolves all parts to proxied playback', async () => {
  const resources = [];
  const requests = [];
  await plugin.activate({
    log: { info() {}, warn() {}, error() {}, debug() {} },
    resource: { proxy(value) { resources.push(value); return `http://127.0.0.1/resource/${resources.length}`; } },
    http: {
      async fetch(input, init) {
        const url = String(input);
        requests.push({ url, init });
        let body;
        if (url.includes('/search/type?')) {
          body = { code: 0, data: { numResults: 1, numPages: 1, result: [{ bvid, title: '超爽<em class="keyword">逃荒路上带飞全家</em>', author: video.owner.name, pic: video.pic, duration: '4372:13' }] } };
        } else if (url.includes('/player/playurl?')) {
          body = { code: 0, data: { format: 'mp4720', durl: [
            { url: 'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/part.mp4?token=temporary' },
          ] } };
        } else {
          body = { code: 0, data: video };
        }
        return new Response(JSON.stringify(body), { status: 200, headers: { 'content-type': 'application/json' } });
      },
    },
  });

  const emptySearch = await plugin.search({ query: '  ', cursor: null, pageSize: 20 });
  assert.deepEqual(emptySearch, { items: [], nextCursor: null, totalCount: 0 });
  const result = await plugin.search({ query: '逃荒路上带飞全家', cursor: null, pageSize: 20 });
  assert.equal(result.items[0].id, `bvid:${bvid}`);
  assert.equal(result.items[0].title, '超爽逃荒路上带飞全家');
  assert.equal(result.items[0].coverOrientation, 'landscape');
  assert.equal(result.items[0].contentKind, 'video');
  assert.equal(result.nextCursor, null);
  assert.deepEqual(result.items[0].attributes, [{ key: 'durationSeconds', label: '时长（秒）', value: '262333' }]);
  assert.match(requests.find((entry) => entry.url.includes('/search/type?')).url, /keyword=%E9%80%83%E8%8D%92%E8%B7%AF%E4%B8%8A%E5%B8%A6%E9%A3%9E%E5%85%A8%E5%AE%B6/u);

  const discovery = await plugin.discover({ target: null, cursor: null, collectionId: null });
  assert.equal(discovery.document.components[0].children[0].type, 'searchInput');
  assert.equal(discovery.document.components[0].children[0].submitLabel, '读取视频');
  await assert.rejects(plugin.discover({ target: 'home', cursor: null, collectionId: null }), /not supported/u);

  const resolved = await plugin.search({ query: `https://www.bilibili.com/video/${bvid}/?_from=333.337.search-card.all.click`, cursor: null, pageSize: 20 });
  assert.equal(resolved.items[0].id, `bvid:${bvid}`);
  const shared = await plugin.search({ query: `分享视频 ${bvid} 给你`, cursor: null, pageSize: 20 });
  assert.equal(shared.items[0].title, video.title);
  const detail = await plugin.getDetail({ id: `bvid:${bvid}` });
  assert.equal(detail.title, video.title);
  assert.equal(detail.description, video.desc);
  const catalog = await plugin.getChapters({ id: `bvid:${bvid}` });
  assert.equal(requests.filter((entry) => entry.url.includes('/web-interface/view?')).length, 1, 'resolution, details and catalog share one request');
  assert.equal(catalog.items.length, 34);
  assert.deepEqual(catalog.items[0].attributes, [{ key: 'durationSeconds', label: '时长（秒）', value: '6840' }]);
  assert.equal(catalog.groups.length, 1);
  assert.deepEqual(catalog.groups[0].episodes, catalog.items);
  assert.equal(new Set(catalog.items.map((item) => item.id)).size, 34);
  assert.equal(catalog.items[27].title, '541-560');
  assert.equal(catalog.items[33].title, '711-760完结');

  const content = await plugin.getContent({ id: `bvid:${bvid}`, chapterId: catalog.items[27].id });
  assert.equal(content.contentKind, 'video');
  assert.equal(content.media.resourceType, 'video');
  assert.equal(content.media.mimeType, 'video/mp4');
  assert.equal(content.media.resourcePolicy, 'sessionOnly');
  assert.match(content.media.url, /^http:\/\/127\.0\.0\.1\/resource/u);
  assert.deepEqual(resources.find((value) => value.kind === 'video'), {
    kind: 'video', url: 'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/part.mp4?token=temporary',
    headers: { Referer: `https://www.bilibili.com/video/${bvid}/` },
  });
  assert.equal(new URL(requests.find((entry) => entry.url.includes('/player/playurl?')).url).searchParams.get('fnval'), '1');
  assert.equal(new URL(requests.find((entry) => entry.url.includes('/player/playurl?')).url).searchParams.get('platform'), 'html5');
  assert.equal(new URL(requests.find((entry) => entry.url.includes('/player/playurl?')).url).searchParams.get('cid'), catalog.items[27].id.split(':').at(-1));
});

test('rejects malformed content and episode identities', async () => {
  await assert.rejects(plugin.getDetail({ id: 'bvid:BV-invalid' }), /Video ID is invalid/u);
  await assert.rejects(plugin.getContent({ id: `bvid:${bvid}`, chapterId: 'other:cid:1' }), /Episode ID is invalid/u);
  await assert.rejects(plugin.getContent({ id: `bvid:${bvid}`, chapterId: `bvid:${bvid}:cid:0` }), /Episode ID is invalid/u);
});

test('resolves b23 share links, reports blocked access and does not cache failures', async () => {
  let attempts = 0;
  await plugin.activate({
    log: { info() {} }, resource: { proxy() { return 'http://127.0.0.1/resource/cover'; } },
    errors: { raise(value) { throw Object.assign(new Error(value.message), { code: value.code }); } },
    http: { async fetch(input) {
      if (String(input).startsWith('https://b23.tv/')) return { ok: true, status: 200, url: `https://www.bilibili.com/video/${bvid}/?p=34` };
      if (++attempts === 1) return new Response('', { status: 412 });
      return new Response(JSON.stringify({ code: 0, data: video }));
    } },
  });
  const request = { query: '分享 https://b23.tv/abc123', cursor: null, pageSize: 20 };
  await assert.rejects(plugin.search(request), (error) => error.code === 'source_access_blocked' && /HTTP 412/u.test(error.message));
  const result = await plugin.search(request);
  assert.equal(result.items[0].id, `bvid:${bvid}`);
  assert.equal(attempts, 2);
  await assert.rejects(plugin.search({ ...request, query: 'https://www.bilibili.com/video/BV-invalid' }), /请输入有效/u);
});

test('rejects DASH-only, truncated multipart and unsafe upstream responses', async () => {
  let payload;
  await plugin.activate({
    log: { info() {} },
    resource: { proxy() { assert.fail('unusable media must not be registered'); } },
    errors: { raise(value) { throw Object.assign(new Error(value.message), { code: value.code }); } },
    http: { async fetch() { return new Response(JSON.stringify({ code: 0, data: payload })); } },
  });
  const valid = { url: 'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/video.mp4' };
  for (payload of [
    { dash: { video: [{ baseUrl: valid.url }], audio: [{ baseUrl: valid.url }] } },
    { format: 'mp4720', durl: [valid, valid] },
    { format: 'flv720', durl: [valid] },
    ...['http://127.0.0.1/video.mp4', 'https://bilivideo.com.evil.test/video.mp4',
      'https://user:secret@cdn.bilivideo.com/video.mp4', 'https://cdn.bilivideo.com/video.m4s',
      'https://cdn.bilivideo.com:8000/video.mp4'].map((url) => ({ format: 'mp4720', durl: [{ url }] })),
  ]) {
    await assert.rejects(plugin.getContent({ id: `bvid:${bvid}`, chapterId: `bvid:${bvid}:cid:123` }),
      (error) => error.code === 'source_media_resolution_failed');
  }
});

test('search pagination follows source page counts and sends the requested size', async () => {
  const urls = [];
  await plugin.activate({
    log: { info() {} }, resource: { proxy() { assert.fail('untrusted cover must not be proxied'); } },
    http: { async fetch(input) {
      const url = new URL(input); urls.push(url);
      return Response.json({ code: 0, data: { numPages: 2, numResults: 2,
        result: [{ bvid, title: '视频', pic: 'http://localhost/cover.jpg' }] } });
    } },
  });
  const first = await plugin.search({ query: '视频', cursor: null, pageSize: 1 });
  assert.equal(first.nextCursor, 'search:2');
  assert.equal(first.items[0].coverUrl, null);
  assert.deepEqual(first.items[0].attributes, [], 'unknown duration must not become zero');
  const last = await plugin.search({ query: '视频', cursor: first.nextCursor, pageSize: 1 });
  assert.equal(last.nextCursor, null);
  assert.equal(urls[1].searchParams.get('page'), '2');
  assert.equal(urls[1].searchParams.get('page_size'), '1');
});
