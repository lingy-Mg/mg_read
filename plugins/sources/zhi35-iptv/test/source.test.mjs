/** 离线来源契约：真实结构 fixture、身份稳定、分页边界、缓存生命周期与资源描述；不访问互联网。 */
import assert from 'node:assert/strict';
import test from 'node:test';
import { collectDiscoveryContent, collectDiscoveryContinuations, collectDiscoveryTargets } from '@mgread/source-testkit';
import * as plugin from '../dist/index.mjs';
import { parsePlaylist, safeHttpUrl } from '../dist/playlist.mjs';
import { createPlaylistStore, playlistUrls } from '../dist/store.mjs';
import { resolveMedia } from '../dist/media.mjs';
import { playlist, hlsManifest, contextFixture, discoveryRequest } from './fixtures.mjs';

test('M3U preserves names, missing metadata, IPv6 and distinct CCTV5 channels', () => {
  const result = parsePlaylist(playlist);
  assert.equal(result.channels.length, 5);
  assert.equal(result.channels[0].title, 'CCTV-5体育');
  assert.notEqual(result.channels[0].id, result.channels[1].id);
  assert.equal(result.channels[0].streams[0].ipv6, true);
  assert.equal(result.channels[2].streams.length, 2);
  assert.equal(result.channels[3].title, '❌ 风景,全景');
  assert.equal(result.channels[3].cover, null);
});

