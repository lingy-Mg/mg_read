/** Fictional GB18030 pages verify official identities, paging, volumes and locked-access boundaries. */
import assert from 'node:assert/strict';
import test from 'node:test';
import iconv from 'iconv-lite';
import * as plugin from '../dist/index.mjs';
import { createSourceTestHarness } from '@mgread/source-testkit';

const row = (id, key, options = {}) => `<tr itemprop="chapter"><td>${options.number ?? key}</td><td><span itemprop="headline">${options.noLink ? '该章节已被锁定' :
  `<a itemprop="url" ${options.locked ? 'rel' : 'href'}="http://${options.locked ? 'my' : 'www'}.jjwxc.net/${options.locked ? 'onebook_vip' : 'onebook'}.php?novelid=${id}&chapterid=${key}">虚构章节${key}</a>${options.locked ? '[VIP]' : ''}`}</span></td><td>虚构提要</td><td itemprop="wordCount">0</td><td>0</td><td>2026-11-06 08:15:00</td></tr>`;
const table = id => `<table id="oneboolt"><tr><td>章节</td><td>标题</td></tr><tr><td colspan="6">第一卷</td></tr>${row(id, 7, { number: 1 })}${row(id, 20, { number: 2 })}${row(id, 99, { locked: true })}${row(id, 41, { noLink: true })}</table>`;
const info = id => `<h1>虚构作品${id}</h1><span itemprop="author">虚构作者</span><span itemprop="wordCount">0字</span><span itemprop="updataStatus">连载</span>
 <span itemprop="genre">原创-言情-古色古香-剧情</span><div id="novelintro">虚构简介</div><img class="noveldefaultimage" src="https://i1-static.jjwxc.net/tmp/backend/authorspace/fiction.jpg">`;
function response(text, url) { const r = new Response(iconv.encode(text, 'gb18030'), { headers: { 'Content-Type': 'text/html; charset=gb18030' } });
  if (url) Object.defineProperty(r, 'url', { value: url }); return r; }
