import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live encrypted API covers discovery, search, detail, catalog and playback resolution', { timeout: 90_000 }, async () => {
  const resources = [];
  const liveFetch = (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(20_000) });
  await plugin.activate({
    log: { debug() {}, error() {}, info() {}, warn() {} },
    resource: {
      proxy(value) {
        resources.push(value);
        return `http://127.0.0.1:9000/v1/source-resource/${resources.length}`;
      },
    },
    http: { fetch: liveFetch },
  });

  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 3 });
  const rootItems = root.document.components.flatMap((component) => component.children ?? []).flatMap((child) => child.items ?? []);
  assert.ok(rootItems.length > 0);
  assert.ok(rootItems.every((item) => item.content.contentKind === 'video'));
  assert.ok(rootItems.every((item) => item.content.coverUrl?.startsWith('http://127.0.0.1:') === true));

  const first = rootItems[0].content;
  const search = await plugin.search({ query: first.title, cursor: null, pageSize: 3 });
  assert.ok(search.items.length > 0);
  const detail = await plugin.getDetail({ id: first.id });
  const catalog = await plugin.getChapters({ id: detail.id });
  assert.ok(catalog.items.length > 0);
  const playable = catalog.items.find((item) => item.isLocked !== true);
  assert.notEqual(playable, undefined);
  const content = await plugin.getContent({ id: detail.id, chapterId: playable.id });
  assert.equal(content.contentKind, 'video');
  assert.ok(content.media.url.startsWith('http://127.0.0.1:'));
  assert.ok(resources.some((value) => value.kind === 'hls' || value.kind === 'video'));
});