test('reordering, renaming and expiring authorization do not change resource identities', () => {
  const original = parsePlaylist(playlist);
  const changed = parsePlaylist(playlist.replaceAll('first', 'refreshed').replace('CCTV-5体育', '新版频道名'));
  assert.deepEqual(changed.channels.map((item) => item.id), original.channels.map((item) => item.id));
  assert.deepEqual(changed.channels.map((item) => item.streams.map((line) => line.id)), original.channels.map((item) => item.streams.map((line) => line.id)));
  assert.match(changed.channels[0].streams[0].url, /accountinfo=refreshed/u);
  assert.notEqual(changed.revision, original.revision);
  assert.equal(parsePlaylist(playlist.replaceAll('first', 'refreshed')).revision, original.revision);
  const entries = playlist.split(/(?=#EXTINF:)/u).slice(1).reverse().join('');
  assert.deepEqual(new Set(parsePlaylist(entries).channels.map((item) => item.id)), new Set(original.channels.map((item) => item.id)));
  const queryIds = parsePlaylist('#EXTINF:-1,One\nhttps://media.example/live.php?id=1\n#EXTINF:-1,Two\nhttps://media.example/live.php?id=2');
  assert.equal(queryIds.channels.length, 2);
});

test('invalid entries and unsafe resources are excluded without consuming the following entry', () => {
  const result = parsePlaylist(`${playlist}
#EXTINF:-1 group-title='额外,分类' tvg-logo='file:///private.png',Extra
https://media.example/extra.m3u8
#EXTINF:-1,Unsafe
http://127.0.0.1/private
#EXTINF:-1,Unsafe scheme
javascript:alert(1)
#EXTINF:-1,Missing stream
#EXTINF:-1 group-title="新增",Valid
https://media.example/valid.m3u8
`);
  assert.equal(result.channels.length, 7);
  assert.equal(result.channels[5].categories[0], '额外,分类');
  assert.equal(result.channels[5].cover, null);
  assert.throws(() => parsePlaylist('<html>denied</html>'), /没有有效频道/u);
  for (const url of ['file:///x', 'https://user:secret@site.example/live', 'http://localhost/x', 'http://10.0.0.1/live', 'http://[::1]/x', 'http://[::ffff:127.0.0.1]/x']) assert.equal(safeHttpUrl(url), null);
});

test('discovery/search paginate the same channels and reject cross-list cursors', async () => {
  let requests = 0;
  const fixture = contextFixture(async () => { requests += 1; return new Response(playlist); });
  await plugin.activate(fixture.context);
  const root = await plugin.discover(discoveryRequest);
  assert.equal(collectDiscoveryTargets(root).length, 5);
  const first = collectDiscoveryContent(root);
  const continuation = collectDiscoveryContinuations(root)[0];
  const second = await plugin.discover({ ...discoveryRequest, ...continuation });
  assert.equal(second.kind, 'append');
  const last = await plugin.discover({ ...discoveryRequest, ...collectDiscoveryContinuations(second)[0] });
  const all = [...first, ...collectDiscoveryContent(second), ...collectDiscoveryContent(last)];
  assert.equal(all.length, 5);
  assert.equal(new Set(all.map((item) => item.id)).size, 5);
  assert.equal(last.continuation, null);
  const search = await plugin.search({ query: '频道', cursor: null, pageSize: 2 });
  assert.equal(search.totalCount, 4);
  const tail = await plugin.search({ query: '频道', cursor: search.nextCursor, pageSize: 2 });
  assert.equal(tail.items.length, 2);
  assert.equal(tail.nextCursor, null);
  const exact = await plugin.search({ query: first[0].title, cursor: null, pageSize: 10 });
  assert.equal(exact.items[0].id, first[0].id);
  await assert.rejects(plugin.search({ query: '卫视', cursor: search.nextCursor, pageSize: 2 }), /游标/u);
  await assert.rejects(plugin.discover({ ...discoveryRequest, target: 'unknown' }), /分类/u);
  await assert.rejects(plugin.discover({ ...discoveryRequest, ...continuation, collectionId: 'other' }), /标识/u);
  await assert.rejects(plugin.discover({ ...discoveryRequest, ...continuation, pageSize: 3 }), /游标/u);
  assert.deepEqual(await plugin.searchSuggestions({ cursor: null, pageSize: 10 }), { items: [], nextCursor: null });
  assert.equal(requests, 1);
});

test('catalog lines map one-to-one to episodes; content refresh preserves authorization and validates ownership', async () => {
  let latest = playlist;
  const fixture = contextFixture(async (url) => new Response(new URL(url).pathname.endsWith('.m3u8') ? hlsManifest : latest));
  await plugin.activate(fixture.context);
  const search = await plugin.search({ query: '测试卫视', cursor: null, pageSize: 20 });
  const id = search.items[0].id;
  const catalog = await plugin.getChapters({ id });
  assert.equal(catalog.items.length, 2);
  assert.deepEqual(catalog.groups.flatMap((group) => group.episodes), catalog.items);
  assert.match(catalog.groups[1].title, /IPv6/u);
  latest = playlist.replaceAll('first', 'renewed');
  const content = await plugin.getContent({ id, chapterId: catalog.items[0].id });
  assert.equal(content.media.resourceType, 'hls');
  assert.equal(content.media.resourcePolicy, 'sessionOnly');
  assert.equal(content.media.expiresAt, null);
  assert.equal(content.text, null);
  assert.deepEqual(content.pages, []);
  assert.match(fixture.resources.at(-1).url, /token=renewed/u);
  assert.equal(fixture.resources.at(-1).headers.Cookie, undefined);
  await assert.rejects(plugin.getContent({ id, chapterId: 'channel:other:stream:other' }), /线路/u);
  await assert.rejects(plugin.getDetail({ id: 'https://media.example/live' }), /标识/u);
  const local = await plugin.search({ query: '地方电视', cursor: null, pageSize: 10 });
  const localChapters = await plugin.getChapters({ id: local.items[0].id });
  assert.equal((await plugin.getContent({ id: local.items[0].id, chapterId: localChapters.items[0].id })).media.resourceType, 'video');
  assert.ok(fixture.logs.every((record) => !record.event.includes('http') && !record.event.includes('renewed')));
});

test('playlist fetch is single-flight, falls back on invalid acceleration response, and retries failures', async () => {
  const requested = [];
  const fixture = contextFixture(async (url) => {
    requested.push(url);
    return new Response(url === playlistUrls[0] ? '<html>error</html>' : playlist);
  });
  const store = createPlaylistStore(fixture.context);
  const result = await Promise.all([store.load(), store.load(), store.load(true)]);
  assert.equal(result[0], result[1]);
  assert.deepEqual(requested, playlistUrls);
  let failures = 0;
  const failing = createPlaylistStore(contextFixture(async () => { failures += 1; return new Response('', { status: 503 }); }).context);
  await assert.rejects(failing.load(), /暂时无法获取/u);
  await assert.rejects(failing.load(), /暂时无法获取/u);
  assert.equal(failures, 4);
});

test('cached list has bounded TTL and stale lifetime; failed refresh does not extend freshness', async () => {
  let time = 0, offline = false, requests = 0;
  const fixture = contextFixture(async () => {
    requests += 1;
    if (offline) throw new Error('offline');
    return new Response(playlist);
  });
  const store = createPlaylistStore(fixture.context, () => time);
  const original = await store.load();
  time = 299_999;
  assert.equal(await store.load(), original);
  assert.equal(requests, 1);
  time = 300_000;
  offline = true;
  assert.equal(await store.load(), original);
  assert.equal(requests, 3);
  assert.equal(await store.load(), original);
  assert.equal(requests, 5);
  time = 24 * 60 * 60_000;
  await assert.rejects(store.load(), /暂时无法获取/u);
});

test('oversized list cancels the response and can recover from the repository fallback', async () => {
  let cancelled = false;
  const fixture = contextFixture(async (url) => url === playlistUrls[0] ? new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(2 * 1024 * 1024 + 1)); },
    cancel() { cancelled = true; },
  })) : new Response(playlist));
  assert.equal((await createPlaylistStore(fixture.context).load()).channels.length, 5);
  assert.equal(cancelled, true);
});

