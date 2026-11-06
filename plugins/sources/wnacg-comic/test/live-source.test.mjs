/** Real-site metadata and bounded image prefixes; no artwork is rendered or persisted. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { collectDiscoveryContent, collectDiscoveryContinuations, createSourceTestHarness, probeResourceGroups, runReadingSourceFlow } from '@mgread/source-testkit';
test('live gallery flow, signature refresh and independent cover/image groups', { timeout: 180000 }, async t => {
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.wnacg-comic', version: '1.0.0' }); t.after(() => h.cleanup());
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 3 });
  const items = collectDiscoveryContent(root); assert.ok(items.length);
  const surfaces = [{ name: 'discover.root', items }], continuation = collectDiscoveryContinuations(root)[0];
  if (continuation) { const next = await plugin.discover({ ...continuation, pageSize: 3 }); const content = collectDiscoveryContent(next);
    assert.ok(content.length); assert.ok(content.every(x => !items.some(y => x.id === y.id))); surfaces.push({ name: 'discover.append.featured', items: content }); }
  const flow = await runReadingSourceFlow({ plugin, contentId: items[0].id, searchRequest: { query: items[0].title, cursor: null, pageSize: 20 } });
  assert.equal(flow.chapters.items.length, 1); assert.ok(flow.contents[0].pages.length > 0);
  const refreshed = await plugin.getContent({ id: flow.detail.id, chapterId: flow.chapters.items[0].id });
  assert.deepEqual(refreshed.pages.map(x => x.id), flow.contents[0].pages.map(x => x.id));
  const groups = await probeResourceGroups({ requests: h.resourceRequests, detail: flow.detail, discoverySurfaces: surfaces,
    searchItems: flow.searchItems, contents: flow.contents, contentKind: 'manga', fetch: (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(15000) }) });
  assert.equal(groups.cover.status, 'passed'); assert.equal(groups.comicImages.status, 'passed');
  console.log(JSON.stringify({ albums: flow.chapters.items.length, pages: flow.contents[0].pages.length, cover: groups.cover.status, images: groups.comicImages.status,
    coverSurfaces: groups.cover.surfaces?.map(x => ({ name: x.name, status: x.status })) }));
});
