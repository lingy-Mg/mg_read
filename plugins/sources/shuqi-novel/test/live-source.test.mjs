/** Real public book flow; reports readable and VIP counts without reading locked chapters. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { collectDiscoveryContent, collectDiscoveryContinuations, createSourceTestHarness,
  probeResourceGroups, runReadingSourceFlow } from '@mgread/source-testkit';

test('live Shuqi discovery, canonical search, full catalog, public samples and cover surfaces', { timeout: 180000 }, async t => {
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.shuqi-novel', version: '1.0.0' });
  t.after(() => h.cleanup());
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 3 });
  const items = collectDiscoveryContent(root); assert.ok(items.length > 0);
  const surfaces = [{ name: 'discover.root', items }];
  const next = collectDiscoveryContinuations(root)[0];
  if (next) { const page = await plugin.discover({ ...next, pageSize: 3 });
    assert.ok(page.items.length > 0); assert.ok(page.items.every(x => !items.some(y => y.id === x.content.id)));
    surfaces.push({ name: 'discover.append.featured', items: collectDiscoveryContent(page) }); }
  const flow = await runReadingSourceFlow({ plugin, contentId: items[0].id,
    searchRequest: { query: items[0].title, cursor: null, pageSize: 20 } });
  assert.ok(flow.contents.every(x => x.text.length > 100));
  const groups = await probeResourceGroups({ requests: h.resourceRequests, detail: flow.detail,
    discoverySurfaces: surfaces, searchItems: flow.searchItems, contents: flow.contents, contentKind: 'novel' });
  assert.equal(groups.cover.status, 'passed', JSON.stringify(groups.cover));
  console.log(JSON.stringify({ chapterItems: flow.chapters.items.length, locked: flow.chapters.items.filter(x => x.isLocked).length,
    samples: flow.contents.map(x => ({ chapterId: x.chapterId, characters: x.text.length })),
    coverSurfaces: groups.cover.surfaces?.map(x => ({ name: x.name, status: x.status })) }));
});
