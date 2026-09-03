/** Live smoke validates current dynamic guards, auth, catalog and a fetchable HLS playlist. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live Yoapp discovery, fallback search, detail, episodes and HLS remain reachable', { timeout: 120_000 }, async () => {
  const resources = [];
  await plugin.activate({
    dataDir: '.live-data', cacheDir: '.live-cache',
    app: { runtimeVersion: 'live', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.fanshu-anime', version: '1.0.0' },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: { proxy(request) { resources.push(request); return 'http://127.0.0.1/live-resource'; } },
    http: { fetch },
  });
  const discovery = await plugin.discover({ target: 'category:latest', cursor: null, collectionId: null, pageSize: 5 });
  const seed = discovery.document.components[0].children[0].items[0]?.content;
  assert.ok(seed);
  const search = await plugin.search({ query: seed.title, cursor: null, pageSize: 5 });
  assert.ok(search.items.some((item) => item.id === seed.id));
  const detail = await plugin.getDetail({ id: seed.id });
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.ok(chapters.items.length > 0);
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.ok(content.media.resourceType === 'hls' || content.media.resourceType === 'video');
  const media = resources.at(-1);
  assert.ok(media);
  const response = await fetch(media.url, { headers: media.headers, signal: AbortSignal.timeout(20_000) });
  assert.equal(response.ok, true);
  const reader = response.body.getReader();
  const first = await reader.read();
  await reader.cancel();
  const prefix = Buffer.from(first.value ?? []).subarray(0, 128);
  if (content.media.resourceType === 'hls') assert.match(prefix.toString('utf8'), /^#EXTM3U/mu);
  else assert.ok((response.headers.get('content-type') ?? '').startsWith('video/') || prefix.includes(Buffer.from('ftyp')));
});
