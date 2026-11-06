/** Fictional fixtures test visible catalog semantics, complete multipart text and source identity. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { createSourceTestHarness } from '@mgread/source-testkit';

const info = id => `<meta property="og:novel:book_name" content="虚构作品${id}"><meta property="og:novel:author" content="虚构作者">
 <meta property="og:image" content="/img/${id}.jpg"><meta property="og:description" content="虚构简介">
 <meta property="og:novel:category" content="都市小说"><meta property="og:novel:status" content="连载中">
 <meta property="og:novel:update_time" content="2026-11-06 08:15:00">
 <meta property="og:novel:latest_chapter_name" content="末章"><meta property="og:novel:latest_chapter_url" content="https://www.snxsw.com/read/0/${id}/22.html">`;
const chapter = (key, title = `虚构${key}`) => `<li><a href="/read/0/1/${key}.html">${title}</a></li>`;
const root = id => info(id) + `<ul class="section-list">${chapter(22, '最新区')}</ul><ul class="section-list">${chapter(7)}</ul><a class="btn-mulu" href="/index/${id}/1/">查看更多章节...</a>`;
const page = `<style>.section-list.ycxsid>li:nth-child(1){display:none}.section-list.ycxsid>li:nth-child(2){display:none}.section-list.ycxsid>li:nth-last-child(1){display:none}</style>
 <select><option value="/book/1/">首页</option><option value="/index/1/1/">末页</option></select>
 <ul class="section-list ycxsid">${chapter(22, '隐藏重复')}${chapter(7, '隐藏重复')}${chapter(22)}${chapter(7, '隐藏重复')}</ul>
 <div class="page_num"><a href="/index/1/2/">下一页</a></div>`;
const encoded = value => `<script>document.write(qsbs.bb('${Buffer.from(`<p>${value}</p>`).toString('base64')}'));</script>`;
async function harness(t, custom) {
  const requests = [];
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.snxsw-novel', version: '1.0.0', fetch: async (input, init) => {
    const u = new URL(input); requests.push(u.href); assert.equal(u.origin, 'https://www.snxsw.com');
    assert.match(new Headers(init.headers).get('user-agent'), /^MgRead-Source\/1\.0\.0/u);
    const replacement = custom?.(u, init); if (replacement) return replacement;
    if (u.pathname === '/index/1/1/') return new Response(page);
    if (/^\/read\//u.test(u.pathname)) return new Response(`<div class="word_read"><h3>重复标题</h3>${encoded(u.pathname.includes('_1') ? '第二段正文。' : '第一段正文。')}</div>` +
      (u.pathname.includes('_1') ? '<a href="/read/0/1/99.html">下一章</a>' : `<a href="${u.pathname.replace('.html', '_1.html')}">下一章</a>`));
    const match = u.pathname.match(/^\/book\/(\d+)\/$/u);
    if (match) return new Response(root(match[1]));
    if (u.pathname === '/search.html') {
      assert.equal(init.method, 'POST'); assert.equal(new URLSearchParams(init.body).get('s'), '虚构');
      return new Response(`<ul class="txt-list">${[1, 2, 3].map(id => `<li><span class="s2"><a href="/book/${id}/">搜索</a></span></li>`).join('')}</ul><a href="/book/99/">无关页脚推荐</a>`);
    }
    return new Response([1, 2, 3].map(id => `<a href="/book/${id}/">推荐</a>`).join(''));
  } });
  t.after(() => h.cleanup()); return { h, requests };
}
test('search slices real results without including footer recommendations or losing the remainder', async t => {
  await harness(t); const first = await plugin.search({ query: '虚构', cursor: null, pageSize: 2 });
  assert.deepEqual(first.items.map(x => x.id), ['book:1', 'book:2']);
  const next = await plugin.search({ query: '虚构', cursor: first.nextCursor, pageSize: 2 });
  assert.deepEqual(next.items.map(x => x.id), ['book:3']); assert.equal(next.nextCursor, null);
  await assert.rejects(plugin.search({ query: '其他', cursor: first.nextCursor, pageSize: 2 }), /another scope/);
});
test('metadata is canonical and image registration rejects unrelated origins', async t => {
  const { h } = await harness(t); const d = await plugin.getDetail({ id: 'book:1' });
  assert.equal(d.author, '虚构作者'); assert.equal(d.description, '虚构简介'); assert.equal(d.wordCount, null);
  assert.equal(d.updatedAt, '2026-11-06T00:15:00.000Z'); assert.equal(d.latestChapter.id, 'chapter:1:22');
  assert.deepEqual(d.categories, ['都市小说']); assert.equal(h.resourceRequests[0].url, 'https://www.snxsw.com/img/1.jpg');
  const other = await harness(t, u => u.pathname.startsWith('/book/') ? new Response(info('1').replace('/img/1.jpg', 'https://unrelated.invalid/a.jpg')) : null);
  assert.equal((await plugin.getDetail({ id: 'book:1' })).coverUrl, null); assert.equal(other.h.resourceRequests.length, 0);
});
test('CSS positions resolve simultaneously and page options exclude the false out-of-range next link', async t => {
  const { requests } = await harness(t); const c = await plugin.getChapters({ id: 'book:1' });
  assert.deepEqual(c.items.map(x => x.id), ['chapter:1:7', 'chapter:1:22']);
  assert.deepEqual(c.items.map(x => x.order), [0, 1]); assert.equal(requests.some(x => x.includes('/index/1/2/')), false);
});
test('public Base64 paragraphs and all same-chapter parts form one content item', async t => {
  await harness(t); const body = await plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:7' });
  assert.equal(body.text, '第一段正文。\n\n第二段正文。'); assert.equal(body.chapterId, 'chapter:1:7');
  await assert.rejects(plugin.getContent({ id: 'book:2', chapterId: 'chapter:1:7' }), /identity/);
});
test('missing, duplicate and incorrectly scoped catalog pages never return a partial list', async t => {
  for (const html of ['', page.replace(chapter(22), chapter(7)), page.replace('value="/index/1/1/"', 'value="/index/2/1/"')]) {
    await harness(t, u => u.pathname === '/index/1/1/' ? new Response(html) : null);
    await assert.rejects(plugin.getChapters({ id: 'book:1' }));
  }
});
test('missing/looping parts and source placeholders fail without returning incomplete prose', async t => {
  for (const html of ['<div class="word_read"></div>', `<div class="word_read">${encoded('正在手打中，请稍等片刻。')}</div>`, `<div class="word_read">${encoded('虚构正文。')}</div><a href="/read/0/1/7_1.html">下一章</a>`]) {
    await harness(t, u => u.pathname.endsWith('_1.html') ? new Response(html) : null);
    await assert.rejects(plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:7' }));
  }
});
test('large chapters and catalogs explicitly fail without truncation', async t => {
  await harness(t, u => u.pathname.startsWith('/read/') ? new Response(`<div class="word_read">${encoded('文'.repeat(20000))}</div>`) : null);
  await assert.rejects(plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:7' }), /not been truncated/);
  await harness(t, u => u.pathname.startsWith('/book/') ? new Response(`<ul class="section-list">${Array.from({ length: 5001 }, (_, i) => chapter(i + 1)).join('')}</ul>`) : null);
  await assert.rejects(plugin.getChapters({ id: 'book:1' }), /not been truncated/);
});
test('existing recommendation continuation remains stable after a homepage rotation', async t => {
  let count = 0;
  await harness(t, u => u.pathname === '/' ? new Response((++count === 1 ? [1, 2, 3] : [3, 1, 2]).map(id => `<a href="/book/${id}/">推荐</a>`).join('')) : null);
  const first = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 }); const c = first.document.components[0].children[0];
  await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 });
  const next = await plugin.discover({ ...c.continuation, collectionId: c.id, pageSize: 2 });
  assert.equal(next.items[0].content.id, 'book:3'); assert.equal(next.continuation, null);
});