test('new activation cannot reuse or be overwritten by an old activation request', async () => {
  let finish;
  await plugin.activate(contextFixture(() => new Promise((resolve) => { finish = resolve; })).context);
  const old = plugin.discover(discoveryRequest);
  await plugin.activate(contextFixture(async () => new Response(playlist.replace('CCTV-5体育', '新实例'))).context);
  assert.equal(collectDiscoveryContent(await plugin.discover(discoveryRequest))[0].title, '新实例');
  finish(new Response(playlist));
  await old;
  assert.equal(collectDiscoveryContent(await plugin.discover(discoveryRequest))[0].title, '新实例');
});

test('unknown-extension media uses bounded sniffing, follows the real redirect URL, and cancels', async () => {
  let cancelled = false;
  const fixture = contextFixture(async (_url, init) => {
    assert.equal(init.headers.Range, 'bytes=0-1023');
    const response = new Response(new ReadableStream({
      start(controller) { controller.enqueue(Buffer.from('#EXTM3U\n#EXTINF:6,\nsegment.ts\n')); },
      cancel() { cancelled = true; },
    }));
    Object.defineProperty(response, 'url', { value: 'https://media.example/actual/index.m3u8?token=preserved' });
    return response;
  });
  const media = await resolveMedia(fixture.context, 'https://media.example/live.php?id=1');
  assert.equal(media.resourceType, 'hls');
  assert.equal(media.url, 'https://media.example/actual/index.m3u8?token=preserved');
  assert.equal(cancelled, true);
  await assert.rejects(resolveMedia(contextFixture(async () => new Response('<html>Error</html>', { headers: { 'content-type': 'text/html' } })).context, 'https://media.example/play'), /可识别/u);
});

test('known HLS validates playlist metadata, cancels immediately, and keeps the original refreshable address', async () => {
  let cancelled = false;
  const url = 'https://media.example/live.m3u8?token=preserved';
  const fixture = contextFixture(async (input, init) => {
    assert.equal(input, url);
    assert.equal(init.proxyMode, undefined);
    const response = new Response(new ReadableStream({
      start(controller) { controller.enqueue(Buffer.from(hlsManifest)); },
      cancel() { cancelled = true; },
    }));
    Object.defineProperty(response, 'url', { value: 'https://media.example/session.m3u8?token=temporary' });
    return response;
  });
  const media = await resolveMedia(fixture.context, url, '测试直播');
  assert.equal(media.url, url);
  assert.equal(media.resourceType, 'hls');
  assert.equal(cancelled, true);
});

test('upstream access denial is a public source error with the channel title and no upstream secrets', async () => {
  const fixture = contextFixture(async () => new Response('Forbidden', { status: 403 }));
  await assert.rejects(resolveMedia(fixture.context, 'https://media.example/live.m3u8?token=secret', 'CCTV-1综合'), (error) => {
    assert.equal(error.code, 'source_access_blocked');
    assert.match(error.message, /CCTV-1综合.*HTTP 403/u);
    assert.ok(!`${error.message}${error.annotation}`.includes('secret'));
    assert.ok(!`${error.message}${error.annotation}`.includes('media.example'));
    return true;
  });
});

test('IPv6 HTTP 502 is reported before player open instead of registering an unusable resource', async () => {
  const fixture = contextFixture(async () => new Response(null, { status: 502 }));
  await assert.rejects(resolveMedia(fixture.context, 'http://[2409:8087:8:21::18]:6610/live.m3u8', 'CCTV-1综合'), (error) => {
    assert.equal(error.code, 'source_media_resolution_failed');
    assert.match(error.message, /HTTP 502/u);
    assert.match(error.annotation, /IPv6/u);
    return true;
  });
  assert.equal(fixture.resources.length, 0);
});

test('HTML or IPTV lists with a misleading HLS extension are rejected by the source', async () => {
  for (const body of ['<html>unavailable</html>', playlist]) {
    const fixture = contextFixture(async () => new Response(body, { headers: { 'content-type': 'application/vnd.apple.mpegurl' } }));
    await assert.rejects(resolveMedia(fixture.context, 'https://media.example/live.m3u8'), (error) => error.code === 'source_media_resolution_failed' && error.message.includes('HLS'));
  }
});

test('HLS connection failures are bounded public errors without exposing request context', async () => {
  const fixture = contextFixture(async () => { throw new Error('connect failed https://media.example/private?token=secret'); });
  await assert.rejects(resolveMedia(fixture.context, 'https://media.example/live.m3u8'), (error) => {
    assert.equal(error.code, 'source_media_resolution_failed');
    assert.match(error.message, /连接失败或超时/u);
    assert.ok(!error.message.includes('secret'));
    return true;
  });
});
