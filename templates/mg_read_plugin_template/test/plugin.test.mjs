import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';

test('standard named exports activate and use multi-file/local-package resources', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-template-test-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  const events = [];
  await plugin.activate({
    dataDir: join(root, 'data'),
    cacheDir: join(root, 'cache'),
    http: { fetch },
    log: {
      debug: (event) => events.push(event),
      info: (event) => events.push(event),
      warn: (event) => events.push(event),
      error: (event) => events.push(event),
    },
    app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.example.source', version: '0.1.0' },
  });

  const search = await plugin.search({ query: '示例', cursor: null, pageSize: 20 });
  const summary = search.items[0];
  const discovery = await plugin.discover({ target: null, cursor: null, pageSize: 20 });
  const detail = await plugin.getDetail({ id: summary.id });
  const chapters = await plugin.getChapters({
    id: summary.id,
    cursor: null,
    pageSize: 20,
  });
  const content = await plugin.getContent({
    id: summary.id,
    chapterId: chapters.items[0].id,
  });

  assert.equal(summary.title, 'MgRead 模板：示例');
  assert.equal(summary.wordCount, 12000);
  assert.equal(summary.coverUrl, null);
  assert.deepEqual(summary.tags, []);
  for (const key of [
    'author',
    'url',
    'coverUrl',
    'description',
    'language',
    'wordCount',
    'chapterCount',
    'publishedAt',
    'updatedAt',
    'latestChapter',
  ]) {
    assert.equal(Object.hasOwn(summary, key), true, `${key} must never be omitted`);
    assert.notEqual(summary[key], undefined, `${key} must use an explicit value or null`);
  }
  for (const key of ['categories', 'tags', 'attributes']) {
    assert.equal(Array.isArray(summary[key]), true, `${key} must always be an array`);
  }
  assert.equal(search.nextCursor, null);
  assert.equal(discovery.kind, 'document');
  assert.equal(discovery.document.components[0].type, 'tabs');
  assert.equal(discovery.document.components[1].children[0].layout, 'featured');
  assert.equal(detail.catalogUrl, null);
  assert.equal(chapters.items[0].order, 0);
  assert.equal(content.chapterId, chapters.items[0].id);
  assert.deepEqual(content.pages, []);
  assert.deepEqual(events, ['plugin_activated']);
});

test('package metadata is single-source and legacy files stay absent', async () => {
  const packageJson = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  const lock = JSON.parse(await readFile(new URL('../package-lock.json', import.meta.url), 'utf8'));
  assert.equal(packageJson.mgread.schemaVersion, 1);
  assert.equal(packageJson.mgread.pluginApi, 1);
  assert.equal(packageJson.mgread.displayName, '示例书源');
  assert.equal(lock.lockfileVersion, 3);
  assert.equal(lock.packages[''].dependencies['@mgread-plugin/example-parser'], 'file:./packages/example-parser');
});
