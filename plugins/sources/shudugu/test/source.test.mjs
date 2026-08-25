import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

function context(fetch, cacheDir = 'cache') {
  const events = [];
  return { events, value: { dataDir: 'data', cacheDir, http: { fetch }, resource: { proxy: () => 'http://127.0.0.1:1234/v1/source-resource/opaque' }, log: { debug: (e) => events.push(e), info: (e) => events.push(e), warn: (e) => events.push(e), error: (e) => events.push(e) }, app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.shudugu', version: '0.1.1' } } };
}

const detail = `<div class="item"><a href="/51/"><img src="https://cdn.example/cover.jpg"></a><div class="itemtxt"><h1><i>12.5万字</i><a href="/51/">测试书</a></h1><p><span>连载中</span><span>都市小说</span></p><p><a href="/zuozhe/?tag=作者">作者：作者甲</a></p><ul><li><a href="/51/101.html">第一章</a></li></ul></div></div><div class="des bb"><p>简介</p></div><h2 id="dir"><span>更新时间：2026-08-24 12:10:35</span></h2><div id="list"><ul><li><a href="/51/101.html">第一章</a></li><li><a href="/51/102.html">第二章</a></li></ul></div>`;

test('completes search, detail, catalog and content with opaque IDs', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-shudugu-hot-search-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  let homeCalls = 0;
  const state = context(async (input) => {
    const requestUrl = new URL(input);
    const path = requestUrl.pathname;
    if (requestUrl.searchParams.get('key') === 'secret-canary-do-not-log') return new Response('upstream failure', { status: 503 });
    if (path === '/i/sor.aspx') return new Response(`<div class="item"><a href="/51/"><img src="https://cdn.example/cover.jpg"></a><div class="itemtxt"><h3><a href="/51/">测试书</a></h3><p><span>连载中</span><span>都市小说</span></p><p><a href="/zuozhe/?tag=作者">作者：作者甲</a></p></div></div><div class="page">共1本小说</div>`);
    if (path === '/') {
      homeCalls += 1;
      return new Response(`<div class="container"><h2><a href="/zuixin/">最新更新</a></h2><div class="item"><a href="/51/"><div class="itemtxt"><h3><a href="/51/">不应作为热门词</a></h3></div></div></div><div class="container"><h2><a href="/paihang/">阅读排行</a></h2><ul class="list top clear"><li><p><a href="/51/">排行热书</a></p></li><li><p><a href="/52/">第二排行热书</a></p></li></ul></div>`);
    }
    if (path === '/51/') return new Response(detail);
    if (path === '/51/101.html') return new Response('<div class="container"><div class="submenu"><h1>测试书 > 第一章</h1></div><div class="con"><p>正文 canary</p></div></div>');
    if (path === '/51/102.html') return new Response('<div class="container"><div class="con"><p>第二章</p></div></div>');
    return new Response('not found', { status: 404 });
  }, join(root, 'cache'));
  await plugin.activate(state.value);
  const search = await plugin.search({ query: '测试', cursor: null, pageSize: 10 });
  assert.equal(search.items[0].id, 'novel:51');
  assert.equal(
    search.items[0].coverUrl,
    'http://127.0.0.1:1234/v1/source-resource/opaque',
  );
  const book = await plugin.getDetail({ id: 'novel:51' });
  assert.equal(book.author, '作者甲');
  assert.equal(book.wordCount, 125000);
  assert.equal(book.chapterCount, 2);
  const chapters = await plugin.getChapters({ id: book.id });
  assert.equal(chapters.items[0].id.startsWith('chapter:'), true);
  const content = await plugin.getContent({ id: book.id, chapterId: chapters.items[0].id });
  const suggestions = await plugin.searchSuggestions({ cursor: null, pageSize: 10 });
  const cachedSuggestions = await plugin.searchSuggestions({ cursor: null, pageSize: 10 });
  assert.equal(content.text, '正文 canary');
  assert.deepEqual(suggestions.items.map((item) => item.query), ['排行热书', '第二排行热书']);
  assert.deepEqual(cachedSuggestions, suggestions);
  assert.equal(homeCalls, 1);
  assert.ok(state.events.includes('source_search_completed'));
  await assert.rejects(plugin.search({ query: 'secret-canary-do-not-log', cursor: null, pageSize: 10 }), /Source operation failed/u);
  assert.ok(state.events.includes('source_search_failed'));
  assert.doesNotMatch(state.events.join('\n'), /secret-canary-do-not-log|正文 canary/u);
});

test('resource proxy rejects foreign URLs without fetching them', async () => {
  let fetchCount = 0;
  const state = context(async () => {
    fetchCount += 1;
    return new Response('unexpected');
  });
  await plugin.activate(state.value);

  const result = await plugin.resource({ url: 'https://evil.example/cover.jpg' });

  assert.equal(result.status, 400);
  assert.equal(result.body.byteLength, 0);
  assert.equal(fetchCount, 0);
});
