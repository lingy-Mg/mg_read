/** Minimal protocol fixtures: paging, identities, complete catalogs, provider routing and resources. */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {setImmediate} from 'node:timers/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import {createSourceTestHarness, collectDiscoveryContent, collectDiscoveryContinuations, collectDiscoveryTargets} from '../../../../packages/mg_read_source_testkit/index.js';
const pkg = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
const shiyin = pkg.mgread.id.endsWith('shiyin-audio');
const book = id => ({id, book_id: String(id), title: '专辑' + id, author: '作者', teller: '演播', status: 0, count: 3, cover_url: 'https://file.tingyou8.vip/pic/test.jpg'});
const items = Array.from({length: 8}, (_, i) => book(100 + i));
const chapters = [
  {id: 71, index: 5, title: '主题曲', duration: 30},
  {id: 75, index: 9, title: '正文一', duration: 900},
  {id: 79, index: 16, title: '正文二', duration: 0},
];
async function setup(t, options = {}) {
  const calls = [], state = {chapters: structuredClone(chapters), ...options};
  const harness = await createSourceTestHarness({plugin, pluginId: pkg.mgread.id, version: pkg.version, fetch: async (input, init = {}) => {
    const u = new URL(String(input)), body = init.body ? JSON.parse(init.body) : null;
    calls.push({u, init, body});
    const reply = value => Response.json(value);
    if (u.hostname === 'api.365ting.com') {
      if (u.pathname.includes('/api/audio/')) {
        assert.equal(init.method, 'HEAD');
        return new Response(null, {status: state.audioFailure ? 502 : 200});
      }
      if (state.primaryFailure) return new Response('error', {status: 503});
      if (u.pathname === '/tingyou-app/search') {
        const q = u.searchParams.get('keyword'), page = Number(u.searchParams.get('page'));
        if (state.pageFailure && page % 2 === 0) return new Response('error', {status: 503});
        if (/^\d+$/u.test(q)) return reply({code: 200, data: {items: [{...book(Number(q)), album_id: state.local ? 12 : 0}], has_more: false}});
        return reply({code: 200, data: {items: page % 2 === 1 ? items : [{...items[0], album_id: 12}], has_more: state.firstHasMore && page === 1}});
      }
      if (u.pathname.includes('/tracks')) {
        if (state.localFailure) return new Response('failed', {status: 503});
        return reply({code: 200, data: state.chapters.map(v => ({...v, album_id: 12})), total: state.chapters.length});
      }
      throw new Error('Unexpected ten-audio URL: ' + u.href);
    }
    const headers = new Headers(init.headers);
    assert.equal(headers.get('Origin'), shiyin ? 'https://fmfm.tingyou.fm' : 'https://tingyou.fm');
    assert.ok(headers.get('x-listening-session'));
    assert.notEqual(headers.get('User-Agent'), 'okhttp/4.9.3');
    assert.equal(headers.get('Cookie'), null);
    if (u.pathname.endsWith('/search')) return reply(state.badSearch ? {detail: 'error'} : {results: items, has_more: false, total: 8});
    if (u.pathname.includes('/rank') || u.pathname.includes('/category')) return reply({items, has_more: false, total: 8});
    if (u.pathname.includes('/album/')) return reply({...book(100), synopsis: '真实简介'});
    if (u.pathname.includes('/chapters/')) {
      const values = state.remoteChapters ?? state.chapters;
      const payload = {id: 100, chapters: structuredClone(values), count: state.incomplete ? 99 : values.length, available: state.blocked !== true};
      if (state.catalogGate) await state.catalogGate;
      return reply(payload);
    }
    if (u.pathname.endsWith('/play')) return reply({play_url: state.badMedia ? 'http://127.0.0.1/private' : 'https://file.hgeuz.cn/stream/test?sign=temporary'});
    throw new Error('Unexpected URL: ' + u.href);
  }});
  t.after(harness.cleanup);
  return {harness, calls, state};
}
test('search keeps every upstream item with pageSize=2 and query-bound cursors', async t => {
  await setup(t);
  let cursor = null; const ids = [];
  do { const result = await plugin.search({query: '专辑', cursor, pageSize: 2}); ids.push(...result.items.map(v => v.id)); cursor = result.nextCursor; } while (cursor !== null);
  assert.deepEqual(ids, items.map(v => 'album:' + v.id));
  const first = await plugin.search({query: '专辑', cursor: null, pageSize: 2});
  await assert.rejects(plugin.search({query: 'other', cursor: first.nextCursor, pageSize: 2}), /cursor/iu);
  assert.deepEqual(await plugin.searchSuggestions(), {items: [], nextCursor: null});
});
test('all real discovery targets and append preserve collection and identity', async t => {
  await setup(t);
  const root = await plugin.discover({target: null, cursor: null, collectionId: null, pageSize: 2});
  assert.equal(collectDiscoveryTargets(root).length, 13);
  for (const target of collectDiscoveryTargets(root)) {
    const first = await plugin.discover({target, cursor: null, collectionId: null, pageSize: 2});
    const continuation = collectDiscoveryContinuations(first)[0];
    const next = await plugin.discover({...continuation, pageSize: 2});
    assert.equal(next.kind, 'append');
    assert.equal(next.collectionId, continuation.collectionId);
    assert.equal(new Set([...collectDiscoveryContent(first), ...collectDiscoveryContent(next)].map(v => v.id)).size, 4);
    await assert.rejects(plugin.discover({...continuation, collectionId: 'foreign', pageSize: 2}));
  }
  await assert.rejects(plugin.discover({target: null, cursor: 'bad', collectionId: null, pageSize: 2}));
  await assert.rejects(plugin.discover({target: 'https://evil.invalid', cursor: null, collectionId: null, pageSize: 2}));
});
test('detail works on a fresh activation; catalog retains short tracks and real chapter IDs', async t => {
  const {calls, harness, state} = await setup(t);
  const detail = await plugin.getDetail({id: 'album:100'});
  assert.equal(detail.title, '专辑100'); assert.equal(detail.description, '真实简介');
  assert.equal(detail.author, '作者'); assert.equal(detail.attributes[0].value, '演播');
  const catalog = await plugin.getChapters({id: 'album:100'});
  assert.equal(catalog.items.length, 3); assert.equal(catalog.items[0].title, '主题曲');
  assert.equal(catalog.items[0].id, 'chapter:100:71');
  const result = await plugin.getContent({id: 'album:100', chapterId: catalog.items[1].id});
  assert.equal(result.media.resourceType, 'audio'); assert.equal(result.media.resourcePolicy, 'sessionOnly');
  assert.equal(result.media.mimeType, null);
  assert.equal(calls.find(v => v.u.pathname.endsWith('/play')).body.chapter_idx, 9);
  const audio = harness.resourceRequests.find(v => v.kind === 'audio');
  assert.match(audio.url, /^https:\/\/file\.hgeuz\.cn/u);
  assert.deepEqual(Object.keys(audio.headers).map(v => v.toLowerCase()), ['referer']);
  await assert.rejects(plugin.getContent({id: 'album:200', chapterId: catalog.items[0].id}));
  state.chapters[1].index = 99;
  await plugin.getChapters({id: 'album:100', refresh: true});
  await plugin.getContent({id: 'album:100', chapterId: catalog.items[1].id});
  assert.equal(calls.filter(v => v.u.pathname.endsWith('/play')).at(-1).body.chapter_idx, 99);
});
test('large catalogs load complete groups without dropping the tail', async t => {
  await setup(t, {chapters: Array.from({length: 5301}, (_, i) => ({id: i + 1, index: i, title: '集' + i}))});
  const initial = await plugin.getChapters({id: 'album:100', supportsDeferredGroups: true});
  assert.equal(initial.items.length, 1000); assert.equal(initial.groups.length, 6);
  let all = [...initial.items];
  for (const group of initial.groups.slice(1)) {
    assert.equal(group.deferred, true); assert.equal(group.episodes.length, 0);
    const result = await plugin.getChapters({id: 'album:100', groupId: group.id, supportsDeferredGroups: true});
    assert.deepEqual(result.items, result.groups[0].episodes); all.push(...result.items);
  }
  assert.equal(all.length, 5301); assert.equal(new Set(all.map(v => v.id)).size, 5301);
  await assert.rejects(plugin.getChapters({id: 'album:100', refresh: true}));
  await assert.rejects(plugin.getChapters({id: 'album:100', groupId: 'foreign'}));
});
test('incomplete/blocked catalogs and untrusted media are rejected', async t => {
  const {state} = await setup(t, {incomplete: true});
  await assert.rejects(plugin.getChapters({id: 'album:100'}), /incomplete/iu);
  state.incomplete = false; state.blocked = true;
  await assert.rejects(plugin.getChapters({id: 'album:100'}));
  state.blocked = false; state.badMedia = true;
  await assert.rejects(plugin.getContent({id: 'album:100', chapterId: 'chapter:100:71'}));
  state.badMedia = false; state.chapters[0].is_locked = true;
  await plugin.getChapters({id: 'album:100', refresh: true});
  await assert.rejects(plugin.getContent({id: 'album:100', chapterId: 'chapter:100:71'}));
  state.chapters[0].is_locked = false; state.chapters[1].id = 71;
  await assert.rejects(plugin.getChapters({id: 'album:100', refresh: true}), /Duplicate/iu);
});
test('catalog snapshots coalesce callers; refresh rejects stale completion and failures remain misses', async t => {
  let release;
  const catalogGate = new Promise(resolve => { release = resolve; });
  const {calls, state} = await setup(t, {catalogGate});
  const first = plugin.getChapters({id: 'album:100'}), concurrent = plugin.getChapters({id: 'album:100'});
  for (let i = 0; i < 20 && !calls.some(v => v.u.pathname.includes('/chapters/')); i++) await setImmediate();
  assert.equal(calls.filter(v => v.u.pathname.includes('/chapters/')).length, 1);
  state.catalogGate = null; state.chapters[0].title = '更新后';
  const refreshed = await plugin.getChapters({id: 'album:100', refresh: true});
  assert.equal(refreshed.items[0].title, '更新后');
  release(); await Promise.all([first, concurrent]);
  assert.equal((await plugin.getChapters({id: 'album:100'})).items[0].title, '更新后');
  state.incomplete = true;
  await assert.rejects(plugin.getChapters({id: 'album:100', refresh: true}));
  state.incomplete = false;
  assert.equal((await plugin.getChapters({id: 'album:100'})).items.length, 3);
});
if (shiyin) {
  test('ten-audio prioritizes local tracks, preserves promotions and resolves the same provider', async t => {
    const {state, calls, harness} = await setup(t, {local: true});
    const result = await plugin.getChapters({id: 'album:100'});
    assert.equal(result.items[0].id, 'track:100:71'); assert.equal(result.items.length, 3);
    await plugin.getContent({id: 'album:100', chapterId: result.items[0].id});
    assert.equal(harness.resourceRequests.at(-1).url, 'https://api.365ting.com/api/audio/71');
    assert.equal(calls.some(v => v.u.pathname.endsWith('/play')), false);
    state.localFailure = true;
    const fallback = await plugin.getChapters({id: 'album:100', refresh: true});
    assert.equal(fallback.items[0].id, 'chapter:100:71');
    state.localFailure = false;
    await plugin.getContent({id: 'album:100', chapterId: fallback.items[0].id});
    assert.equal(calls.at(-1).u.pathname.endsWith('/play'), true);
  });
  test('search fallback works on a primary outage and does not turn total failure into empty success', async t => {
    const {state} = await setup(t, {primaryFailure: true});
    const result = await plugin.search({query: '专辑', cursor: null, pageSize: 2});
    assert.equal(result.items.length, 2);
    state.badSearch = true;
    await assert.rejects(plugin.search({query: '专辑', cursor: null, pageSize: 2}));
  });
  test('two-page batches use the last page continuation and preserve remote group routing', async t => {
    const {state} = await setup(t, {firstHasMore: true});
    const found = await plugin.search({query: '专辑', cursor: null, pageSize: 50});
    assert.equal(found.nextCursor, null);
    state.chapters = Array.from({length: 5301}, (_, i) => ({id: i + 1, index: i, title: '集' + i}));
    const initial = await plugin.getChapters({id: 'album:100', supportsDeferredGroups: true});
    state.local = true;
    const tail = await plugin.getChapters({id: 'album:100', supportsDeferredGroups: true, groupId: initial.groups.at(-1).id});
    assert.equal(tail.items.length, 301);
    assert.ok(tail.items.every(v => v.id.startsWith('chapter:100:')));
  });
  test('unavailable local audio uses only an unambiguous matching remote chapter', async t => {
    const {state, calls, harness} = await setup(t, {local: true, audioFailure: true});
    const catalog = await plugin.getChapters({id: 'album:100'});
    const content = await plugin.getContent({id: 'album:100', chapterId: catalog.items[1].id});
    assert.equal(content.chapterId, 'track:100:75');
    assert.match(harness.resourceRequests.at(-1).url, /^https:\/\/file\.hgeuz\.cn/u);
    assert.equal(calls.find(v => v.u.pathname.endsWith('/play')).body.chapter_idx, 9);
    const mismatched = structuredClone(chapters); mismatched[1].title = '另一个版本';
    await setup(t, {local: true, audioFailure: true, remoteChapters: mismatched});
    await assert.rejects(plugin.getContent({id: 'album:100', chapterId: 'track:100:75'}), error => error.code === 'source_media_resolution_failed');
    const ambiguous = [...structuredClone(chapters), {id: 999, index: 99, title: '正文一'}];
    await setup(t, {local: true, audioFailure: true, remoteChapters: ambiguous});
    await assert.rejects(plugin.getContent({id: 'album:100', chapterId: 'track:100:75'}), error => error.code === 'source_media_resolution_failed');
    const local = structuredClone(chapters); local[1].track_no = 9;
    const differentIndex = structuredClone(chapters); differentIndex[1].index = 199;
    await setup(t, {local: true, audioFailure: true, chapters: local, remoteChapters: differentIndex});
    await assert.rejects(plugin.getContent({id: 'album:100', chapterId: 'track:100:75'}), error => error.code === 'source_media_resolution_failed');
  });
}
