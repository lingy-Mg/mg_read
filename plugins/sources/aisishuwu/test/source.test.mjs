import assert from 'node:assert/strict';
import test from 'node:test';

import { AliceBookHouseSource } from '../dist/source.js';

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
      log: { debug() {}, info() {}, warn() {}, error() {} },
      app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
      plugin: { id: 'org.mgread.aisishuwu', version: '0.1.0' },
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
    'https://cdn.example.com/covers/42.jpg',
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
      plugin: { id: 'org.mgread.aisishuwu', version: '0.1.0' },
    },
    { origin: 'https://www.alicesw.com', categories: [{ id: '62', title: '玄幻' }] },
  );

  const detail = await source.getDetail({ id: 'novel:42' });

  assert.equal(detail.coverUrl, 'https://cdn.example.com/covers/42.jpg');
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
      plugin: { id: 'org.mgread.aisishuwu', version: '0.1.0' },
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

test('catalog returns pages asynchronously without re-fetching a loaded source page', async () => {
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
      plugin: { id: 'org.mgread.aisishuwu', version: '0.1.0' },
    },
    { origin: 'https://www.alicesw.com', categories: [{ id: '71', title: '科幻' }] },
  );

  const first = await source.getChapters({ id: 'novel:42', cursor: null, pageSize: 2 });
  const second = await source.getChapters({ id: 'novel:42', cursor: first.nextCursor, pageSize: 2 });

  assert.deepEqual(first.items.map((chapter) => chapter.title), ['第一章', '第二章']);
  assert.deepEqual(second.items.map((chapter) => chapter.title), ['第三章', '第四章']);
  assert.equal(first.totalCount, 5);
  assert.equal(second.nextCursor, 'catalog-page:1:4');
  assert.equal(catalogFetches, 1);
});
