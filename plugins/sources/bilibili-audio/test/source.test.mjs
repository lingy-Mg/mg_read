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

test('Bilibili source searches without discovery and resolves all parts to proxied playback', async () => {
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
          body = { code: 0, data: { numResults: 1, result: [{ bvid, title: '超爽<em class="keyword">逃荒路上带飞全家</em>', author: video.owner.name, pic: video.pic, duration: '4372:13' }] } };
        } else if (url.includes('/player/playurl?')) {
          body = { code: 0, data: { durl: [{ url: 'https://upos.example/video.mp4?token=temporary' }] } };
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
  assert.equal(result.items[0].contentKind, 'audio');
  assert.match(requests.find((entry) => entry.url.includes('/search/type?')).url, /keyword=%E9%80%83%E8%8D%92%E8%B7%AF%E4%B8%8A%E5%B8%A6%E9%A3%9E%E5%85%A8%E5%AE%B6/u);

  const discovery = await plugin.discover({ target: null, cursor: null, collectionId: null });
  assert.deepEqual(discovery.document.components, []);
  await assert.rejects(plugin.discover({ target: 'home', cursor: null, collectionId: null }), /not supported/u);

  const detail = await plugin.getDetail({ id: `bvid:${bvid}` });
  assert.equal(detail.title, video.title);
  assert.equal(detail.description, video.desc);
  const catalog = await plugin.getChapters({ id: `bvid:${bvid}` });
  assert.equal(catalog.items.length, 34);
  assert.equal(catalog.groups.length, 1);
  assert.equal(catalog.items[27].title, '541-560');
  assert.equal(catalog.items[33].title, '711-760完结');

  const content = await plugin.getContent({ id: `bvid:${bvid}`, chapterId: catalog.items[27].id });
  assert.equal(content.contentKind, 'audio');
  assert.equal(content.media.resourceType, 'audio');
  assert.equal(content.media.resourcePolicy, 'sessionOnly');
  assert.match(content.media.url, /^http:\/\/127\.0\.0\.1\/resource/u);
  assert.equal(resources.find((value) => value.kind === 'audio').url, 'https://upos.example/video.mp4?token=temporary');
  assert.equal(new URL(requests.find((entry) => entry.url.includes('/player/playurl?')).url).searchParams.get('cid'), catalog.items[27].id.split(':').at(-1));
});

test('rejects malformed content and episode identities', async () => {
  await assert.rejects(plugin.getDetail({ id: 'bvid:BV-invalid' }), /Video ID is invalid/u);
  await assert.rejects(plugin.getContent({ id: `bvid:${bvid}`, chapterId: 'other:cid:1' }), /Episode ID is invalid/u);
});
