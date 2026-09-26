import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('audio fixture covers search, catalog, locked items and proxy playback metadata', async () => {
  const fixture = JSON.parse(await readFile(new URL('./fixtures/catalog.json', import.meta.url), 'utf8'));
  const resources = []; const calls = []; const logs = [];
  await plugin.activate({ cacheDir: 'fixture-cache', log: { info(event) { logs.push(`info:${event}`); }, warn(event) { logs.push(`warn:${event}`); } }, resource: { proxy(value) { resources.push(value); return 'http://127.0.0.1:9000/v1/source-resource/token123456789012'; } }, http: { async fetch(input, init) {
    const url = String(input); calls.push({ url, init });
    if (url.includes('AppGetChapterUrl2023')) return Response.json(fixture.play);
    if (url.includes('chapter?')) return Response.json(fixture.chapters);
    if (url.includes('book?')) return Response.json(fixture.book);
    if (url.includes('appHome')) return Response.json(fixture.home);
    return Response.json(fixture.search);
  } } });
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(root.document.components[0].title, '热门听书');
  assert.equal(root.document.components[0].children[0].layout, 'shelf');
  assert.equal(root.document.components[0].children[0].items[0].content.contentKind, 'audio');
  assert.equal(root.document.components[1].children[0].layout, 'chips');
  assert.equal(root.document.components[1].children[0].categories.length, 8);
  const discovery = await plugin.discover({ target: 'category:popular', cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(discovery.document.components[0].children[0].items.length, 1);
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 5 });
  const detail = await plugin.getDetail({ id: search.items[0].id });
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.equal(chapters.items.length, 2); assert.equal(chapters.items[1].isLocked, true);
  assert.equal(chapters.items[0].url, 'https://app.365ting.com/book/book-a/c-1');
  assert.equal(chapters.groups.length, 1);
  assert.deepEqual(chapters.groups[0].episodes.map((episode) => episode.id), chapters.items.map((episode) => episode.id));
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  const cover = resources.find((value) => value.kind === 'image');
  assert.equal(cover.url, 'https://app.365ting.com/cover.jpg');
  assert.equal(cover.headers.Referer, 'https://app.365ting.com/');
  assert.match(cover.headers.Accept, /^image\//u);
  assert.equal(cover.headers['User-Agent'], 'TingShiJie/1.8.8 (m.i275.com)');
  assert.equal(content.media.resourceType, 'audio'); assert.equal(content.media.resourcePolicy, 'refreshable');
  assert.equal(content.media.url.startsWith('http://127.0.0.1:'), true);
  assert.equal(content.media.expiresAt, '2100-01-01T00:00:00.000Z');
  const media = resources.find((value) => value.kind === 'audio');
  assert.equal(media.headers.Range, undefined);
  const cached = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.equal(cached.media.resourcePolicy, 'refreshable');
  assert.equal(resources.filter((value) => value.kind === 'audio').length, 2);
  assert.equal(calls.filter(({ url }) => url.includes('AppGetChapterUrl2023')).length, 1);
  assert.equal(calls.filter(({ init }) => init.method === 'HEAD').length, 1);
  await assert.rejects(plugin.getContent({ id: detail.id, chapterId: chapters.items[1].id }), /paid audio chapter/u);
  assert.deepEqual(logs.slice(-3), ['info:audio_playback_resource_resolved', 'info:audio_playback_resource_requested', 'warn:audio_playback_resource_failed']);
  assert.ok(calls.every(({ init }) => init.headers.cookie === undefined));
});

test('re-resolves a cached playback URL after the fast probe rejects it', async () => {
  let playCalls = 0; let probeCalls = 0; const proxied = [];
  await plugin.activate({ cacheDir: 'fixture-cache', log: { info() {}, warn() {} }, resource: { proxy(value) { proxied.push(value); return `http://127.0.0.1:9000/v1/source-resource/token${proxied.length}`; } }, http: { async fetch(input, init = {}) {
    const url = String(input);
    if (init.method === 'HEAD') { probeCalls += 1; return new Response(null, { status: 403 }); }
    if (url.includes('AppGetChapterUrl2023')) { playCalls += 1; return Response.json({ status: 0, src: `https://audio.tingshijie.com/reconnected-${playCalls}.mp3?expires=4102444800` }); }
    return Response.json({ data: { count: 1, list: [{ chapterId: 'c-1', title: 'Episode one', price: 0 }] } });
  } } });
  const contentRequest = { id: 'audio:book-reconnect', chapterId: 'audio:book-reconnect:c-1' };
  const first = await plugin.getContent(contentRequest); const second = await plugin.getContent(contentRequest);
  assert.equal(first.media.resourcePolicy, 'refreshable'); assert.equal(second.media.resourcePolicy, 'refreshable');
  assert.equal(playCalls, 2); assert.equal(probeCalls, 1); assert.equal(proxied[1].url.endsWith('reconnected-2.mp3?expires=4102444800'), true);
});

test('drops an expired playback URL without probing it', async () => {
  let playCalls = 0; let probeCalls = 0;
  await plugin.activate({ cacheDir: 'fixture-cache', log: { info() {}, warn() {} }, resource: { proxy() { return 'http://127.0.0.1:9000/v1/source-resource/token123456789012'; } }, http: { async fetch(input, init = {}) {
    const url = String(input);
    if (init.method === 'HEAD') { probeCalls += 1; return new Response(null, { status: 200 }); }
    if (url.includes('AppGetChapterUrl2023')) { playCalls += 1; return Response.json({ status: 0, src: `https://audio.tingshijie.com/expired-${playCalls}.mp3?expires=1` }); }
    return Response.json({ data: { count: 1, list: [{ chapterId: 'c-1', title: 'Episode one', price: 0 }] } });
  } } });
  const contentRequest = { id: 'audio:book-expired', chapterId: 'audio:book-expired:c-1' };
  await plugin.getContent(contentRequest); await plugin.getContent(contentRequest);
  assert.equal(playCalls, 2); assert.equal(probeCalls, 0);
});

test('loads a long catalog in bounded parallel page batches while preserving order', async () => {
  let active = 0; let maximumActive = 0;
  await plugin.activate({ cacheDir: 'fixture-cache', log: { info() {}, warn() {} }, resource: { proxy() { return 'http://127.0.0.1:9000/v1/source-resource/token123456789012'; } }, http: { async fetch(input) {
    const url = String(input); const page = Number(new URL(url).searchParams.get('page') ?? 1);
    active += 1; maximumActive = Math.max(maximumActive, active);
    await new Promise((resolve) => setTimeout(resolve, 10));
    active -= 1;
    return Response.json({ data: { count: 1000, list: [{ chapterId: `c-${page}`, title: `Episode ${page}`, price: 0 }] } });
  } } });
  const result = await plugin.getChapters({ id: 'audio:book-long' });
  assert.equal(result.items.map((item) => item.id).join(','), [1, 2, 3, 4, 5].map((page) => `audio:book-long:c-${page}`).join(','));
  assert.ok(maximumActive > 1);
  assert.ok(maximumActive <= 6);
});

test('serves an expired catalog immediately and refreshes it in the background', async () => {
  const cacheDir = await mkdtemp(join(tmpdir(), 'tingchina-catalog-cache-'));
  const originalNow = Date.now; let now = 1_000_000; let fetchCalls = 0; let signalRefreshStarted; let releaseRefresh;
  const refreshStarted = new Promise((resolve) => { signalRefreshStarted = resolve; });
  const refreshRelease = new Promise((resolve) => { releaseRefresh = resolve; });
  const context = { cacheDir, log: { info() {}, warn() {} }, resource: { proxy() { return 'http://127.0.0.1/resource'; } }, http: { async fetch() {
    fetchCalls += 1;
    if (fetchCalls === 2) { signalRefreshStarted(); await refreshRelease; }
    const version = fetchCalls === 1 ? 'old' : 'new';
    return Response.json({ data: { count: 1, list: [{ chapterId: `c-${version}`, title: `Episode ${version}`, price: 0 }] } });
  } } };
  try {
    Date.now = () => now;
    await plugin.activate(context);
    const initial = await plugin.getChapters({ id: 'audio:book-stale' });
    assert.equal(initial.items[0].id, 'audio:book-stale:c-old');
    now += 24 * 60 * 60 * 1000 + 1;
    const stale = await plugin.getChapters({ id: 'audio:book-stale' });
    assert.equal(stale.items[0].id, 'audio:book-stale:c-old');
    await refreshStarted;
    const duringRefresh = await plugin.getChapters({ id: 'audio:book-stale' });
    assert.equal(duringRefresh.items[0].id, 'audio:book-stale:c-old');
    assert.equal(fetchCalls, 2);
    releaseRefresh();
    await new Promise((resolve) => setTimeout(resolve, 30));
    await plugin.activate(context);
    const refreshed = await plugin.getChapters({ id: 'audio:book-stale' });
    assert.equal(refreshed.items[0].id, 'audio:book-stale:c-new');
    assert.equal(fetchCalls, 2);
  } finally {
    Date.now = originalNow;
    await rm(cacheDir, { recursive: true, force: true });
  }
});

function discoveryCollections(result) {const found=[]; const visit=node=>{if(node.type==='contentCollection')found.push(node);for(const child of node.children??[])visit(child);};for(const node of result.document?.components??[])visit(node);return found;}
test('home exposes source sections and popular continuation drains the snapshot',async()=>{
 const books=Array.from({length:7},(_,i)=>({id:String(i+1),bookTitle:'Book '+i}));const calls=[];
 await plugin.activate({cacheDir:'fixture-cache',log:{info(){}},resource:{proxy:v=>v.url},http:{fetch:async(url)=>{calls.push(String(url));return Response.json({data:{best:{list:books},ertong:{id:50,list:books.slice(0,2)}}});}}});
 const root=await plugin.discover({target:null,cursor:null,collectionId:null,pageSize:3});const lists=discoveryCollections(root);
 assert.equal(lists.length,2);assert.equal(lists[1].items[0].content.coverOrientation,'portrait');let current=lists[0],seen=current.items.map(x=>x.content.id);
 while(current.continuation){current=await plugin.discover({...current.continuation,collectionId:lists[0].id,pageSize:3});seen.push(...current.items.map(x=>x.content.id));}
 assert.equal(seen.length,7);assert.equal(new Set(seen).size,7);assert.ok(calls.every(x=>x.endsWith('appHome')));
 await assert.rejects(plugin.discover({target:'category:popular',cursor:'category:popular:2',collectionId:null,pageSize:3}));
});