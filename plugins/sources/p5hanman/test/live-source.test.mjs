/** Bounded network smoke; response HTML and image bytes are never written to fixtures. */
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live source completes search discovery detail catalog pages and Referer image fetch', { timeout: 120_000 }, async (t) => {
  const cacheDir = await mkdtemp(join(tmpdir(), 'p5hanman-live-'));
  t.after(() => rm(cacheDir, { recursive: true, force: true }));
  const proxied = [];
  await plugin.activate({
    dataDir: cacheDir,
    cacheDir,
    app: {},
    plugin: {},
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: {
      proxy(request) {
        proxied.push(request);
        return `http://127.0.0.1/resource/${proxied.length}`;
      },
    },
    http: { fetch },
  });

  const search = await plugin.search({ query: '秘密教学', cursor: null, pageSize: 20 });
  assert.ok(search.items.length > 0);
  const discovery = await plugin.discover({
    target: 'category:latest',
    cursor: null,
    collectionId: null,
    pageSize: 30,
  });
  assert.equal(discovery.kind, 'document');
  const item = discovery.document.components[0].children[0].items[0]?.content;
  assert.ok(item);
  const detail = await plugin.getDetail({ id: item.id });
  assert.equal(detail.id, item.id);
  const chapters = await plugin.getChapters({ id: item.id });
  assert.ok(chapters.items.length > 0);
  const content = await plugin.getContent({ id: item.id, chapterId: chapters.items[0].id });
  assert.equal(content.text, null);
  assert.ok(content.pages.length > 0);
  assert.ok(content.pages.every((page) => page.resourcePolicy === 'sessionOnly'));
  const pageRequest = proxied.find((request) => request.purpose === 'page');
  assert.ok(pageRequest);
  const image = await plugin.resource(pageRequest);
  assert.equal(image.status, 200);
  assert.match(image.headers['content-type'], /^image\//u);
  assert.ok(image.body.byteLength > 0);
});
