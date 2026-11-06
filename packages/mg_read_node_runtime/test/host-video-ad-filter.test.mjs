/** Host fallback and opt-out through resolve, real loopback HLS and binary IO. */
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { PluginManager } from '../dist/index.js';
import { applyHostVideoAdFilter, defaultVideoAdFilter } from '../dist/host-video-ad-filter.js';
import { dispatchSourceResourceResolve } from '../dist/desktop-source-control-dispatch.js';
import { serveSourceResource } from '../dist/loopback-resources.js';
import { decodeSourceResourceUrl } from '../dist/source-resource-token.js';
import { makeFixture, rules, transportPrefix } from './helpers/hls-ad-fixtures.mjs';

test('host fallback needs no source opt-in and valid source thresholds remain preferred', () => {
  const request = { kind: 'hls', url: 'https://media.example/stream.m3u8', headers: {} };
  const automatic = applyHostVideoAdFilter(request, true);
  assert.deepEqual(automatic.hlsAdFilter, defaultVideoAdFilter);
  assert.equal(request.hlsAdFilter, undefined, 'Resolving must not mutate saved source descriptors');
  const sourcePolicy = { ...rules, maximumInterstitialSeconds: 45 };
  assert.deepEqual(applyHostVideoAdFilter({ ...request, hlsAdFilter: sourcePolicy }, true).hlsAdFilter, sourcePolicy);
  assert.deepEqual(applyHostVideoAdFilter({ ...request, hlsAdFilter: {} }, true).hlsAdFilter, defaultVideoAdFilter);
});

test('host disable clears source filtering; non-video callers and binary resources retain their descriptor', () => {
  const input = { kind: 'hls', url: 'https://media.example/stream.m3u8', hlsAdFilter: rules };
  assert.equal(applyHostVideoAdFilter(input, false).hlsAdFilter, undefined);
  assert.equal(applyHostVideoAdFilter(input, undefined), input);
  for (const kind of ['image', 'video', 'audio']) {
    const request = { kind, url: 'https://media.example/resource', resourceRole: 'hlsMedia' };
    assert.equal(applyHostVideoAdFilter(request, true), request);
    assert.equal(applyHostVideoAdFilter(request, false), request);
  }
});

test('resolve rejects non-boolean preference and unknown fields before opening an owner', async () => {
  const requestError = (_request, code, message) => ({ code, message });
  for (const params of [{ url: 'invalid', filterVideoAds: 'yes' }, { url: 'invalid', filterVideoAds: null },
    { url: 'invalid', filterVideoAds: true, extra: true }]) {
    const result = await dispatchSourceResourceResolve({ params }, undefined, requestError);
    assert.equal(result.error.code, 'invalid_request');
  }
});

test('a source without ad rules is filtered after host resolve; disabling restores every original URI', async t => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-host-hls-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const fixture = makeFixture();
  const calls = [];
  const manager = new PluginManager(root, { http: { async fetch(input, init, _deadline, proxyMode) {
    const url = String(input); calls.push({ url, headers: init.headers, proxyMode });
    const manifest = url.endsWith('.m3u8');
    const master = url.endsWith('/master.m3u8');
    const body = manifest ? master ? '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nstream.m3u8\n' : fixture.text
      : transportPrefix(fixture.clocks.get(url)?.pts ?? 1.48);
    const range = init.headers.range;
    const response = new Response(body, { status: range ? 206 : 200, headers: {
      'content-type': manifest ? 'application/vnd.apple.mpegurl' : 'video/mp2t',
      ...(range ? { 'content-range': `bytes 0-${body.length - 1}/${body.length}` } : {}),
    } });
    Object.defineProperty(response, 'url', { value: url });
    return response;
  } } });
  const server = createServer((request, response) => { void serveSourceResource(manager,
    new URL(request.url, 'http://localhost').pathname.split('/').at(-1), response, () => {}, request); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  manager.setResourceOrigin(`http://127.0.0.1:${server.address().port}`);
  const owner = { listInstalled: async () => [{ id: 'org.example.video', enabled: true }],
    createResourceUrl: manager.createResourceUrl.bind(manager) };
  const resolve = async (url, enabled) => {
    const result = await dispatchSourceResourceResolve({ params: { url, filterVideoAds: enabled } }, owner,
      (_request, code, message) => ({ code, message }));
    assert.equal(result.error, undefined);
    return result.result.url;
  };
  const input = { kind: 'hls', url: new URL('master.m3u8', fixture.base).href,
    headers: { Referer: 'https://source.example/watch' }, proxyMode: 'direct' };
  const saved = manager.createResourceUrl('org.example.video', input);
  const enabledUrl = await resolve(saved, true);
  assert.deepEqual(decodeSourceResourceUrl(enabledUrl).request.hlsAdFilter, defaultVideoAdFilter);
  const master = await (await fetch(enabledUrl)).text();
  const child = master.split('\n').find(line => line.startsWith('http'));
  assert.deepEqual(decodeSourceResourceUrl(child).request.hlsAdFilter, defaultVideoAdFilter);
  const filtered = await (await fetch(child)).text();
  const urls = filtered.split('\n').filter(line => line.startsWith('http'));
  assert.equal(urls.length, fixture.originals.length);
  assert.ok(urls.every(url => fixture.originals.some(uri => new URL(uri, fixture.base).href === decodeSourceResourceUrl(url).request.url)));
  const probes = calls.filter(call => call.headers.range === 'bytes=0-65535');
  assert.equal(probes.length, 3);
  assert.ok(probes.every(call => call.proxyMode === 'direct' && call.headers.Referer === input.headers.Referer));
  const binary = await fetch(urls[0], { headers: { Range: 'bytes=0-0' } });
  assert.equal(binary.status, 206);
  await binary.body.cancel();
  assert.equal(calls.at(-1).headers.range, 'bytes=0-0');
  const beforeDisable = calls.filter(call => call.headers.range === 'bytes=0-65535').length;
  const originalUrl = await resolve(child, false);
  const original = await (await fetch(originalUrl)).text();
  assert.equal(original.split('\n').filter(line => line.startsWith('http')).length, fixture.originals.length + fixture.inserted.length);
  assert.equal(calls.filter(call => call.headers.range === 'bytes=0-65535').length, beforeDisable);
});
