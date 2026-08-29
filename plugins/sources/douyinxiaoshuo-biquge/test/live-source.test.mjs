/** Bounded live smoke; responses stay in memory and are never persisted as fixtures. */
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live source completes discovery search detail catalog and content', { timeout: 120_000 }, async (t) => {
  const cacheDir = await mkdtemp(join(tmpdir(), 'douyinxs-live-'));
  t.after(() => rm(cacheDir, { recursive: true, force: true }));
  await plugin.activate({
    dataDir: cacheDir,
    cacheDir,
    app: {},
    plugin: {},
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: { proxy() { return 'http://127.0.0.1/resource'; } },
    http: { fetch },
  });

  const discovery = await plugin.discover({
    target: 'category:all',
    cursor: null,
    collectionId: null,
    pageSize: 20,
  });
  assert.equal(discovery.kind, 'document');
  const item = discovery.document.components[0].children[0].items[0]?.content;
  assert.ok(item);
  const search = await plugin.search({
    query: '万族之劫',
    cursor: null,
    pageSize: 20,
  });
  assert.ok(search.items.length > 0);
  const detail = await plugin.getDetail({ id: item.id });
  assert.ok(detail.title.length > 0);
  const chapters = await plugin.getChapters({ id: item.id });
  assert.ok(chapters.items.length > 0);
  const content = await plugin.getContent({
    id: item.id,
    chapterId: chapters.items[0].id,
  });
  assert.ok(content.text.length > 0);
  assert.deepEqual(content.pages, []);
});
