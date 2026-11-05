/** Real loopback integration with synthetic media; preserves routing and Range. */
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { PluginManager } from '../dist/index.js';
import { serveSourceResource } from '../dist/loopback-resources.js';
import { decodeSourceResourceUrl } from '../dist/source-resource-token.js';
import { filterSourceHlsResource } from '../dist/hls-ad-filter.js';
import { makeFixture, rules, transportPrefix } from './helpers/hls-ad-fixtures.mjs';

test('proxy inherits source policy into variants, filters before URL rewriting, and leaves binary Range intact', async t => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-hls-ad-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const fixture = makeFixture(), calls = [];
  const manager = new PluginManager(root, { http: { async fetch(input, init, _deadline, proxyMode) {
    const url = String(input); calls.push({ url, headers: init.headers, proxyMode });
    const master = url.endsWith('/master.m3u8');
    const manifest = url.endsWith('.m3u8');
    const range = init.headers.range;
    const body = manifest ? master ? '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nstream.m3u8\n' : fixture.text
      : transportPrefix(fixture.clocks.get(url)?.pts ?? 1.48);
    const response = new Response(body, { status: range ? 206 : 200, headers: {
      'content-type': manifest ? 'application/vnd.apple.mpegurl' : 'video/mp2t',
      ...(range ? { 'content-range': `bytes 0-${body.length - 1}/${body.length}` } : {}),
    } });
    Object.defineProperty(response, 'url', { value: url }); return response;
  } } });
  const server = createServer((request, response) => { void serveSourceResource(manager,
    new URL(request.url, 'http://localhost').pathname.split('/').at(-1), response, () => {}, request); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  manager.setResourceOrigin(`http://127.0.0.1:${server.address().port}`);
  const input = { kind: 'hls', url: new URL('master.m3u8', fixture.base).href,
    proxyMode: 'direct', headers: { Referer: 'https://source.example/watch' }, hlsAdFilter: rules };
  const master = await (await fetch(manager.createResourceUrl('org.example.video', input))).text();
  const child = master.split('\n').find(line => line.startsWith('http'));
  assert.deepEqual(decodeSourceResourceUrl(child).request.hlsAdFilter, rules);
  const filtered = await (await fetch(child)).text();
  const urls = filtered.split('\n').filter(line => line.startsWith('http'));
  assert.equal(urls.length, fixture.originals.length);
  assert.ok(urls.every(url => decodeSourceResourceUrl(url).request.hlsAdFilter === undefined));
  assert.ok(urls.every(url => fixture.clocks.has(decodeSourceResourceUrl(url).request.url)));
  assert.ok(!urls.some(url => decodeSourceResourceUrl(url).request.url.includes('/different/')));
  const probes = calls.filter(call => call.headers.range === 'bytes=0-65535');
  assert.equal(probes.length, 3);
  assert.ok(probes.every(call => call.proxyMode === 'direct' && call.headers.Referer === 'https://source.example/watch'));
  const binary = await fetch(urls[0], { headers: { Range: 'bytes=0-0' } });
  assert.equal(binary.status, 206); await binary.body.cancel();
  assert.equal(calls.at(-1).headers.range, 'bytes=0-0');
  const original = await (await fetch(manager.createResourceUrl('org.example.video', { ...input, hlsAdFilter: null, url: fixture.base }))).text();
  assert.equal(original.split('\n').filter(line => line.startsWith('http')).length, fixture.originals.length + fixture.inserted.length);
});

test('aborting a probe cancels all pending response readers', async () => {
  const fixture = makeFixture(), controller = new AbortController(); let cancelled = 0;
  const request = { kind: 'hls', url: fixture.base, headers: {}, hlsAdFilter: rules };
  const entry = { request, proxy: () => '', fetch: async () => new Response(new ReadableStream({
    start(stream) { stream.enqueue(new Uint8Array([0x47])); }, cancel() { cancelled += 1; },
  })) };
  const resource = { request, proxy: entry.proxy, response: new Response(fixture.text), responseUrl: fixture.base };
  const pending = filterSourceHlsResource(resource, entry, controller.signal);
  setTimeout(() => controller.abort(), 20);
  await assert.rejects(pending, { name: 'AbortError' });
  assert.equal(cancelled, 3);
});
