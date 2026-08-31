import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live public flow reaches discovery, search, detail, catalog and playback resolution', { timeout: 120_000 }, async (t) => {
  const resources = [];
  let requestCount = 0;
  const liveFetch = (input, init = {}) => {
    requestCount += 1;
    const liveTimeout = AbortSignal.timeout(20_000);
    const signal = init.signal === undefined
      ? liveTimeout
      : AbortSignal.any([init.signal, liveTimeout]);
    return fetch(input, { ...init, signal });
  };
  await plugin.activate({
    log: { info() {}, warn() {} },
    errors: { raise(code) { throw Object.assign(new Error(code), { code, name: 'PluginManagerError' }); } },
    resource: {
      proxy(value) {
        resources.push(value);
        return `http://127.0.0.1/live-resource/${resources.length}`;
      },
    },
    http: { fetch: liveFetch },
  });
  const discovery = await plugin.discover({ target: 'category:today', cursor: null, collectionId: null, pageSize: 3 });
  const items = discovery.document.components[0].children[0].items;
  assert.ok(items.length > 0);
  assert.ok(items.every((item) => item.content.coverUrl !== null));
  assert.ok(items.every((item) => item.content.coverOrientation === 'portrait'));
  const first = items[0].content;
  const search = await plugin.search({ query: '海贼王', cursor: null, pageSize: 3 });
  assert.ok(search.items.length > 0);
  const detail = await plugin.getDetail({ id: first.id });
  const catalog = await plugin.getChapters({ id: detail.id });
  assert.ok(catalog.groups.length > 0);
  assert.ok(catalog.groups.every((group) => group.title.trim() !== '' && !/^线路 \d+$/u.test(group.title)));
  assert.equal(catalog.items.length, catalog.groups.reduce((count, group) => count + group.episodes.length, 0));
  const requestsBeforePlayback = requestCount;
  const playbackStartedAt = performance.now();
  const content = await plugin.getContent({ id: detail.id, chapterId: catalog.items[0].id });
  const playbackRequestCount = requestCount - requestsBeforePlayback;
  t.diagnostic(`playback_resolution durationMs=${Math.round(performance.now() - playbackStartedAt)} requestCount=${playbackRequestCount}`);
  assert.ok(playbackRequestCount === 1 || playbackRequestCount === 2);
  assert.equal(content.contentKind, 'video');
  assert.ok(['hls', 'video'].includes(content.media.resourceType));
  assert.equal(content.media.resourcePolicy, 'sessionOnly');
  assert.ok(resources.length > 0);
  assert.ok(['http:', 'https:'].includes(new URL(resources[0].url).protocol));
});
