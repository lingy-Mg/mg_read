import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live discovery, search, detail, catalog and playback projection are reachable', { timeout: 60_000 }, async () => {
  const resources = [];
  const liveFetch = (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(15_000) });
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: {
      proxy(value) {
        resources.push(value);
        return 'http://127.0.0.1:9000/v1/source-resource/token123456789012';
      },
    },
    http: { fetch: liveFetch },
  });

  const discovery = await plugin.discover({ target: 'channel:latest', cursor: null, collectionId: null, pageSize: 1 });
  const item = discovery.document.components[0].children[0].items[0]?.content;
  assert.ok(item);
  assert.equal(item.contentKind, 'video');
  assert.ok(item.coverUrl);

  const result = await plugin.search({ query: item.title.slice(0, 8), cursor: null, pageSize: 1 });
  assert.ok(result.items.length > 0);
  const detail = await plugin.getDetail({ id: result.items[0].id });
  const catalog = await plugin.getChapters({ id: detail.id });
  assert.equal(catalog.groups.length, 1);
  assert.equal(catalog.items.length, 1);

  const content = await plugin.getContent({ id: detail.id, chapterId: catalog.items[0].id });
  assert.equal(content.contentKind, 'video');
  assert.ok(content.media.url.startsWith('http://127.0.0.1:'));
  assert.ok(content.media.resourceType === 'hls' || content.media.resourceType === 'video');
  assert.equal(resources.length, 1);
});
