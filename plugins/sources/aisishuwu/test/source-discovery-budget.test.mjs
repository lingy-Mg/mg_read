/**
 * 发现载荷的离线回归：长封面代理 URL、中文/转义文本、嵌套首页和分类追加。
 * 验证实际返回字节与稳定身份，完整详情必须保持不变；不访问线上站点。
 */
import assert from 'node:assert/strict';
import test from 'node:test';
import { collectDiscoveryContent, createSourceTestHarness } from '@mgread/source-testkit';
import { AliceBookHouseSource } from '../dist/source.js';
import {
  compactDiscoveryResult, discoveryPayloadBytes, discoveryPayloadMaximumBytes,
} from '../dist/source-discovery-budget.js';

const coverUrl = `http://127.0.0.1:54321/v1/source-resource/${'x'.repeat(360)}`;
const description = '中文简介😀"\\\n'.repeat(500);
const summary = Object.freeze({
  id: 'novel:1', title: '测试小说', contentKind: 'novel', author: '作者',
  url: 'https://www.alicesw.com/novel/1.html', coverUrl, description,
  language: 'zh-CN', status: 'ongoing', access: 'unknown', wordCount: 12345,
  chapterCount: 67, publishedAt: null, updatedAt: null,
  latestChapter: Object.freeze({
    id: 'chapter:L2Jvb2svMS9sYXRlc3QuaHRtbA', title: '最新章节',
    url: 'https://www.alicesw.com/book/1/latest.html', updatedAt: null,
  }),
  categories: Object.freeze(['科幻']), tags: Object.freeze(['标签一', '标签二', '标签三', '标签四']),
  attributes: Object.freeze([{ key: 'heat', label: '热度', value: '12345' }]),
});
const items = Object.freeze(Array.from({ length: 50 }, (_, index) => Object.freeze({
  content: Object.freeze({ ...summary, id: `novel:${index + 1}` }),
  rank: null, metric: Object.freeze({ label: '热度', value: '1.2万' }), recommendation: null,
})));
const continuation = Object.freeze({ target: 'category:71', cursor: 'category-page:2' });

test('keeps small results unchanged and compacts nested documents and append results by UTF-8 bytes', () => {
  const small = Object.freeze({ kind: 'document', document: Object.freeze({ components: [] }) });
  assert.equal(compactDiscoveryResult(small), small);
  const collection = Object.freeze({
    type: 'contentCollection', id: 'books', layout: 'list', items, continuation,
  });
  const navigation = Object.freeze({ type: 'text', id: 'notice', text: '来源说明' });
  for (const original of [
    Object.freeze({ kind: 'document', document: Object.freeze({ components: [
      { type: 'group', id: 'group', layout: 'vertical', children: [
        { type: 'section', id: 'section', title: '小说', subtitle: null, children: [collection, navigation] },
      ] },
    ] }) }),
    Object.freeze({ kind: 'append', collectionId: 'books', items, continuation }),
  ]) {
    assert.ok(discoveryPayloadBytes(original) > 66730);
    const projected = compactDiscoveryResult(original);
    assert.ok(discoveryPayloadBytes(projected) <= discoveryPayloadMaximumBytes);
    const contents = collectDiscoveryContent(projected);
    assert.deepEqual(contents.map((content) => content.id), items.map((item) => item.content.id));
    for (const content of contents) {
      for (const key of ['title', 'author', 'coverUrl', 'wordCount', 'chapterCount']) {
        assert.deepEqual(content[key], summary[key]);
      }
      for (const key of ['id', 'title', 'updatedAt']) {
        assert.equal(content.latestChapter[key], summary.latestChapter[key]);
      }
      assert.ok(content.description === null || description.startsWith(content.description));
      assert.doesNotMatch(content.description ?? '', /[\uD800-\uDBFF]$/u);
      assert.ok(Object.isFrozen(content));
    }
    if (projected.kind === 'append') {
      assert.equal(projected.collectionId, 'books');
      assert.equal(projected.continuation, continuation);
    } else {
      const children = projected.document.components[0].children[0].children;
      assert.equal(children[0].continuation, continuation);
      assert.equal(children[1], navigation);
    }
  }
  assert.equal(items[0].content.description, description);
  assert.equal(items[0].content.tags.length, 4);
});

test('rejects an irreducible payload instead of dropping rows or breaking opaque cover URLs', () => {
  const oversized = {
    kind: 'append', collectionId: 'books', continuation: null,
    items: [{ ...items[0], content: { ...summary, coverUrl: `${coverUrl}${'x'.repeat(discoveryPayloadMaximumBytes + 1)}` } }],
  };
  assert.throws(() => compactDiscoveryResult(oversized), /identity and cover fields exceed/u);
});

test('public discovery bounds category, append, and full ranking after cover proxying without changing detail', async (t) => {
  const list = Array.from({ length: 50 }, (_, index) => `
    <article class="list-group-item"><a href="/novel/${index + 1}.html">小说${index + 1}</a>
    <a href="/lists/71.html">科幻</a></article>
  `).join('');
  const fullDescription = '用于验证完整详情不能被发现压缩修改。'.repeat(200);
  const harness = await createSourceTestHarness({
    plugin: { activate() {} }, pluginId: 'org.mgread.aisishuwu', version: '0.2.17',
    prefix: 'alice-discovery-budget-', resourceProxy: () => coverUrl,
    fetch: async (input) => {
      const url = new URL(input);
      if (!url.pathname.startsWith('/novel/')) return new Response(list);
      return new Response(`
        <h1 class="novel_title">小说</h1>
        <section class="pic"><img src="https://img.321cdn.com/covers/1.jpg"></section>
        <div class="novel_info"><a href="/lists/71.html">科幻</a><p>字 数：12345 · 章 节：67</p>
          <a href="/book/1/latest.html">最新章节</a></div>
        <div class="jianjie"><p>${fullDescription}</p></div>
      `);
    },
  });
  t.after(harness.cleanup);
  const source = new AliceBookHouseSource(harness.context, {
    origin: 'https://www.alicesw.com', categories: [{ id: '71', title: '科幻' }],
  });
  for (const request of [
    { target: 'category:71', cursor: null, collectionId: null, pageSize: 20 },
    { target: 'category:71', cursor: 'category-page:2', collectionId: 'category-books:71', pageSize: 20 },
    { target: 'ranking:day', cursor: null, collectionId: null, pageSize: 5 },
  ]) {
    const result = await source.discover(request);
    assert.ok(discoveryPayloadBytes(result) <= discoveryPayloadMaximumBytes);
    const contents = collectDiscoveryContent(result);
    assert.equal(contents.length, request.target.startsWith('ranking:') ? 50 : 20);
    assert.deepEqual(contents.map((content) => content.id), items.slice(0, contents.length).map((item) => item.content.id));
    assert.ok(contents.every((content) => content.coverUrl === coverUrl));
  }
  const detail = await source.getDetail({ id: 'novel:1' });
  assert.equal(detail.description, fullDescription);
  assert.equal(detail.chapterCount, 67);
  assert.equal(detail.url, 'https://www.alicesw.com/novel/1.html');
  assert.equal(detail.latestChapter.url, 'https://www.alicesw.com/book/1/latest.html');
});
