import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live JM API search, catalog, page registration and decoded first image', { timeout: 90000 }, async () => {
  const resources = [];
  await plugin.activate({ log: { info() {} }, resource: { proxy(request) { resources.push(request); return request.url; } },
    http: { fetch: (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(20000) }) } });
  const search = await plugin.search({ query: 'MANA', cursor: null, pageSize: 5 });
  assert.ok(search.items.length > 0);
  const item = search.items[0];
  const detail = await plugin.getDetail({ id: item.id });
  assert.ok(detail.title);
  const chapters = await plugin.getChapters({ id: item.id });
  assert.ok(chapters.items.length > 0);
  const content = await plugin.getContent({ id: item.id, chapterId: chapters.items[0].id });
  assert.ok(content.pages.length > 0);
  const first = resources.find(value => value.url === content.pages[0].url);
  assert.ok(first);
  if (first.handler) {
    const decoded = await plugin.getResource(first);
    assert.equal(decoded.mimeType, 'image/png');
    assert.ok(decoded.bytes.length > 100);
  }
});
