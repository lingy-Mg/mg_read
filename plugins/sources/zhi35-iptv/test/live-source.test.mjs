/** 真实来源全分类链路与分层资源抽样；失败也写报告，不能代替主程序首帧/进度验收。 */
import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import test from 'node:test';
import {
  collectDiscoveryContent, collectDiscoveryContinuations, createSourceTestHarness, probeResourceGroups,
} from '@mgread/source-testkit';
import * as plugin from '../dist/index.mjs';
import { probeHls, failureCode, sanitize } from './live-probe.mjs';

test('live IPTV traverses every category and probes stratified covers and media', { timeout: 360000 }, async (t) => {
  const report = { startedAt: new Date().toISOString(), status: 'failed', chain: [], covers: null, media: [], playback: 'notTested' };
  const fetchBounded = (url, init = {}) => fetch(url, {
    ...init, signal: init.signal ? AbortSignal.any([init.signal, AbortSignal.timeout(8000)]) : AbortSignal.timeout(8000),
  });
  const { version } = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  const harness = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.zhi35-iptv', version, fetch: fetchBounded });
  t.after(harness.cleanup);
  try {
    const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 });
    const rootItems = collectDiscoveryContent(root);
    assert.ok(rootItems.length > 0);
    const categories = root.document.components[0].children[0].categories;
    const surfaces = [{ name: 'discover.root', items: rootItems }];
    const samples = new Map();
    let allIds;
    for (const category of categories) {
      let page = await plugin.discover({ target: category.target, cursor: null, collectionId: null, pageSize: 50 });
      const items = [...collectDiscoveryContent(page)];
      surfaces.push({ name: `discover.target.${category.title}`, items: [...items] });
      let pages = 1;
      while (collectDiscoveryContinuations(page).length > 0) {
        assert.ok(pages < 100, 'discovery_pagination_limit');
        page = await plugin.discover({ ...collectDiscoveryContinuations(page)[0], pageSize: 50 });
        assert.equal(page.kind, 'append');
        items.push(...collectDiscoveryContent(page));
        pages += 1;
      }
      assert.equal(items.length, category.count);
      assert.equal(new Set(items.map((item) => item.id)).size, items.length);
      report.chain.push({ stage: `discover.${category.title}`, status: 'passed', items: items.length, pages });
      if (category.target === 'all') { allIds = new Set(items.map((item) => item.id)); continue; }
      for (const index of new Set([0, Math.floor((items.length - 1) / 2), items.length - 1])) {
        const item = items[index];
        if (item) samples.set(item.id, item);
      }
    }
    assert.ok(allIds.size > 0);
    const first = rootItems[0];
    const search = await plugin.search({ query: first.title, cursor: null, pageSize: 50 });
    assert.ok(search.items.some((item) => item.id === first.id));
    const detail = await plugin.getDetail({ id: first.id });
    assert.equal(detail.contentKind, 'video');
    report.chain.push({ stage: 'search/detail', status: 'passed', items: search.items.length, sameId: true });
    const contentSamples = (await Promise.all([...samples.values()].map(async (item) => {
      const catalog = await plugin.getChapters({ id: item.id });
      assert.ok(catalog.items.length > 0);
      assert.deepEqual(new Set(catalog.items.map((entry) => entry.id)), new Set(catalog.groups.flatMap((group) => group.episodes.map((entry) => entry.id))));
      return Promise.all(catalog.groups.map(async (group) => {
        try {
          const content = await plugin.getContent({ id: item.id, chapterId: group.episodes[0].id });
          assert.equal(content.chapterId, group.episodes[0].id);
          assert.equal(content.contentKind, 'video');
          return { item, group, content };
        } catch (error) {
          report.media.push({ channel: item.title, id: item.id, group: group.title, status: 'failed', stage: 'content', failureCode: failureCode(error) });
          return null;
        }
      }));
    }))).flat().filter(Boolean);
    report.chain.push({ stage: 'catalog/content', status: report.media.length === 0 ? 'passed' : 'partial', channels: samples.size, media: contentSamples.length });
    // Keep at most two declared cover resources per surface, retaining original item/declared counts.
    const coverValues = new Set([...surfaces, { items: search.items }, { items: [detail] }].flatMap((surface) => surface.items.map((item) => item.coverUrl).filter(Boolean).slice(0, 2)));
    const selectedRequests = harness.resourceRequests.filter((request) => coverValues.has(request.projectedUrl));
    report.covers = sanitize((await probeResourceGroups({
      requests: selectedRequests, discoverySurfaces: surfaces, searchItems: search.items, detail, fetch: fetchBounded,
    })).cover);
    const pending = contentSamples.slice(0, 24);
    async function worker() {
      while (pending.length > 0) {
        const sample = pending.shift();
        if (!sample) return;
        const request = harness.resourceRequests.find((entry) => entry.projectedUrl === sample.content.media.url);
        assert.ok(request);
        const base = { channel: sample.item.title, id: sample.item.id, categories: sample.item.categories, group: sample.group.title, type: sample.content.media.resourceType };
        try {
          let result;
          if (request.kind === 'hls') result = await probeHls(request, fetchBounded);
          else {
            const groups = await probeResourceGroups({ requests: [request], contents: [sample.content], contentKind: 'video', fetch: fetchBounded });
            result = sanitize(groups.video);
          }
          report.media.push({ ...base, ...result });
        } catch (error) {
          report.media.push({ ...base, status: 'failed', failureCode: failureCode(error) });
        }
      }
    }
    await Promise.all([worker(), worker()]);
    if (contentSamples.length > 24) report.media.push({ status: 'notTested', reason: 'sample_limit', samples: contentSamples.length - 24 });
    report.status = report.covers.status === 'passed' && report.media.length > 0 && report.media.every((sample) => sample.status === 'passed') ? 'passed' : 'partial';
  } catch (error) {
    report.failureCode = failureCode(error);
    throw error;
  } finally {
    report.finishedAt = new Date().toISOString();
    await mkdir(new URL('../artifacts/', import.meta.url), { recursive: true });
    await writeFile(new URL('../artifacts/live-report.json', import.meta.url), `${JSON.stringify(report, null, 2)}\n`);
    console.log(JSON.stringify({ status: report.status, categories: report.chain.length, covers: report.covers?.status, mediaPassed: report.media.filter((item) => item.status === 'passed').length, mediaFailed: report.media.filter((item) => item.status === 'failed').length }));
  }
  assert.equal(report.status, 'passed', 'Upstream resource failures are recorded in artifacts/live-report.json');
});
