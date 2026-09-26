import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live 126 discovery, search, catalog and first/middle/last novel text remain reachable', { timeout: 90_000 }, async () => {
  await plugin.activate({ log: { info() {}, warn() {} }, resource: { proxy() { return 'http://127.0.0.1/live-resource'; } }, http: { fetch: (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(15_000) }) } });
  const home = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(home.document.components[1].children[0].categories.length, 15);
  const ranking = await plugin.discover({ target: 'chart:allvisit', cursor: null, collectionId: null, pageSize: 3 });
  assert.ok(ranking.document.components[0].children[0].items.length > 0);
  const discovery = await plugin.discover({ target: 'category:xuanhuan', cursor: null, collectionId: null, pageSize: 3 });
  const candidate = discovery.document.components[0].children[0].items[0]?.content;
  assert.ok(candidate);
  const found = await plugin.search({ query: candidate.title, cursor: null, pageSize: 8 });
  assert.ok(found.items.some((item) => item.id === candidate.id));
  const chapters = await plugin.getChapters({ id: candidate.id });
  assert.ok(chapters.items.length > 0);
  const samples = [...new Set([0, Math.floor((chapters.items.length - 1) / 2), chapters.items.length - 1])];
  for (const index of samples) {
    const chapter = chapters.items[index];
    const content = await plugin.getContent({ id: candidate.id, chapterId: chapter.id });
    assert.equal(content.chapterId, chapter.id);
    assert.ok(content.text.length > 20);
  }
});
