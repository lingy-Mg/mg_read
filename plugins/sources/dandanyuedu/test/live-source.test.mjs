/** Bounded public-API smoke; JSON, category HTML and chapter text are never persisted as fixtures. */
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live public QQ chain completes without login signature Cookie or fixed GUID', { timeout: 120_000 }, async (t) => {
  const cacheDir = await mkdtemp(join(tmpdir(), 'dandan-live-'));
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

  const search = await plugin.search({ query: '斗罗大陆', cursor: null, pageSize: 10 });
  assert.ok(search.items.length > 0);
  const detail = await plugin.getDetail({ id: search.items[0].id });
  assert.equal(detail.id, search.items[0].id);
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.ok(chapters.items.length > 0 && chapters.items.length <= 5000);
  const readable = chapters.items.find((chapter) => chapter.isLocked !== true);
  assert.ok(readable);
  const content = await plugin.getContent({ id: detail.id, chapterId: readable.id });
  assert.ok(content.text.length > 0);
  assert.deepEqual(content.pages, []);
  const discovery = await plugin.discover({
    target: 'category:ancient-romance',
    cursor: null,
    collectionId: null,
    pageSize: 20,
  });
  assert.equal(discovery.kind, 'document');
  assert.ok(discovery.document.components[0].children[0].items.length > 0);
  const coverRequest = proxied.find((request) => request.kind === 'qq-cover');
  assert.ok(coverRequest);
  const cover = await plugin.resource(coverRequest);
  assert.equal(cover.status, 200);
  assert.match(cover.headers['content-type'], /^image\//u);
  assert.ok(cover.body.byteLength > 0);
});
