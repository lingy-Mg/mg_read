import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { AliceBookHouseSource } from '../dist/source.js';
import * as plugin from '../dist/index.mjs';

test('list results retain an HTTP(S) cover from the source card', async () => {
  const source = new AliceBookHouseSource(
    {
      dataDir: 'data',
      cacheDir: 'cache',
      http: {
        fetch: async (input) =>
          new URL(input).pathname.startsWith('/novel/')
              ? new Response(`
                <h1 class="novel_title">封面测试书</h1>
                <section class="pic"><img data-original="//cdn.example.com/covers/42.jpg"></section>
              `)
              : new Response(`
            <article class="list-group-item">
              <a href="/novel/42.html">封面测试书</a>
              <a href="/lists/62.html">玄幻</a>
            </article>
          `),
      },
      resource: {
        proxy: () => 'http://127.0.0.1:1234/v1/source-resource/opaque',
      },
      log: { debug() {}, info() {}, warn() {}, error() {} },
      app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
      plugin: { id: 'org.mgread.aisishuwu', version: '0.2.2' },
    },
    { origin: 'https://www.alicesw.com', categories: [{ id: '62', title: '玄幻' }] },
  );

  const result = await source.discover({
    target: 'category:62',
    cursor: null,
    collectionId: null,
    pageSize: 20,
  });

  assert.equal(
    result.document.components[0].children[0].items[0].content.coverUrl,
    'http://127.0.0.1:1234/v1/source-resource/opaque',
  );
});

test('detail results retain a lazy-loaded cover from the source page', async () => {
  const source = new AliceBookHouseSource(
    {
      dataDir: 'data',
      cacheDir: 'cache',
      http: {
        fetch: async () =>
          new Response(`
            <h1 class="novel_title">封面测试书</h1>
            <section class="pic"><img data-original="https://cdn.example.com/covers/42.jpg"></section>
          `),
      },
      log: { debug() {}, info() {}, warn() {}, error() {} },
      app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
      plugin: { id: 'org.mgread.aisishuwu', version: '0.2.2' },
    },
    { origin: 'https://www.alicesw.com', categories: [{ id: '62', title: '玄幻' }] },
  );

  const detail = await source.getDetail({ id: 'novel:42' });

  assert.equal(detail.coverUrl, 'https://cdn.example.com/covers/42.jpg');
});

test('Runtime proxy replaces an Alice cover URL and rejects off-origin resources', async () => {
  let proxyRequest;
  let fetchCount = 0;
  const context = {
    dataDir: 'data', cacheDir: 'cache',
    resource: { proxy: (request) => { proxyRequest = request; return 'http://127.0.0.1:1234/v1/source-resource/opaque'; } },
    http: { fetch: async () => { fetchCount += 1; return new Response('<h1 class="novel_title">封面测试书</h1><section class="pic"><img src="https://www.alicesw.com/covers/42.jpg"></section><div class="novel_info"><a href="/lists/62.html">玄幻</a><p>字 数：0 · 章 节：0</p><p>状 态：连载中</p></div>'); } },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.aisishuwu', version: '0.2.2' },
  };
  const source = new AliceBookHouseSource(context, { origin: 'https://www.alicesw.com', categories: [] });
  const detail = await source.getDetail({ id: 'novel:42' });
  assert.equal(detail.coverUrl, 'http://127.0.0.1:1234/v1/source-resource/opaque');
  assert.deepEqual(proxyRequest, { url: 'https://www.alicesw.com/covers/42.jpg' });

  await plugin.activate(context);
  const result = await plugin.resource({ url: 'https://evil.example/covers/42.jpg' });
  assert.equal(result.status, 400);
  assert.equal(result.body.byteLength, 0);
  assert.equal(fetchCount, 1);
});

test('detail projects real source metadata into the v1 summary fields', async () => {
  const source = new AliceBookHouseSource(
    {
      dataDir: 'data',
      cacheDir: 'cache',
      http: {
        fetch: async () =>
          new Response(`
            <h1 class="novel_title">字段测试书</h1>
            <div class="pic"><img src="https://cdn.example.com/covers/fields.jpg"></div>
            <div class="novel_info">
              <p>作 者：<a href="/search.html?q=test&f=author">字段作者</a></p>
              <p>分 类：<a href="/lists/71.html">科幻</a></p>
              <p>热 度：12210 · 收 藏：49</p>
              <p>字 数：185.96万 · 章 节：733</p>
              <p>状 态：连载中</p>
              <p>最 新：<a href="/book/42/latest.html">最新章节</a></p>
            </div>
            <div class="tags_list">标签：
              <a href="/search.html?q=tag-a&f=tag"><em>#</em>标签甲</a>
              <a href="/search.html?q=tag-b&f=tag"><em>#</em>标签乙</a>
            </div>
            <div class="book_newchap"><div class="con"><li><em>更新时间：2026-08-10 12:31</em></li></div></div>
          `),
      },
      log: { debug() {}, info() {}, warn() {}, error() {} },
      app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
      plugin: { id: 'org.mgread.aisishuwu', version: '0.2.2' },
    },
    { origin: 'https://www.alicesw.com', categories: [{ id: '71', title: '科幻' }] },
  );

  const detail = await source.getDetail({ id: 'novel:42' });

  assert.equal(detail.author, '字段作者');
  assert.deepEqual(detail.categories, ['科幻']);
  assert.equal(detail.wordCount, 1859600);
  assert.equal(detail.chapterCount, 733);
  assert.equal(detail.status, 'ongoing');
  assert.deepEqual(detail.tags, ['标签甲', '标签乙']);
  assert.deepEqual(detail.attributes, [
    { key: 'heat', label: '热度', value: '12210' },
    { key: 'favorites', label: '收藏', value: '49' },
  ]);
  assert.equal(detail.latestChapter?.updatedAt, '2026-08-10T04:31:00.000Z');
});

