/** Real-site smoke; the Node harness cannot execute browser challenges, which is a failure/partial. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { collectDiscoveryContent, collectDiscoveryContinuations, createSourceTestHarness, probeResourceGroups, runReadingSourceFlow } from '@mgread/source-testkit';
test('live public UAA novel flow', { timeout: 180000 }, async t => {
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.uaa-novel', version: '1.0.0' }); t.after(() => h.cleanup());
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 3 });
  const items = collectDiscoveryContent(root); assert.ok(items.length > 0);
  const surfaces = [{ name: 'discover.root', items }], continuation = collectDiscoveryContinuations(root)[0];
  if (continuation) { const next = await plugin.discover({ ...continuation, pageSize: 3 }); surfaces.push({ name: 'discover.append.library', items: collectDiscoveryContent(next) }); }
  const flow = await runReadingSourceFlow({ plugin, contentId: items[0].id, searchRequest: { query: items[0].title, cursor: null, pageSize: 20 } });
  assert.ok(flow.contents.every(x => x.text.length > 100));
  const groups = await probeResourceGroups({ requests: h.resourceRequests, detail: flow.detail, discoverySurfaces: surfaces, searchItems: flow.searchItems,
    contents: flow.contents, contentKind: 'novel', fetch: (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(15000) }) });
  assert.equal(groups.cover.status, 'passed', JSON.stringify(groups.cover));
  console.log(JSON.stringify({ chapters: flow.chapters.items.length, public: flow.chapters.items.filter(x => x.isLocked === false).length,
    samples: flow.contents.map(x => ({ id: x.chapterId, characters: x.text.length })), covers: groups.cover.status }));
});
