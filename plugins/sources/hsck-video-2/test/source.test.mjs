import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('mirror fixture covers categories, search, detail, single episode and HLS proxy metadata', async () => {
  const detail = await readFile(new URL('./fixtures/detail.html', import.meta.url), 'utf8');
  const list = await readFile(new URL('./fixtures/list.html', import.meta.url), 'utf8');
  const resources = [];
  const requests = [];
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
        return new Response(url.includes('/view/?id=') ? detail : list);
      },
    },
  });

  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(root.document.components[0].title, '热门视频');
  assert.equal(root.document.components[0].children[0].items[0].content.contentKind, 'video');
  assert.equal(root.document.components[1].children[0].categories.length, 10);
  assert.equal(root.document.components[1].children[0].categories[7].count, 80);

  const discovery = await plugin.discover({ target: 'category:gc', cursor: null, collectionId: null, pageSize: 5 });
  const collection = discovery.document.components[0].children[0];
  assert.equal(collection.items.length, 1);
  assert.equal(collection.items[0].content.coverUrl, 'https://hsck123.25img.com/poster.jpg');
  assert.equal(collection.continuation.cursor, 'category:gc:2:0');

  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 5 });
  assert.equal(search.items[0].id, 'video:fixture1');
  assert.ok(requests.some((url) => url.includes('search2=ndafeoafa&search=fixture')));

  const detailResult = await plugin.getDetail({ id: search.items[0].id });
  assert.equal(detailResult.title, 'Fixture video');
  assert.equal(detailResult.updatedAt, '2026-08-30T00:00:00+08:00');
  assert.equal(detailResult.chapterCount, 1);

  const catalog = await plugin.getChapters({ id: detailResult.id });
  assert.equal(catalog.groups.length, 1);
  assert.equal(catalog.items.length, 1);
  assert.deepEqual(catalog.groups[0].episodes, catalog.items);
  assert.equal(catalog.items[0].updatedAt, '2026-08-30T00:00:00+08:00');

  const requestsBeforePlayback = requests.length;
  const content = await plugin.getContent({ id: detailResult.id, chapterId: catalog.items[0].id });
  assert.equal(requests.length - requestsBeforePlayback, 1);
  assert.ok(requests.at(-1).includes('/view/?id=fixture1'));
  assert.equal(content.media.resourceType, 'hls');
  assert.equal(content.media.resourcePolicy, 'sessionOnly');
  assert.equal(content.media.url.startsWith('http://127.0.0.1:'), true);
  assert.equal(resources[0].kind, 'hls');
  assert.equal(resources[0].headers.Range, undefined);
  assert.equal(resources[0].headers.Referer.includes('/view/?id=fixture1'), true);
});

test('retries one transient mirror read without changing the public result', async () => {
  const list = await readFile(new URL('./fixtures/list.html', import.meta.url), 'utf8');
  let attempts = 0;
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy() { return 'http://127.0.0.1/resource'; } },
    http: {
      async fetch() {
        attempts += 1;
        if (attempts === 1) throw new TypeError('transient reset');
        return new Response(list);
      },
    },
  });

  const result = await plugin.discover({ target: 'category:gc', cursor: null, collectionId: null, pageSize: 1 });
  assert.equal(result.document.components[0].children[0].items.length, 1);
  assert.equal(attempts, 2);
});

test('coalesces concurrent detail and catalog reads for the same item', async () => {
  const detail = await readFile(new URL('./fixtures/detail.html', import.meta.url), 'utf8');
  let requests = 0;
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy() { return 'http://127.0.0.1/resource'; } },
    http: {
      async fetch() {
        requests += 1;
        return new Response(detail);
      },
    },
  });

  const [detailResult, catalog] = await Promise.all([
    plugin.getDetail({ id: 'video:fixture1' }),
    plugin.getChapters({ id: 'video:fixture1' }),
  ]);
  assert.equal(detailResult.id, 'video:fixture1');
  assert.equal(catalog.items.length, 1);
  assert.equal(requests, 1);
});