test('search hydrates list items with the same cover and rich metadata as discovery', async () => {
  const source = new AliceBookHouseSource(
    {
      dataDir: 'data',
      cacheDir: 'cache',
      http: {
        fetch: async (input) => {
          const path = new URL(input).pathname;
          if (path === '/novel/42.html') {
            return new Response(`
              <h1 class="novel_title">字段测试书</h1>
              <div class="pic"><img src="https://cdn.example.com/covers/fields.jpg"></div>
              <div class="novel_info">
                <p>作 者：<a href="/search.html?q=test&f=author">字段作者</a></p>
                <p>分 类：<a href="/lists/71.html">科幻</a></p>
                <p>热 度：562.3万 · 收 藏：49</p>
                <p>字 数：185.96万 · 章 节：733</p>
                <p>状 态：连载中</p>
                <p>最 新：<a href="/book/42/latest.html">最新章节</a></p>
              </div>
              <div class="jianjie"><p>这是分类页应该展示的短简介。</p></div>
              <div class="tags_list">
                <a href="/search.html?q=tag-a&f=tag"><em>#</em>标签甲</a>
                <a href="/search.html?q=tag-b&f=tag"><em>#</em>标签乙</a>
              </div>
              <div class="book_newchap"><div class="con"><li><em>更新时间：2026-08-10 12:31</em></li></div></div>
            `);
          }
          return new Response(`
            <article class="list-group-item">
              <a href="/novel/42.html">字段测试书</a>
              <a href="/lists/71.html">科幻</a>
            </article>
          `);
        },
      },
      log: { debug() {}, info() {}, warn() {}, error() {} },
      app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
      plugin: { id: 'org.mgread.aisishuwu', version: '0.2.0' },
    },
    { origin: 'https://www.alicesw.com', categories: [{ id: '71', title: '科幻' }] },
  );

  const result = await source.search({
    query: '字段测试',
    cursor: null,
    pageSize: 20,
  });
  const item = result.items[0];
  assert.equal(item.author, '字段作者');
  assert.equal(item.coverUrl, 'https://cdn.example.com/covers/fields.jpg');
  assert.equal(item.description, '这是分类页应该展示的短简介。');
  assert.equal(item.wordCount, 1859600);
  assert.equal(item.chapterCount, 733);
  assert.equal(item.status, 'ongoing');
  assert.deepEqual(item.categories, ['科幻']);
  assert.deepEqual(item.tags, ['标签甲', '标签乙']);
  assert.deepEqual(item.attributes, [
    { key: 'heat', label: '热度', value: '5623000' },
    { key: 'favorites', label: '收藏', value: '49' },
  ]);
});

test('popular search terms come only from the home hot-recommendation section and are cached', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-aisishuwu-hot-search-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  let fetchCount = 0;
  const source = new AliceBookHouseSource(
    {
      dataDir: 'data',
      cacheDir: join(root, 'cache'),
      http: {
        fetch: async () => {
          fetchCount += 1;
          return new Response(`
            <div class="title">原创专区</div>
            <article class="list-group-item"><a href="/novel/1.html">不应出现的首页书</a></article>
            <div class="innerss">
              <div class="title">热门推荐小说</div>
              <div class="details"><ul class="item-list">
                <li><a class="titles" href="/novel/42.html">首页热书</a></li>
                <li><a class="titles" href="/novel/43.html">第二本热书</a></li>
                <li><a class="titles" href="/novel/44.html">首页热书</a></li>
              </ul></div>
            </div>
          `);
        },
      },
      log: { debug() {}, info() {}, warn() {}, error() {} },
      app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
      plugin: { id: 'org.mgread.aisishuwu', version: '0.2.0' },
    },
    { origin: 'https://www.alicesw.com', categories: [{ id: '71', title: '科幻' }] },
  );

  const suggestions = await source.searchSuggestions({
    cursor: null,
    pageSize: 20,
  });
  const cachedSuggestions = await source.searchSuggestions({
    cursor: null,
    pageSize: 20,
  });
  assert.deepEqual(suggestions, {
    items: [
      { query: '首页热书', metric: null },
      { query: '第二本热书', metric: null },
    ],
    nextCursor: null,
  });
  assert.deepEqual(cachedSuggestions, suggestions);
  assert.equal(fetchCount, 1);
});

