import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';

// Explicit, opt-in online acceptance. It never writes pages or source content
// to disk, and asserts only stable structural facts about the public Plugin API.
test('live source completes category, search, detail, catalog, and content flow', { timeout: 60000 }, async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-aisishuwu-live-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  await plugin.activate({
    dataDir: join(root, 'data'),
    cacheDir: join(root, 'cache'),
    http: { fetch },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    app: { runtimeVersion: 'live-test', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.aisishuwu', version: '0.1.0' },
  });

  const categories = await plugin.discover({ target: null, cursor: null, pageSize: 20 });
  assert.equal(categories.sections[0].layout, 'categories');
  const target = categories.sections[0].categories[0].target;

  const discovery = await plugin.discover({ target, cursor: null, pageSize: 5 });
  assert.ok(discovery.sections[0].items.length > 0);
  const book = discovery.sections[0].items[0].content;
  assert.match(book.id, /^novel:\d+$/u);

  const search = await plugin.search({ query: '修仙', cursor: null, pageSize: 5 });
  assert.ok(search.items.length > 0);

  const detail = await plugin.getDetail({ id: book.id });
  assert.equal(detail.id, book.id);
  assert.ok(detail.title.length > 0);

  const chapters = await plugin.getChapters({ id: book.id, cursor: null, pageSize: 5 });
  assert.ok(chapters.items.length > 0);
  const content = await plugin.getContent({ id: book.id, chapterId: chapters.items[0].id });
  assert.equal(content.chapterId, chapters.items[0].id);
  assert.equal(content.contentKind, 'novel');
  assert.ok((content.text ?? '').length > 0);
});
