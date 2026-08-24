import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live source completes category, search, detail, catalog and content', { timeout: 60000 }, async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-shudugu-live-')); t.after(() => rm(root, { recursive: true, force: true }));
  await plugin.activate({ dataDir: join(root, 'data'), cacheDir: join(root, 'cache'), http: { fetch }, log: { debug() {}, info() {}, warn() {}, error() {} }, app: { runtimeVersion: 'live', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.shudugu', version: '0.1.0' } });
  const categories = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(categories.kind, 'document');
  const category = categories.document.components.find((item) => item.type === 'section')?.children.find((item) => item.type === 'categoryCollection');
  assert.equal(category?.type, 'categoryCollection');
  const discovery = await plugin.discover({ target: category.categories[0].target, cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(discovery.kind, 'document');
  const book = discovery.document.components[0].children[0].items[0].content;
  assert.match(book.id, /^novel:\d+$/u);
  const suggestions = await plugin.searchSuggestions({ cursor: null, pageSize: 5 });
  assert.ok(suggestions.items.length > 0);
  assert.ok(suggestions.items.every((item) => item.query.trim().length > 0));
  const chapters = await plugin.getChapters({ id: book.id, cursor: null, pageSize: 5 });
  assert.ok(chapters.items.length > 0);
  const content = await plugin.getContent({ id: book.id, chapterId: chapters.items[0].id });
  assert.equal(content.contentKind, 'novel');
  assert.ok((content.text ?? '').length > 0);
});
