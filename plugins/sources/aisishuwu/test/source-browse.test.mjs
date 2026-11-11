/**
 * 官网已核实的独立栏目、分类/排序联动与 50 行站点分页回归。
 * 只使用最小 DOM fixture；线上入口及内容/资源另由 live smoke 验证。
 */
import assert from 'node:assert/strict';
import test from 'node:test';
import { collectDiscoveryContent, collectDiscoveryContinuations, createSourceTestHarness } from '@mgread/source-testkit';
import { AliceBookHouseSource } from '../dist/source.js';
import { browseNextPage, browsePath, browseState, browseTarget } from '../dist/source-browse-routes.js';
import { discoveryPayloadMaximumBytes } from '../dist/source-discovery-budget.js';

const categories = [
  { id: '71', title: '科幻' }, { id: '64', title: '都市' },
  { id: '73', title: '同人' }, { id: '62', title: '玄幻' },
];
const request = (target, extra = {}) => ({ target, cursor: null, collectionId: null, pageSize: 20, ...extra });
const card = (id) => `<div class="class-img"><a href="/novel/${id}.html"><img src="https://img.321cdn.com/${id}.jpg"></a>
  <h5><a href="/novel/${id}.html">测试小说${id}</a></h5></div>`;
const home = `<div class="hot-box"><div class="hot-title"><h2>原创专区</h2><a href="/original.html">More+</a></div>
    <div class="class-box">${Array.from({ length: 6 }, (_, i) => card(100 + i)).join('')}</div></div>
  <div class="hot-box"><div class="hot-title"><h2>重磅推荐</h2></div><div class="hot-data">
    ${Array.from({ length: 4 }, (_, i) => `<div class="hot-img">${card(200 + i)}</div>`).join('')}</div></div>
  <div class="innerss"><div class="title">热门推荐小说</div><div class="details"><ul>
    ${Array.from({ length: 10 }, (_, i) => `<li><a href="/novel/${300 + i}.html">热门${i}</a></li>`).join('')}</ul></div></div>
  ${categories.map((category, i) => `<div class="hot-box"><div class="hot-title"><h2>${category.title}排行榜</h2>
    <a href="/lists/${category.id}.html">More+</a></div><div class="class-box">
    ${Array.from({ length: 4 }, (_, n) => card(400 + i * 10 + n)).join('')}</div></div>`).join('')}
  <div class="inner"><div class="hot-title"><h2>最新小说</h2></div><div class="rec_rullist">
    ${Array.from({ length: 6 }, (_, i) => `<ul><li><a href="/novel/${600 + i}.html">最新${i}</a></li></ul>`).join('')}</div></div>`;

async function fixture(t, { next = true } = {}) {
  const requests = [];
  const harness = await createSourceTestHarness({
    plugin: { activate() {} }, pluginId: 'org.mgread.aisishuwu', version: '0.2.18', prefix: 'alice-browse-',
    resourceProxy: (_request, index) => `http://127.0.0.1:1234/v1/source-resource/${String(index).padStart(360, 'x')}`,
    fetch: async (input) => {
      const url = new URL(input);
      requests.push(url.pathname + url.search);
      if (url.pathname === '/') return new Response(home);
      const id = /^\/novel\/(\d+)\.html$/u.exec(url.pathname)?.[1];
      if (id !== undefined) return new Response(`<h1 class="novel_title">测试小说${id}</h1>
        <section class="pic"><img src="https://img.321cdn.com/${id}.jpg"></section>
        <div class="novel_info"><a href="/lists/71.html">科幻</a><p>字 数：12345 · 章 节：67</p></div>
        <div class="jianjie"><p>测试简介</p></div>`);
      const page = Number(url.searchParams.get('page') ?? 1);
      const rows = page === 1 ? 50 : 3;
      const offset = page === 1 ? 0 : 50;
      return new Response(`<div class="rec_rullist">${Array.from({ length: rows }, (_, i) => `
        <ul><li><a href="/novel/${offset + i + 1}.html">列表小说${offset + i + 1}</a></li>
        <li class="four">列表作者</li><li><a href="/lists/71.html">科幻</a></li></ul>`).join('')}</div>
        ${next && page === 1 ? `<ul class="pagination"><li><a href="${url.pathname}?page=2">下一页</a></li></ul>` : ''}`);
    },
  });
  t.after(harness.cleanup);
  return { source: new AliceBookHouseSource(harness.context, { origin: 'https://www.alicesw.com', categories }), requests };
}