async function harness(t, custom) {
  const requests = [];
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.jjwxc-novel', version: '1.0.0', fetch: async (input, init) => {
    const u = new URL(input); requests.push(u.href);
    assert.ok(['https://m.jjwxc.net', 'https://www.jjwxc.net'].includes(u.origin));
    assert.equal(new Headers(init.headers).has('cookie'), false);
    assert.match(new Headers(init.headers).get('user-agent'), /^MgRead-Source\/1\.0\.0/u);
    const replacement = custom?.(u, init); if (replacement) return replacement;
    if (u.pathname.startsWith('/search')) {
      assert.match(u.search, /kw=%D0%E9%B9%B9/u, 'Chinese query must use the observed GB18030 bytes, not UTF-8.');
      const second = u.pathname.endsWith('/2'), start = second ? 4 : 1;
      return response([start, start + 1, start + 2].map(id => `<a href="/book2/${id}">作品</a>`).join('') +
        (second ? '' : '<a href="/search/index/page/2?version=1&kw=%D0%E9%B9%B9&t=1">下一页</a>'));
    }
    if (u.pathname === '/onebook.php') { const id = u.searchParams.get('novelid'); return response(info(id) + table(id)); }
    if (/^\/book2\/\d+\/\d+$/u.test(u.pathname)) return response('<ul class="content_ul"><li>虚构第一段。<br><br>虚构第二段。<script>untrusted()</script></li></ul><div>作者备注不进入正文</div>');
    return response([1, 2, 3].map(id => `<a href="https://m.jjwxc.net/book2/${id}">推荐</a>`).join(''));
  } });
  t.after(() => h.cleanup()); return { h, requests };
}
test('GB18030 search and upstream paging preserve every page remainder', async t => {
  await harness(t); let cursor = null; const ids = [];
  do { const r = await plugin.search({ query: '虚构', cursor, pageSize: 2 }); ids.push(...r.items.map(x => x.id)); cursor = r.nextCursor; } while (cursor);
  assert.deepEqual(ids, ['book:1', 'book:2', 'book:3', 'book:4', 'book:5', 'book:6']);
  const first = await plugin.search({ query: '虚构', cursor: null, pageSize: 2 });
  await assert.rejects(plugin.search({ query: '其他', cursor: first.nextCursor, pageSize: 2 }), /another scope/);
});
test('same-name results with no official chapter records are omitted while published results retain their order', async t => {
  await harness(t, u => u.pathname === '/onebook.php' && u.searchParams.get('novelid') === '1' ? response(info('1')) : null);
  const result = await plugin.search({ query: '虚构', cursor: null, pageSize: 2 });
  assert.deepEqual(result.items.map(x => x.id), ['book:2', 'book:3']);
  assert.equal((await plugin.getDetail({ id: 'book:1' })).chapterCount, 0);
  const next = await plugin.search({ query: '虚构', cursor: result.nextCursor, pageSize: 2 });
  assert.deepEqual(next.items.map(x => x.id), ['book:4', 'book:5']);
});
test('official metadata decodes correctly and preserves zero rather than converting it to unknown', async t => {
  const { h } = await harness(t); const d = await plugin.getDetail({ id: 'book:1' });
  assert.equal(d.title, '虚构作品1'); assert.equal(d.author, '虚构作者'); assert.equal(d.wordCount, 0); assert.equal(d.status, 'ongoing');
  assert.equal(d.description, '虚构简介'); assert.deepEqual(d.categories, ['原创-言情-古色古香-剧情']);
  assert.equal(h.resourceRequests[0].url, 'https://i1-static.jjwxc.net/tmp/backend/authorspace/fiction.jpg');
});
test('catalog keeps upstream keys, volumes, VIP and unavailable chapter rows without using array indexes', async t => {
  await harness(t); const c = await plugin.getChapters({ id: 'book:1' });
  assert.deepEqual(c.items.map(x => x.id), ['chapter:1:7', 'chapter:1:20', 'chapter:1:99', 'chapter:1:41']);
  assert.deepEqual(c.items.map(x => x.order), [0, 1, 2, 3]); assert.deepEqual(c.items.map(x => x.isLocked), [false, false, true, true]);
  assert.ok(c.items.every(x => x.volumeTitle === '第一卷' && x.wordCount === 0));
  assert.equal(c.items[0].updatedAt, '2026-11-06T00:15:00.000Z');
});
test('locked chapters never trigger a body request; public content excludes notes and scripts', async t => {
  const { requests } = await harness(t);
  await assert.rejects(plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:99' }));
  await assert.rejects(plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:41' }));
  assert.equal(requests.length, 1);
  const body = await plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:7' });
  assert.equal(body.text, '虚构第一段。\n\n虚构第二段。');
  await assert.rejects(plugin.getContent({ id: 'book:2', chapterId: 'chapter:1:7' }), /identity/);
});
test('duplicate, foreign or empty official catalogs fail rather than losing rows', async t => {
  for (const html of ['', table('2'), table('1').replace('chapterid=20', 'chapterid=7')]) {
    await harness(t, u => u.pathname === '/onebook.php' ? response(html) : null);
    await assert.rejects(plugin.getChapters({ id: 'book:1' }));
  }
});
test('absent and oversized public content is rejected without truncation', async t => {
  for (const html of ['<p>请登录后阅读</p>', `<ul class="content_ul"><li>${'文'.repeat(20000)}</li></ul>`]) {
    await harness(t, u => u.pathname.startsWith('/book2/') ? response(html) : null);
    await assert.rejects(plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:7' }));
  }
});
test('host catalog limit and official origin boundaries remain explicit', async t => {
  await harness(t, u => u.pathname === '/onebook.php' ? response(`<table id="oneboolt">${Array.from({ length: 5001 }, (_, i) => row('1', i + 1)).join('')}</table>`) : null);
  await assert.rejects(plugin.getChapters({ id: 'book:1' }), /not been truncated/);
  const { h } = await harness(t, u => u.pathname === '/onebook.php' ? response(info('1').replace('i1-static.jjwxc.net', 'unrelated.invalid')) : null);
  assert.equal((await plugin.getDetail({ id: 'book:1' })).coverUrl, null); assert.equal(h.resourceRequests.length, 0);
  await harness(t, u => u.pathname === '/onebook.php' ? response('', 'https://my.jjwxc.net/login') : null);
  await assert.rejects(plugin.getDetail({ id: 'book:1' }));
});
test('recommendation snapshots survive a changed homepage order', async t => {
  let count = 0;
  await harness(t, u => u.pathname === '/' ? response((++count === 1 ? [1, 2, 3] : [3, 1, 2]).map(id => `<a href="/book2/${id}">推荐</a>`).join('')) : null);
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 }); const c = root.document.components[0].children[0];
  await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 });
  const next = await plugin.discover({ ...c.continuation, collectionId: c.id, pageSize: 2 });
  assert.equal(next.items[0].content.id, 'book:3'); assert.equal(next.continuation, null);
});
