/** 聚合回归：跨仓库频道身份、误合并边界、独立失效缓存与真实备用选择；全部使用离线公开 HTTP fixture。 */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { parsePlaylist } from '../dist/playlist.mjs';
import { mergePlaylists } from '../dist/merge.mjs';
import { createPlaylistStore, playlistProviders } from '../dist/store.mjs';
import { createPlaybackResolver } from '../dist/playback.mjs';
import { contextFixture, hlsManifest } from './fixtures.mjs';

const m3u = (entries) => '#EXTM3U\n' + entries.map(([title, path, attrs = '']) => `#EXTINF:-1 ${attrs},${title}\nhttps://media.example/${path}\n`).join('');
const source = (index, entries) => ({ provider: playlistProviders[index], playlist: parsePlaylist(m3u(entries)) });
const sources = () => [
  source(0, [['CCTV-1综合', 'original.m3u8?token=secret', 'group-title="央视频道"']]),
  source(1, [['CCTV-1 (1080p)', 'denied.m3u8', 'tvg-id="CCTV1.cn@HD"'], ['CCTV-1', 'shared.m3u8?token=fresh', 'tvg-id="CCTV1.cn@SD"']]),
  source(2, [['CCTV1高清', 'yue.m3u8', 'group-title="地方频道"']]),
  source(3, [['CCTV-1 综合', 'shared.m3u8?token=stale', 'tvg-id="CCTV1.cn" group-title="China"']]),
];

test('same channel across all providers keeps the original ID, deduplicates lines and retains every provider', () => {
  const input = sources(), merged = mergePlaylists(input);
  assert.equal(merged.channels.length, 1);
  const channel = merged.channels[0];
  assert.equal(channel.id, input[0].playlist.channels[0].id);
  assert.equal(channel.streams.length, 4);
  assert.deepEqual(new Set(channel.streams.flatMap((stream) => stream.providers)), new Set(['zhi35', 'iptv-org', 'YueChan', 'Free-TV']));
  const shared = channel.streams.find((stream) => stream.url.includes('shared'));
  assert.deepEqual(shared.providers, ['iptv-org', 'Free-TV']);
  assert.match(shared.url, /token=fresh/u);
  assert.equal(merged.channels[0].title, 'CCTV-1综合');
  assert.equal(input[1].playlist.channels[0].streams[0].providers, undefined, 'never mutate provider snapshots');
  assert.equal(mergePlaylists(input.slice().reverse()).channels[0].id, channel.id);
});

test('EPG quality suffixes merge while plus, regional, UHD and generic-name channels remain distinct', () => {
  const merged = mergePlaylists([
    source(0, [['CCTV-5体育', 'sports.m3u8'], ['CCTV-5+体育赛事', 'sportsplus.m3u8'], ['CCTV-4中文国际', 'asia.m3u8'], ['新闻综合', 'city-a.m3u8']]),
    source(1, [['CCTV-5 (1080p)', 'sports-new.m3u8', 'tvg-id="CCTV5.cn@HD"'], ['CCTV-5+', 'plus-new.m3u8', 'tvg-id="CCTV5Plus.cn@SD"'], ['CCTV-4 Europe', 'europe.m3u8', 'tvg-id="CCTV4Europe.cn"'], ['CCTV-4K', 'uhd.m3u8', 'tvg-id="CCTV4K.cn"'], ['新闻综合', 'city-b.m3u8']]),
    source(3, [['CCTV-4 中文国际（亚）', 'asia-new.m3u8', 'tvg-id="CCTV4Asia.cn" group-title="China"'], ['ABC', 'us.m3u8', 'group-title="United States"'], ['ABC', 'au.m3u8', 'group-title="Australia"']]),
  ]);
  assert.equal(merged.channels.length, 9);
  assert.equal(merged.channels.find((channel) => channel.title === 'CCTV-5体育').streams.length, 2);
  assert.equal(merged.channels.find((channel) => channel.title === 'CCTV-5+体育赛事').streams.length, 2);
  assert.equal(merged.channels.find((channel) => channel.title === 'CCTV-4中文国际').streams.length, 2);
  assert.equal(merged.channels.filter((channel) => channel.title === '新闻综合').length, 2);
  assert.equal(merged.channels.filter((channel) => channel.title === 'ABC').length, 2);
  assert.equal(new Set(merged.channels.map((channel) => channel.id)).size, merged.channels.length);
});