test('home retains recommendations, exposes original/latest, and parses every real category ranking', async (t) => {
  const { source } = await fixture(t);
  const result = await source.discover(request(null));
  assert.ok(Buffer.byteLength(JSON.stringify(result), 'utf8') <= discoveryPayloadMaximumBytes);
  const components = result.document.components;
  const rankings = components.filter((component) => component.id.startsWith('source-home-ranking-section:'));
  assert.deepEqual(rankings.map((component) => component.title), categories.map((category) => `${category.title}排行榜`));
  assert.deepEqual(rankings.map((component) => component.children[1].categories[0].target), categories.map((category) => `category:${category.id}`));
  assert.ok(rankings.every((component) => component.children[0].items.length === 3));
  assert.equal(components.find((component) => component.id === 'source-featured-section').children[0].items.length, 4);
  assert.equal(components.find((component) => component.id === 'source-popular-section').children[0].items.length, 10);
  assert.equal(components.find((component) => component.id === 'source-latest-section').children[1].categories[0].target, 'library:latest');
  assert.equal(components.find((component) => component.id === 'source-originals-section').children[1].categories[0].target, 'library:original');
  for (const target of ['library:original', 'library:latest']) {
    const list = await source.discover(request(target));
    assert.equal(collectDiscoveryContent(list).length, 20);
    assert.equal(list.document.components.some((component) => component.type === 'filters'), target !== 'library:original');
  }
});

test('category and sorting preserve each other and reset pagination when a filter changes', async (t) => {
  const { source, requests } = await fixture(t);
  const category = await source.discover(request('category:71'));
  const filters = category.document.components.find((component) => component.type === 'filters');
  const byWord = filters.groups[1].options.find((option) => option.id === 'word').target;
  const sorted = await source.discover(request(byWord));
  const sortedFilters = sorted.document.components.find((component) => component.type === 'filters');
  assert.equal(sortedFilters.groups[0].selectedOptionId, '71');
  assert.equal(sortedFilters.groups[1].selectedOptionId, 'word');
  const urban = sortedFilters.groups[0].options.find((option) => option.id === '64').target;
  const urbanResult = await source.discover(request(urban));
  assert.equal(urbanResult.document.components[0].groups[1].selectedOptionId, 'word');
  assert.ok(requests.includes('/all/id/71/order/word+desc.html'));
  assert.ok(requests.includes('/all/id/64/order/word+desc.html'));
  const all = urbanResult.document.components[0].groups[0].options.find((option) => option.id === 'all').target;
  await source.discover(request(all));
  assert.ok(requests.includes('/all/order/word+desc.html'));
  const before = requests.length;
  await assert.rejects(source.discover(request('browse:64:word', {
    collectionId: 'category-books:71', cursor: 'browse-page:1:20',
  })), /continuation/u);
  await assert.rejects(source.discover(request('browse:999:word')), /target/u);
  assert.equal(requests.length, before);
});

for (const target of ['category:71', 'browse:71:word', 'library:original', 'library:latest']) {
  test(`${target} returns all 50 rows before following the site's next page`, async (t) => {
    const { source } = await fixture(t);
    let result = await source.discover(request(target));
    const ids = [];
    const sizes = [];
    for (let attempt = 0; attempt < 4; attempt += 1) {
      const contents = collectDiscoveryContent(result);
      ids.push(...contents.map((content) => content.id));
      sizes.push(contents.length);
      const [continuation] = collectDiscoveryContinuations(result);
      if (continuation === undefined) break;
      assert.equal(continuation.target, target);
      result = await source.discover(request(target, continuation));
    }
    assert.deepEqual(sizes, [20, 20, 10, 3]);
    assert.deepEqual(ids, Array.from({ length: 53 }, (_, i) => `novel:${i + 1}`));
    assert.equal(new Set(ids).size, ids.length);
  });
}

test('a full last website page does not invent another page and pagination links cannot escape the selected route', async (t) => {
  const { source } = await fixture(t, { next: false });
  let result = await source.discover(request('browse:71:hits'));
  for (let attempt = 0; attempt < 2; attempt += 1) {
    result = await source.discover(request('browse:71:hits', collectDiscoveryContinuations(result)[0]));
  }
  assert.equal(collectDiscoveryContent(result).length, 10);
  assert.deepEqual(collectDiscoveryContinuations(result), []);
  const base = new URL('https://www.alicesw.com/all/id/71/order/hits+desc.html');
  for (const href of ['https://example.com/all/id/71/order/hits+desc.html?page=2', '/all/id/64/order/hits+desc.html?page=2', `${base.pathname}?page=3`]) {
    assert.equal(browseNextPage(`<ul class="pagination"><li><a href="${href}">下一页</a></li></ul>`, base, 1), null);
  }
  assert.equal(browsePath(browseState('library:original', categories)), '/original.html');
  assert.equal(browseTarget(browseState('browse:71:word', categories)), 'browse:71:word');
});