test('catalog does not let a zero detail count hide loaded chapters', async () => {
  const source = new AliceBookHouseSource(
    {
      dataDir: 'data',
      cacheDir: 'cache',
      http: {
        fetch: async (input) => {
          const path = new URL(input).pathname;
          if (path === '/novel/42.html') {
            return new Response(`
              <h1 class="novel_title">零值测试书</h1>
              <div class="novel_info">
                <p>字 数：0 · 章 节：0</p>
                <p>状 态：连载中</p>
              </div>
            `);
          }
          return new Response(`
            <div class="book_newchap"><div class="tit">最新章节：全5章</div></div>
            <ul class="mulu_list">
              <li><a href="/book/42/a.html">第一章</a></li>
              <li><a href="/book/42/b.html">第二章</a></li>
              <li><a href="/book/42/c.html">第三章</a></li>
              <li><a href="/book/42/d.html">第四章</a></li>
              <li><a href="/book/42/e.html">第五章</a></li>
            </ul>
          `);
        },
      },
      log: { debug() {}, info() {}, warn() {}, error() {} },
      app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
      plugin: { id: 'org.mgread.aisishuwu', version: '0.2.2' },
    },
    { origin: 'https://www.alicesw.com', categories: [] },
  );

  const detail = await source.getDetail({ id: 'novel:42' });
  assert.equal(detail.chapterCount, 0);
  const chapters = await source.getChapters({ id: 'novel:42' });

  assert.equal(chapters.items.length, 5);
});

test('catalog returns the complete source page without re-fetching it', async () => {
  let catalogFetches = 0;
  const source = new AliceBookHouseSource(
    {
      dataDir: 'data',
      cacheDir: 'cache',
      http: {
        fetch: async () => {
          catalogFetches += 1;
          return new Response(`
            <div class="book_newchap"><div class="tit">最新章节：全5章</div></div>
            <ul class="mulu_list">
              <li><a href="/book/42/a.html">第一章</a></li>
              <li><a href="/book/42/b.html">第二章</a></li>
              <li><a href="/book/42/c.html">第三章</a></li>
              <li><a href="/book/42/d.html">第四章</a></li>
              <li><a href="/book/42/e.html">第五章</a></li>
            </ul>
          `);
        },
      },
      log: { debug() {}, info() {}, warn() {}, error() {} },
      app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
      plugin: { id: 'org.mgread.aisishuwu', version: '0.2.2' },
    },
    { origin: 'https://www.alicesw.com', categories: [{ id: '71', title: '科幻' }] },
  );

  const first = await source.getChapters({ id: 'novel:42' });

  assert.deepEqual(first.items.map((chapter) => chapter.title), [
    '第一章',
    '第二章',
    '第三章',
    '第四章',
    '第五章',
  ]);
  assert.equal(catalogFetches, 1);
});

test('catalog follows source pagination internally and returns one deduplicated result', async () => {
  const requestedPages = [];
  const source = new AliceBookHouseSource(
    {
      dataDir: 'data',
      cacheDir: 'cache',
      http: {
        fetch: async (input) => {
          const url = new URL(input);
          const page = Number(url.searchParams.get('page') ?? '1');
          requestedPages.push(page);
          return new Response(
            page === 1
              ? `<ul class="mulu_list"><li><a href="/book/42/a.html">第一章</a></li><li><a href="/book/42/b.html">第二章</a></li></ul><div class="pagination"><a rel="next" href="?page=2">下一页</a></div>`
              : `<ul class="mulu_list"><li><a href="/book/42/b.html">第二章</a></li><li><a href="/book/42/c.html">第三章</a></li></ul>`,
          );
        },
      },
      log: { debug() {}, info() {}, warn() {}, error() {} },
      app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
      plugin: { id: 'org.mgread.aisishuwu', version: '0.2.2' },
    },
    { origin: 'https://www.alicesw.com', categories: [] },
  );

  const chapters = await source.getChapters({ id: 'novel:42' });

  assert.deepEqual(requestedPages, [1, 2]);
  assert.deepEqual(chapters.items.map(({ title, order }) => ({ title, order })), [
    { title: '第一章', order: 0 },
    { title: '第二章', order: 1 },
    { title: '第三章', order: 2 },
  ]);
  assert.equal(new Set(chapters.items.map((chapter) => chapter.id)).size, 3);
});

