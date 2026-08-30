import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live mirror discovery, search, detail, catalog and playback projection are reachable', { timeout: 60_000 }, async () => {
  const resources = [];
  const liveFetch = (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(15_000) });
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: {
      proxy(value) {
        resources.push(value);
        return 'http://127.0.0.1/live-resource';
      },
    },
    http: { fetch: liveFetch },
  });

  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 3 });
  assert.equal(root.document.components.at(-1).children[0].categories.length, 10);

  const discovery = await plugin.discover({ target: 'category:gc', cursor: null, collectionId: null, pageSize: 3 });
  const discoveryItems = discovery.document.components[0].children[0].items;
  assert.ok(discoveryItems.length > 0);
  assert.ok(discoveryItems.every((item) => item.content.coverUrl !== null));

  const query = discoveryItems[0].content.title;
  const result = await plugin.search({ query, cursor: null, pageSize: 3 });
  const matched = result.items.find((item) => item.id === discoveryItems[0].content.id);
  assert.ok(matched);

  const detail = await plugin.getDetail({ id: matched.id });
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.equal(chapters.groups.length, 1);
  assert.equal(chapters.items.length, 1);

  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.equal(content.contentKind, 'video');
  assert.equal(content.media.resourceType, 'hls');
  assert.equal(resources.length, 1);
  assert.equal(resources[0].kind, 'hls');
});
