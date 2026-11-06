/** Bounded real-site check: all exposed categories, paging, same-book search, text and images. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { collectDiscoveryContent, collectDiscoveryTargets, collectDiscoveryContinuations,
  createSourceTestHarness, probeResourceGroups, runReadingSourceFlow } from '@mgread/source-testkit';

test('live official Qimao novel flow and every exposed category', { timeout: 180000 }, async t => {
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.qimao-novel', version: '1.0.0' });
  t.after(() => h.cleanup());
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 3 });
  const surfaces = [{ name: 'discover.root', items: collectDiscoveryContent(root) }];
  let selected;
  for (const target of collectDiscoveryTargets(root)) {
    const result = await plugin.discover({ target, cursor: null, collectionId: null, pageSize: 3 });
    const items = collectDiscoveryContent(result);
    assert.ok(items.length > 0, target);
    selected ??= items[0];
    surfaces.push({ name: `discover.target.${target}`, items });
    const continuation = collectDiscoveryContinuations(result)[0];
    if (continuation) {
      const next = await plugin.discover({ ...continuation, pageSize: 3 });
      assert.equal(next.kind, 'append');
      assert.ok(next.items.length > 0);
      assert.ok(next.items.every(b => !items.some(old => old.id === b.content.id)));
      surfaces.push({ name: `discover.append.${target}`, items: collectDiscoveryContent(next) });
    }
  }
  const flow = await runReadingSourceFlow({ plugin, contentId: selected.id,
    searchRequest: { query: selected.title, cursor: null, pageSize: 20 } });
  assert.ok(flow.contents.every(c => typeof c.text === 'string' && c.text.length > 100));
  assert.equal(new Set(flow.chapters.items.map(c => c.id)).size, flow.chapters.items.length);
  const groups = await probeResourceGroups({ requests: h.resourceRequests, detail: flow.detail,
    discoverySurfaces: surfaces, searchItems: flow.searchItems, contents: flow.contents, contentKind: 'novel' });
  assert.equal(groups.cover.status, 'passed', JSON.stringify(groups.cover));
  console.log(JSON.stringify({ chapterItems: flow.chapters.items.length,
    samples: flow.contents.map(c => ({ chapterId: c.chapterId, characters: c.text.length })), resourceGroups: groups }));
});