test('provider-local EPG IDs cannot collide and a new canonical EPG ID survives reordering', () => {
  const input = [source(1, [['CCTV-1', 'hd.m3u8', 'tvg-id="CCTV1.cn@HD"'], ['CCTV-1 (720p)', 'sd.m3u8', 'tvg-id="CCTV1.cn@SD"'], ['Local One', 'one.m3u8', 'tvg-id="local"']]), source(2, [['Local Two', 'two.m3u8', 'tvg-id="local"']])];
  const first = mergePlaylists(input);
  assert.equal(first.channels.length, 3);
  assert.equal(new Set(first.channels.map((channel) => channel.id)).size, 3);
  input[0].playlist.channels.reverse();
  assert.deepEqual(new Set(mergePlaylists(input).channels.map((channel) => channel.id)), new Set(first.channels.map((channel) => channel.id)));
});

test('a visually verified mislabeled CCTV1 resource is excluded only from the incorrect channel', () => {
  const wrong = source(1, [['CCTV-1', 'wrong.m3u8']]);
  wrong.playlist.channels[0].streams[0].id = 'stream:4b60b42947402afdf4f89c3d';
  const actual = source(2, [['花垣综合', 'wrong.m3u8']]);
  actual.playlist.channels[0].streams[0].id = 'stream:4b60b42947402afdf4f89c3d';
  const merged = mergePlaylists([sources()[0], wrong, actual]);
  assert.equal(merged.channels.length, 2);
  assert.equal(merged.channels.find((channel) => channel.title === 'CCTV-1综合').streams.length, 1);
  assert.equal(merged.channels.find((channel) => channel.title === '花垣综合').streams.length, 1);
  assert.equal(wrong.playlist.channels[0].streams.length, 1);
});

test('failed providers retain only their own bounded snapshot while healthy providers continue updating', async () => {
  let time = 0, broken = false, generation = 0, calls = 0;
  const definitions = playlistProviders.slice(0, 2);
  const fixture = contextFixture(async (url) => {
    calls += 1;
    if (url.includes('iptv-org')) return new Response(m3u([['CCTV-1', `new.m3u8?token=${generation}`, 'tvg-id="CCTV1.cn"']]));
    return broken ? new Response(null, { status: 503 }) : new Response(m3u([['CCTV-1综合', 'original.m3u8']]));
  }, { additionalProviders: true });
  const store = createPlaylistStore(fixture.context, () => time, definitions);
  const initial = await store.load();
  broken = true; generation = 1; time = 300_000;
  const updated = await store.load();
  assert.equal(updated.channels[0].id, initial.channels[0].id);
  assert.equal(updated.channels[0].streams.length, 2);
  assert.ok(updated.channels[0].streams.some((stream) => stream.url.includes('token=1')));
  assert.match(updated.notice, /zhi35/u);
  const count = calls;
  assert.equal(await store.load(), updated);
  assert.equal(calls, count, 'failed providers have a bounded retry interval');
  time = 24 * 60 * 60_000;
  const expired = await store.load();
  assert.equal(expired.channels[0].streams.length, 1);
  assert.equal(expired.channels[0].streams[0].providers[0], 'iptv-org');
});

test('automatic entry skips failed HLS, remembers success, and explicit selection never changes lines', async () => {
  const channel = mergePlaylists(sources()).channels[0], requests = [];
  const fixture = contextFixture(async (url) => { requests.push(url); return new Response(url.includes('shared') ? hlsManifest : 'Forbidden', { status: url.includes('shared') ? 200 : 403 }); });
  const playback = createPlaybackResolver(fixture.context);
  const media = await playback.resolve(channel);
  assert.match(media.url, /shared/u);
  assert.equal(requests.length, 3);
  requests.length = 0;
  await playback.resolve(channel);
  assert.equal(requests.length, 1);
  await assert.rejects(playback.resolve(channel, channel.streams[0]), (error) => error.code === 'source_access_blocked');
  assert.equal(requests.length, 2, 'manual selection attempted exactly its selected address');
  assert.ok(fixture.logs.every((record) => !record.event.includes('secret') && !record.event.includes('media.example')));
});