test('public API completes the opaque content chain with safe diagnostic phases', async () => {
  const events = [];
  const secret = 'credential-canary-do-not-log';
  const chapterBody = 'chapter-body-canary-do-not-log';
  let detailFetches = 0;
  let catalogFetches = 0;
  const list = `
    <article class="list-group-item">
      <a href="/novel/42.html">测试书名</a>
      <a href="/lists/71.html">科幻</a>
      <img src="https://cdn.example.com/covers/42.jpg">
    </article>
    <div class="innerss">
      <div class="title">热门推荐小说</div>
      <div class="details"><ul class="item-list">
        <li><a class="titles" href="/novel/42.html">测试书名</a></li>
      </ul></div>
    </div>
  `;
  await plugin.activate({
    dataDir: 'data',
    cacheDir: 'cache',
    http: {
      fetch: async (input) => {
        const url = new URL(input);
        if (url.pathname === '/search.html' && url.searchParams.get('q') === secret) {
          return new Response('upstream-response-canary', { status: 503 });
        }
        if (
          url.pathname === '/' ||
          url.pathname === '/lists/71.html' ||
          url.pathname === '/search.html'
        ) {
          return new Response(list);
        }
        if (url.pathname === '/novel/42.html') {
          detailFetches += 1;
          return new Response(`
            <h1 class="novel_title">测试书名</h1>
            <div class="novel_info"><p>作 者：<a href="/search.html?f=author">测试作者</a></p></div>
          `);
        }
        if (url.pathname === '/other/chapters/id/42.html') {
          catalogFetches += 1;
          return new Response('<ul class="mulu_list"><li><a href="/book/42/first.html">第一章</a></li></ul>');
        }
        if (url.pathname === '/book/42/first.html') {
          return new Response(`<h1>第一章</h1><article class="read-content"><p>${chapterBody}</p></article>`);
        }
        return new Response('not found', { status: 404 });
      },
    },
    log: {
      debug: (event) => events.push(event),
      info: (event) => events.push(event),
      warn: (event) => events.push(event),
      error: (event) => events.push(event),
    },
    app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.aisishuwu', version: '0.2.0' },
  });

  const categoryPage = await plugin.discover({
    target: null,
    cursor: null,
    collectionId: null,
    pageSize: 20,
  });
  assert.equal(categoryPage.kind, 'document');
  const categoryCollection = categoryPage.document.components[0].children.find(
    (component) => component.type === 'categoryCollection',
  );
  assert.equal(categoryCollection?.type, 'categoryCollection');
  const categoryTarget = categoryCollection.categories[0].target;
  const discovery = await plugin.discover({
    target: categoryTarget,
    cursor: null,
    collectionId: null,
    pageSize: 5,
  });
  assert.equal(discovery.kind, 'document');
  const contentCollection = discovery.document.components[0].children.find(
    (component) => component.type === 'contentCollection',
  );
  assert.equal(contentCollection?.type, 'contentCollection');
  const contentId = contentCollection.items[0].content.id;
  const search = await plugin.search({ query: '测试', cursor: null, pageSize: 5 });
  const suggestions = await plugin.searchSuggestions({ cursor: null, pageSize: 5 });
  const detail = await plugin.getDetail({ id: contentId });
  const chapters = await plugin.getChapters({ id: contentId });
  const content = await plugin.getContent({ id: contentId, chapterId: chapters.items[0].id });

  assert.equal(search.items[0].id, contentId);
  assert.equal(suggestions.items[0].query, '测试书名');
  assert.equal(detail.id, contentId);
  assert.equal(content.chapterId, chapters.items[0].id);
  assert.equal(content.text, chapterBody);
  // Discovery already parsed the detail page. Reopening the detail reuses that
  // projection, and a repeated shelf catalog read reuses the full aggregation.
  assert.equal(detailFetches, 1);
  assert.equal(catalogFetches, 1);
  await plugin.getChapters({ id: contentId });
  assert.equal(catalogFetches, 1);
  for (const operation of ['discover', 'search', 'search_suggestions', 'get_detail', 'get_chapters', 'get_content']) {
    assert.ok(events.includes(`source_${operation}_started`));
    assert.ok(events.includes(`source_${operation}_validated`));
    assert.ok(events.includes(`source_${operation}_parsed`));
    assert.ok(events.includes(`source_${operation}_result_ready`));
    assert.ok(events.includes(`source_${operation}_completed`));
  }
  assert.ok(events.includes('source_http_fetch_started'));

  await assert.rejects(
    plugin.search({ query: secret, cursor: null, pageSize: 5 }),
    /Source operation failed/u,
  );
  assert.ok(events.includes('source_search_failed'));
  assert.doesNotMatch(events.join('\n'), new RegExp(`${secret}|${chapterBody}`, 'u'));
});
