/** 台标专项 live：遍历真实分类/分页，核对频道数量，并逐一验证所有仍登记的唯一图片及各内容表面。 */
import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import test from 'node:test';
import { collectDiscoveryContent, collectDiscoveryContinuations, createSourceTestHarness, probeReachableResource } from '@mgread/source-testkit';
import * as plugin from '../dist/index.mjs';
import { failureCode } from './live-probe.mjs';

test('all declared IPTV logos have matching image MIME/signatures across discovery, search and detail', { timeout: 240000 }, async (t) => {
  const { version } = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  const deadline = AbortSignal.timeout(210000);
  const fetchBounded = (url, init = {}) => fetch(url, {
    ...init, signal: AbortSignal.any([deadline, AbortSignal.timeout(8000), ...(init.signal ? [init.signal] : [])]),
  });
  const harness = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.zhi35-iptv', version, fetch: fetchBounded });
  t.after(harness.cleanup);
  const report = { version, startedAt: new Date().toISOString(), status: 'failed', scope: 'all declared logos; absent logos remain null', surfaces: [], resources: [] };
  try {
    const surfaces = [];
    const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 });
    const first = collectDiscoveryContent(root)[0];
    assert.ok(first);
    surfaces.push({ name: 'discover.root', items: collectDiscoveryContent(root) });
    const categories = root.document.components[0].children[0].categories;
    const allChannels = new Map();
    for (const category of categories) {
      let page = await plugin.discover({ target: category.target, cursor: null, collectionId: null, pageSize: 50 });
      let count = 0, pages = 0;
      const ids = new Set();
      while (true) {
        const items = collectDiscoveryContent(page);
        for (const item of items) {
          assert.ok(!ids.has(item.id));
          ids.add(item.id);
          if (category.target === 'all') allChannels.set(item.id, item);
        }
        count += items.length;
        pages += 1;
        surfaces.push({ name: `discover.${category.title}.page.${pages}`, items });
        const next = collectDiscoveryContinuations(page)[0];
        if (!next) break;
        assert.ok(pages < 100);
        page = await plugin.discover({ ...next, pageSize: 50 });
      }
      assert.equal(count, category.count, `channel count changed for ${category.title}`);
    }
    const search = await plugin.search({ query: first.title, cursor: null, pageSize: 50 });
    assert.ok(search.items.some((item) => item.id === first.id));
    const detail = await plugin.getDetail({ id: first.id });
    assert.equal(detail.id, first.id);
    surfaces.push({ name: 'search', items: search.items }, { name: 'detail', items: [detail] });
    const byProxy = new Map(harness.resourceRequests.filter((request) => request.kind === 'image').map((request) => [request.projectedUrl, request]));
    const uniqueRequests = new Map();
    for (const surface of surfaces) for (const item of surface.items) {
      if (!item.coverUrl) continue;
      const request = byProxy.get(item.coverUrl);
      assert.ok(request, `unregistered cover for ${item.id}`);
      uniqueRequests.set(request.url, request);
    }
    const pending = [...uniqueRequests.values()];
    const results = new Map();
    async function worker() {
      while (pending.length > 0) {
        const request = pending.shift();
        try {
          const result = await probeReachableResource({
            requests: [request], maximumAttempts: 1, fetch: fetchBounded,
            expectedContentType: /^image\/(?:png|jpeg|gif|webp)(?:;|$)/iu, validatePrefix: validImagePrefix,
          });
          results.set(request.url, { status: 'passed', host: new URL(request.url).hostname, bytesRead: result.bytesRead, mimeType: result.contentType });
        } catch (error) { results.set(request.url, { status: 'failed', host: new URL(request.url).hostname, failureCode: failureCode(error) }); }
      }
    }
    await Promise.all(Array.from({ length: 6 }, worker));
    report.resources = [...results.values()];
    report.channels = allChannels.size;
    report.channelsWithLogo = [...allChannels.values()].filter((item) => item.coverUrl !== null).length;
    report.channelsWithoutLogo = report.channels - report.channelsWithLogo;
    for (const surface of surfaces) {
      const declared = surface.items.filter((item) => item.coverUrl !== null);
      const passed = declared.filter((item) => results.get(byProxy.get(item.coverUrl).url)?.status === 'passed').length;
      report.surfaces.push({ name: surface.name, items: surface.items.length, declared: declared.length, missing: surface.items.length - declared.length, passed, status: declared.length === 0 ? 'notRegistered' : passed === declared.length ? 'passed' : 'failed' });
    }
    report.status = report.resources.length > 0 && report.resources.every((item) => item.status === 'passed') ? 'passed' : 'partial';
    assert.equal(report.status, 'passed', 'Declared logo failures are recorded in artifacts/live-logo-report.json');
  } catch (error) { report.failureCode = failureCode(error); throw error; }
  finally {
    report.finishedAt = new Date().toISOString();
    await mkdir(new URL('../artifacts/', import.meta.url), { recursive: true });
    await writeFile(new URL('../artifacts/live-logo-report.json', import.meta.url), `${JSON.stringify(report, null, 2)}\n`);
    console.log(JSON.stringify({ status: report.status, channels: report.channels, withLogo: report.channelsWithLogo, withoutLogo: report.channelsWithoutLogo, uniqueImages: report.resources.length, failed: report.resources.filter((item) => item.status === 'failed').length }));
  }
});

function validImagePrefix(bytes, contentType) {
  const data = Buffer.from(bytes);
  if (/^image\/png(?:;|$)/iu.test(contentType)) return data.length >= 24 && data.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) && data.readUInt32BE(16) > 0 && data.readUInt32BE(20) > 0;
  if (/^image\/jpeg(?:;|$)/iu.test(contentType)) return data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff;
  if (/^image\/gif(?:;|$)/iu.test(contentType)) return ['GIF87a', 'GIF89a'].includes(data.subarray(0, 6).toString('ascii'));
  if (/^image\/webp(?:;|$)/iu.test(contentType)) return data.subarray(0, 4).toString('ascii') === 'RIFF' && data.subarray(8, 12).toString('ascii') === 'WEBP';
  return false;
}
