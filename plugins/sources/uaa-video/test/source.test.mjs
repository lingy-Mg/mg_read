import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('fixture covers channels, search, detail, one episode and HLS proxy metadata', async () => {
  const list = await readFile(new URL('./fixtures/list.json', import.meta.url), 'utf8');
  const detail = await readFile(new URL('./fixtures/detail.json', import.meta.url), 'utf8');
  const requests = [];
  const resources = [];
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: {
      proxy(value) {
        resources.push(value);
        return 'http://127.0.0.1:9000/v1/source-resource/token123456789012';
      },
    },
    http: {
      async fetch(input) {
        const url = String(input);
        requests.push(url);
        return new Response(url.includes('/intro?') ? detail : list, {
          headers: { 'content-type': 'application/json' },
        });
      },
    },
  });

  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(root.document.components[0].title, '最新视频');
  assert.equal(root.document.components[0].children[0].items[0].content.contentKind, 'video');
  assert.equal(root.document.components[1].children[0].categories.length, 10);

  const discovery = await plugin.discover({ target: 'channel:weekly', cursor: null, collectionId: null, pageSize: 1 });
  const collection = discovery.document.components[0].children[0];
  assert.equal(collection.items[0].content.id, 'video:10000001');
  assert.equal(collection.continuation.cursor, 'channel:weekly:2');
  assert.ok(requests.some((url) => url.includes('/rank?') && url.includes('type=1')));

  const search = await plugin.search({ query: 'fixture value', cursor: null, pageSize: 1 });
  assert.equal(search.items[0].id, 'video:10000001');
  assert.equal(search.nextCursor, 'search:2');
  assert.equal(search.totalCount, 2);
  assert.ok(requests.some((url) => url.includes('keyword=fixture+value')));

  const detailResult = await plugin.getDetail({ id: search.items[0].id });
  assert.equal(detailResult.title, 'Fixture video');
  assert.deepEqual(detailResult.aliases, ['Fixture alias']);
  assert.equal(detailResult.chapterCount, 1);

  const catalog = await plugin.getChapters({ id: detailResult.id });
  assert.equal(catalog.groups.length, 1);
  assert.equal(catalog.items.length, 1);
  assert.deepEqual(catalog.groups[0].episodes, catalog.items);

  const content = await plugin.getContent({ id: detailResult.id, chapterId: catalog.items[0].id });
  assert.equal(content.media.resourceType, 'hls');
  assert.equal(content.media.resourcePolicy, 'sessionOnly');
  assert.equal(content.media.url.startsWith('http://127.0.0.1:'), true);
  assert.equal(content.media.url.includes('media.example.test'), false);
  assert.equal(resources[0].kind, 'hls');
  assert.equal(resources[0].url, 'https://media.example.test/fixture.m3u8');
  assert.equal(resources[0].headers.Range, undefined);
});
