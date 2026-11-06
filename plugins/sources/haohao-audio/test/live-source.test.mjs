/** Real-site, bounded prefix evidence; does not claim physical-device or long-duration playback. */
import assert from 'node:assert/strict';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import {createSourceTestHarness, collectDiscoveryContent, collectDiscoveryContinuations, collectDiscoveryTargets, runReadingSourceFlow, probeResourceGroups} from '../../../../packages/mg_read_source_testkit/index.js';
test('all discovery surfaces, complete catalog, first/middle/last audio and covers', {timeout: 300000}, async t => {
  const pkg = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  const boundedFetch = (input, init = {}) => fetch(input, {...init, signal: init.signal ? AbortSignal.any([init.signal, AbortSignal.timeout(20000)]) : AbortSignal.timeout(20000)});
  const harness = await createSourceTestHarness({plugin, pluginId: pkg.mgread.id, version: pkg.version, fetch: boundedFetch});
  t.after(harness.cleanup);
  const root = await plugin.discover({target: null, cursor: null, collectionId: null, pageSize: 3});
  const surfaces = [{name: 'discover.root', items: collectDiscoveryContent(root)}];
  assert.ok(surfaces[0].items.length);
  for (const target of collectDiscoveryTargets(root)) {
    const result = await plugin.discover({target, cursor: null, collectionId: null, pageSize: 3});
    const items = collectDiscoveryContent(result);
    assert.ok(items.length, target);
    surfaces.push({name: 'discover.target.' + target, items});
    const continuation = collectDiscoveryContinuations(result)[0];
    if (continuation) {
      const append = await plugin.discover({...continuation, pageSize: 3});
      assert.equal(append.kind, 'append');
      const next = collectDiscoveryContent(append);
      assert.equal(new Set([...items, ...next].map(v => v.id)).size, items.length + next.length);
    }
  }
  const selected = surfaces[0].items[0];
  const queries = [...new Set([selected.title, selected.title.split(/[|丨｜]/u)[0].trim()])];
  const flow = await runReadingSourceFlow({plugin, contentId: selected.id, searchRequest: queries.map(query => ({query, cursor: null, pageSize: 50}))});
  const contents = [...flow.contents], coverage = [];
  for (const group of flow.chapters.groups) {
    const chapter = group.episodes.find(v => !v.isLocked);
    assert.ok(chapter, group.id);
    if (!contents.some(v => v.chapterId === chapter.id)) contents.push(await plugin.getContent({id: selected.id, chapterId: chapter.id}));
    coverage.push({groupId: group.id, chapterId: chapter.id});
  }
  // The supplied ten-audio fallback is a separate provider, even when this album is already local.
  if (pkg.mgread.id.endsWith('shiyin-audio')) {
    const response = await boundedFetch('https://fmfm.tingyou.fm/listening-api/chapters/' + selected.id.slice('album:'.length));
    const data = await response.json(), index = Math.floor(data.chapters.length / 2);
    const chapterId = 'chapter:' + selected.id.slice('album:'.length) + ':' + data.chapters[index].id;
    contents.push(await plugin.getContent({id: selected.id, chapterId}));
    coverage.push({groupId: 'remote-provider', chapterId});
  }
  const groups = await probeResourceGroups({requests: harness.resourceRequests, detail: flow.detail, discoverySurfaces: surfaces, searchItems: flow.searchItems, contents, contentKind: 'audio', fetch: boundedFetch, plugin});
  const report = {pluginId: pkg.mgread.id, time: new Date().toISOString(), surfaces: surfaces.map(v => ({name: v.name, count: v.items.length})), summary: flow.summary, coverage, groups};
  const output = new URL('../artifacts/', import.meta.url);
  await mkdir(output, {recursive: true}); await writeFile(new URL('live-report.json', output), JSON.stringify(report, null, 2));
  console.log(JSON.stringify({pluginId: report.pluginId, surfaces: report.surfaces.length, summary: report.summary, coverage, resources: Object.fromEntries(Object.entries(groups).map(([k,v]) => [k, {status:v.status, applicable:v.applicable}]))}));
  for (const [name, result] of Object.entries(groups)) if (result.applicable) assert.equal(result.status, 'passed', name + ': ' + JSON.stringify(result));
});
