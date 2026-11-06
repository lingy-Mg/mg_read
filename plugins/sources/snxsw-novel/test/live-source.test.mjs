/** Bounded real-site check of discovery, paging, same-book search, catalog, text and covers. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { collectDiscoveryContent, collectDiscoveryContinuations, createSourceTestHarness,
  probeResourceGroups, runReadingSourceFlow } from '@mgread/source-testkit';

test('live Snxsw novel flow and independent cover surfaces', { timeout: 180000 }, async t => {
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.snxsw-novel', version: '1.0.0' });
  t.after(() => h.cleanup());
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 3 });
  const items = collectDiscoveryContent(root); assert.ok(items.length > 0);
  const surfaces = [{ name: 'discover.root', items }];
  const continuation = collectDiscoveryContinuations(root)[0];
  if (continuation) {
    const next = await plugin.discover({ ...continuation, pageSize: 3 });
    assert.ok(next.items.length > 0); assert.ok(next.items.every(x => !items.some(y => y.id === x.content.id)));
    surfaces.push({ name: 'discover.append.featured', items: collectDiscoveryContent(next) });
  }
  const flow = await runReadingSourceFlow({ plugin, contentId: items[0].id,
    searchRequest: { query: items[0].title, cursor: null, pageSize: 20 } });
  assert.ok(flow.contents.every(x => x.text.length > 100));
  assert.equal(new Set(flow.chapters.items.map(x => x.id)).size, flow.chapters.items.length);
  console.log(JSON.stringify({ stage: 'reading', chapterItems: flow.chapters.items.length,
    samples: flow.contents.map(x => ({ chapterId: x.chapterId, characters: x.text.length })) }));
  const groups = await probeResourceGroups({ requests: h.resourceRequests, detail: flow.detail,
    discoverySurfaces: surfaces, searchItems: flow.searchItems, contents: flow.contents, contentKind: 'novel',
    fetch: (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(15000) }) });
  assert.equal(groups.cover.status, 'passed', JSON.stringify(groups.cover));
  console.log(JSON.stringify({ chapterItems: flow.chapters.items.length,
    samples: flow.contents.map(x => ({ chapterId: x.chapterId, characters: x.text.length })),
    coverSurfaces: groups.cover.surfaces?.map(x => ({ name: x.name, status: x.status })) }));
});