test('automatic selection bounds the candidate count and sanitizes the final error', async () => {
  const channel = source(1, [['CCTV-1', 'empty.m3u8']]).playlist.channels[0];
  channel.streams = Array.from({ length: 12 }, (_, index) => ({ id: `stream:${index}`, url: `https://media.example/${index}.m3u8?token=secret`, ipv6: false }));
  let calls = 0;
  const playback = createPlaybackResolver(contextFixture(async () => { calls += 1; return new Response(null, { status: 403 }); }).context);
  await assert.rejects(playback.resolve(channel), (error) => {
    assert.equal(error.code, 'source_media_resolution_failed');
    assert.match(error.message, /8 次/u);
    assert.ok(!`${error.message}${error.annotation}`.includes('secret'));
    return true;
  });
  assert.equal(calls, 8);
});

test('the explicit automatic route tries direct and preserves it in the Runtime media descriptor', async () => {
  const list = m3u([['CCTV-1综合', 'denied.m3u8'], ['CCTV-1', 'direct-only.m3u8']]);
  const requests = [];
  const fixture = contextFixture(async (url, init) => {
    if (new URL(url).pathname.endsWith('.m3u')) return new Response(list);
    requests.push({ url, proxyMode: init.proxyMode });
    const good = url.includes('direct-only') && init.proxyMode === 'direct';
    return new Response(good ? hlsManifest : 'Forbidden', { status: good ? 200 : 403 });
  });
  await plugin.activate(fixture.context);
  const { items } = await plugin.search({ query: 'CCTV1', cursor: null, pageSize: 20 });
  const catalog = await plugin.getChapters({ id: items[0].id });
  assert.match(catalog.groups[0].title, /含直连/u);
  await plugin.getContent({ id: items[0].id, chapterId: catalog.items[0].id });
  assert.equal(requests.length, 4);
  assert.equal(fixture.resources.at(-1).proxyMode, 'direct');
  requests.length = 0;
  await plugin.getContent({ id: items[0].id, chapterId: catalog.items[0].id });
  assert.equal(requests.length, 1);
  assert.equal(requests[0].proxyMode, 'direct');
  assert.equal(fixture.resources.at(-1).proxyMode, 'direct');
});

test('the plugin exposes automatic and labelled manual groups, searches aliases and resolves legacy IDs', async () => {
  const input = sources();
  const fixture = contextFixture(async (url) => {
    const index = playlistProviders.findIndex((provider) => provider.urls.includes(url));
    if (index >= 0) return new Response(m3u([
      ...input[index].playlist.channels.flatMap((channel) => channel.streams.map((stream) => [channel.title, stream.url.replace('https://media.example/', ''), `${channel.epgId ? `tvg-id="${channel.epgId}"` : ''} group-title="${channel.categories[0]}"`])),
    ]));
    return new Response(url.includes('shared') ? hlsManifest : 'Forbidden', { status: url.includes('shared') ? 200 : 403 });
  }, { additionalProviders: true });
  await plugin.activate(fixture.context);
  const result = await plugin.search({ query: 'CCTV1', cursor: null, pageSize: 20 });
  assert.equal(result.totalCount, 1);
  const id = result.items[0].id;
  assert.equal(id, input[0].playlist.channels[0].id);
  const catalog = await plugin.getChapters({ id });
  assert.equal(catalog.groups.length, 5);
  assert.equal(catalog.groups[0].title, '自动线路（含直连）');
  assert.deepEqual(catalog.groups.flatMap((group) => group.episodes), catalog.items);
  assert.ok(catalog.groups.some((group) => group.title.includes('iptv-org / Free-TV')));
  const content = await plugin.getContent({ id, chapterId: catalog.items[0].id });
  assert.equal(content.chapterId, catalog.items[0].id);
  assert.match(fixture.resources.at(-1).url, /shared/u);
  const legacy = input[1].playlist.channels.find((channel) => channel.streams.some((stream) => stream.url.includes('shared')));
  assert.equal((await plugin.getDetail({ id: legacy.id })).id, id);
  const oldChapter = `${legacy.id}:${legacy.streams[0].id}`;
  assert.equal((await plugin.getContent({ id: legacy.id, chapterId: oldChapter })).chapterId, oldChapter);
});
