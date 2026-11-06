/** Fictional fixtures cover real result pagination, metadata semantics and complete chapter identities. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { createSourceTestHarness } from '@mgread/source-testkit';

const info = id => `<article class="panel"><h3>《虚构作品${id}》</h3></article><div class="kv"><p>书籍作者：虚构作者</p><p>书籍分类：都市小说</p>
 <p>书籍大小：0KB</p><p>写作进度：已完结</p><p>上传时间：2026-11-06</p></div><div class="pic"><img src="https://image.jjjjxsw.com/UploadPic/2026-11/fiction.jpg"></div>
 <div class="intro-panel"><div class="desc">虚构作品简介</div></div>`;
const toc = id => `<ul class="chapter-list"><li><a href="/read/41/${id}/3.html">内容简介</a></li><li><a href="/read/41/${id}/7.html">虚构正文</a></li></ul>`;
function response(html, url) { const r = new Response(html); if (url) Object.defineProperty(r, 'url', { value: url }); return r; }
async function harness(t, custom) {
  const requests = [];
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.aijjxs-novel', version: '1.0.0', fetch: async (input, init) => {
    const u = new URL(input); requests.push(u.href); assert.equal(u.origin, 'https://www.aijjxs.com');
    assert.match(new Headers(init.headers).get('user-agent'), /^MgRead-Source\/1\.0\.0/u);
    const replacement = custom?.(u, init); if (replacement) return replacement;
    if (u.pathname === '/e/search/index.php') {
      assert.equal(init.method, 'POST'); const body = new URLSearchParams(init.body);
      assert.equal(body.get('keyboard'), '虚构'); assert.equal(body.get('show'), 'title,writer');
    }
    if (u.pathname === '/e/search/index.php' || u.pathname.startsWith('/search/')) {
      const page = u.pathname.includes('-1.html') ? 1 : 0, start = page ? 4 : 1;
      return response([start, start + 1, start + 2].map(id => `<div class="searchTopic"><a class="searchtitle" href="/txt/${id}.html">搜索结果</a></div>`).join('') +
        (page ? '' : '<a href="/search/result-1234-1.html">下一页</a>') + '<a href="/txt/99.html">无关页脚推荐</a>', `https://www.aijjxs.com/search/result-1234-${page}.html`);
    }
    const m = u.pathname.match(/^\/txt\/(\d+)\.html$/u); if (m) return response(info(m[1]));
    const c = u.pathname.match(/^\/read\/(\d+)\/$/u); if (c) return response(toc(c[1]));
    if (u.pathname.startsWith('/read/41/')) return response('<div id="view_content_txt"><p>虚构第一段。<script>untrusted()</script></p><p>虚构第二段。</p></div>');
    return response([1, 2, 3].map(id => `<a href="/txt/${id}.html">推荐</a>`).join(''));
  } });
  t.after(() => h.cleanup()); return { h, requests };
}
test('search keeps each upstream page remainder and binds continuation to its query', async t => {
  const { requests } = await harness(t); const ids = []; let cursor = null;
  do { const r = await plugin.search({ query: '虚构', cursor, pageSize: 2 }); ids.push(...r.items.map(x => x.id)); cursor = r.nextCursor; } while (cursor);
  assert.deepEqual(ids, ['book:1', 'book:2', 'book:3', 'book:4', 'book:5', 'book:6']);
  assert.equal(requests.filter(x => x.endsWith('/e/search/index.php')).length, 1);
  const first = await plugin.search({ query: '虚构', cursor: null, pageSize: 2 });
  await assert.rejects(plugin.search({ query: '其他', cursor: first.nextCursor, pageSize: 2 }), /another scope/);
});
test('metadata retains author/category while file size and upload date do not become word count or publication date', async t => {
  const { h } = await harness(t); const d = await plugin.getDetail({ id: 'book:1' });
  assert.equal(d.title, '虚构作品1'); assert.equal(d.author, '虚构作者'); assert.equal(d.status, 'completed');
  assert.equal(d.description, '虚构作品简介'); assert.equal(d.wordCount, null); assert.equal(d.publishedAt, null);
  assert.deepEqual(d.categories, ['都市小说']); assert.equal(h.resourceRequests[0].url, 'https://image.jjjjxsw.com/UploadPic/2026-11/fiction.jpg');
});
test('both observed cover month directories and protocol-relative URLs resolve to the verified CDN', async t => {
  const { h } = await harness(t, u => u.pathname.startsWith('/txt/') ? response(info('1').replace('https://image.jjjjxsw.com/UploadPic/2026-11/', '//image.jjjjxsw.com/UploadPic/202611/')) : null);
  assert.ok((await plugin.getDetail({ id: 'book:1' })).coverUrl);
  assert.equal(h.resourceRequests[0].url, 'https://image.jjjjxsw.com/UploadPic/202611/fiction.jpg');
});
test('chapter keys preserve source identity, including the source introduction item', async t => {
  await harness(t); const c = await plugin.getChapters({ id: 'book:1' });
  assert.deepEqual(c.items.map(x => x.id), ['chapter:1:3', 'chapter:1:7']);
  assert.deepEqual(c.items.map(x => x.order), [0, 1]); assert.equal(c.items[0].title, '内容简介');
  const body = await plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:7' });
  assert.equal(body.text, '虚构第一段。\n\n虚构第二段。');
  await assert.rejects(plugin.getContent({ id: 'book:2', chapterId: 'chapter:1:7' }), /identity/);
});
test('foreign, duplicate, empty or unexpectedly paginated catalogs cannot become partial success', async t => {
  for (const html of ['', toc('2'), toc('1').replace('/7.html', '/3.html'), toc('1') + '<a href="/read/1/?page=2">下一页</a>']) {
    await harness(t, u => u.pathname === '/read/1/' ? response(html) : null);
    await assert.rejects(plugin.getChapters({ id: 'book:1' }));
  }
});
test('search refuses a changed result identity and foreign redirects', async t => {
  await harness(t, u => u.pathname === '/e/search/index.php' ? response('<div class="searchTopic"><a class="searchtitle" href="/txt/1.html">结果</a></div><a href="/search/result-9999-1.html">下一页</a>', 'https://www.aijjxs.com/search/result-1234-0.html') : null);
  await assert.rejects(plugin.search({ query: '虚构', cursor: null, pageSize: 2 }), /next-page/);
  await harness(t, u => u.pathname === '/e/search/index.php' ? response('', 'https://unrelated.invalid/') : null);
  await assert.rejects(plugin.search({ query: '虚构', cursor: null, pageSize: 2 }));
});
test('missing or placeholder bodies and oversized text are rejected without clipping', async t => {
  for (const html of ['<p>验证页面</p>', '<div id="view_content_txt"><p>正在手打中，请稍后。</p></div>', `<div id="view_content_txt"><p>${'文'.repeat(20000)}</p></div>`]) {
    await harness(t, u => u.pathname.startsWith('/read/41/') ? response(html) : null);
    await assert.rejects(plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:7' }));
  }
});
test('over-limit catalogs fail and unrelated cover origins are never registered', async t => {
  await harness(t, u => u.pathname === '/read/1/' ? response(`<ul class="chapter-list">${Array.from({ length: 5001 }, (_, i) => `<li><a href="/read/41/1/${i + 1}.html">虚构章</a></li>`).join('')}</ul>`) : null);
  await assert.rejects(plugin.getChapters({ id: 'book:1' }), /not been truncated/);
  const { h } = await harness(t, u => u.pathname.startsWith('/txt/') ? response(info('1').replace('image.jjjjxsw.com', 'unrelated.invalid')) : null);
  assert.equal((await plugin.getDetail({ id: 'book:1' })).coverUrl, null); assert.equal(h.resourceRequests.length, 0);
});
test('homepage rotation keeps an existing recommendation continuation stable', async t => {
  let count = 0;
  await harness(t, u => u.pathname === '/' ? response((++count === 1 ? [1, 2, 3] : [3, 1, 2]).map(id => `<a href="/txt/${id}.html">推荐</a>`).join('')) : null);
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 }); const c = root.document.components[0].children[0];
  await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 });
  const next = await plugin.discover({ ...c.continuation, collectionId: c.id, pageSize: 2 });
  assert.equal(next.items[0].content.id, 'book:3'); assert.equal(next.continuation, null);
});
