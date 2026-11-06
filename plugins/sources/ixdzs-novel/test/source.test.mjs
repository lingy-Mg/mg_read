/** Fictional fixtures verify canonical metadata, snapshot paging and upstream chapter keys. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { createSourceTestHarness } from '@mgread/source-testkit';

const detail = id => `<meta property="og:novel:book_name" content="虚构作品${id}">
  <meta property="og:novel:author" content="虚构作者"><meta property="og:image" content="https://img22.ixdzs.com/ab/cd/abcdef0123456789abcdef0123456789.jpg">
  <meta property="og:novel:status" content="连载中"><meta property="og:novel:update_time" content="2026-11-06T08:00:00+08:00">
  <span class="nsize">0字</span><p id="intro">虚构作品简介</p>`;
const rows = [{ ctype: '1', title: '虚构卷' }, { ctype: '0', ordernum: '7', title: '首章' }, { ctype: '0', ordernum: '11', title: '末章' }];
async function harness(t, custom) {
  const requests = [];
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.ixdzs-novel', version: '1.0.0', fetch: async (input, init) => {
    const url = new URL(input); requests.push(url.href);
    assert.equal(url.origin, 'https://ixdzs8.com');
    assert.match(new Headers(init.headers).get('user-agent'), /^MgRead-Source\/1\.0\.0/u);
    assert.equal(url.searchParams.has('challenge'), false);
    const override = custom?.(url, init); if (override) return override;
    if (url.pathname === '/novel/clist/') {
      assert.equal(init.method, 'POST'); assert.equal(String(init.body), 'bid=1');
      return Response.json({ rs: true, data: rows });
    }
    if (/\/p\d+\.html$/u.test(url.pathname)) return new Response('<section><p>虚构第一段。</p><p>虚构第二段。</p></section>');
    const m = /^\/read\/(\d+)\/$/u.exec(url.pathname);
    if (m) return new Response(detail(m[1]));
    const start = url.searchParams.get('page') === '2' ? 4 : 1;
    return new Response(Array.from({ length: 3 }, (_, i) => `<a href="/read/${start + i}/">书籍</a>`).join('') +
      (url.pathname === '/bsearch' && start === 1 ? `<a href="/bsearch?q=${encodeURIComponent(url.searchParams.get('q'))}&page=2">下一页</a>` : ''));
  } });
  t.after(() => h.cleanup());
  return { h, requests };
}

test('search page-size slicing keeps every book and cursor belongs to its query', async t => {
  await harness(t);
  let cursor = null; const ids = [];
  do { const result = await plugin.search({ query: '虚构', cursor, pageSize: 2 }); ids.push(...result.items.map(x => x.id)); cursor = result.nextCursor; } while (cursor);
  assert.deepEqual(ids, ['book:1', 'book:2', 'book:3', 'book:4', 'book:5', 'book:6']);
  const first = await plugin.search({ query: '虚构', cursor: null, pageSize: 2 });
  await assert.rejects(plugin.search({ query: '其他', cursor: first.nextCursor, pageSize: 2 }), /another scope/);
});

test('upstream chapter keys are preserved instead of array indexes; volumes remain metadata', async t => {
  const { h } = await harness(t);
  const info = await plugin.getDetail({ id: 'book:1' });
  assert.equal(info.wordCount, 0); assert.equal(info.author, '虚构作者');
  assert.equal(info.updatedAt, '2026-11-06T00:00:00.000Z');
  const catalog = await plugin.getChapters({ id: 'book:1' });
  assert.deepEqual(catalog.items.map(x => x.id), ['chapter:1:7', 'chapter:1:11']);
  assert.ok(catalog.items.every(x => x.volumeTitle === '虚构卷'));
  const body = await plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:11' });
  assert.equal(body.text, '虚构第一段。\n\n虚构第二段。');
  assert.ok(h.resourceRequests.length > 0);
  assert.ok(h.resourceRequests.every(x => x.url === 'https://img22.ixdzs.com/ab/cd/abcdef0123456789abcdef0123456789.jpg'));
  await assert.rejects(plugin.getContent({ id: 'book:2', chapterId: 'chapter:1:11' }), /identity/);
});

test('discovery snapshots survive rotations of recommendations', async t => {
  let count = 0;
  await harness(t, u => u.pathname === '/' ? new Response((++count === 1 ? [1, 2, 3] : [3, 1, 2]).map(id => `<a href="/read/${id}/">推荐</a>`).join('')) : null);
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 });
  const c = root.document.components[0].children[0];
  await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 });
  const next = await plugin.discover({ ...c.continuation, collectionId: c.id, pageSize: 2 });
  assert.equal(next.items[0].content.id, 'book:3'); assert.equal(next.continuation, null);
});

test('duplicate and oversized catalogs are rejected without truncation', async t => {
  await harness(t, u => u.pathname === '/novel/clist/' ? Response.json({ data: [rows[1], rows[1]] }) : null);
  await assert.rejects(plugin.getChapters({ id: 'book:1' }), /duplicate/);
  await harness(t, u => u.pathname === '/novel/clist/' ? Response.json({ data: Array.from({ length: 5001 }, (_, i) => ({ ctype: '0', ordernum: String(i + 1), title: '虚构章' })) }) : null);
  await assert.rejects(plugin.getChapters({ id: 'book:1' }), /host limit/);
});

test('challenge pages fail without constructing verification URLs; large text is not clipped', async t => {
  const { requests } = await harness(t, u => /\/p\d+\.html$/u.test(u.pathname) ? new Response('<script>var token="fictional";</script><p>请求验证</p>') : null);
  await assert.rejects(plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:7' }));
  assert.equal(requests.length, 2);
  await harness(t, u => /\/p\d+\.html$/u.test(u.pathname) ? new Response(`<section><p>${'文'.repeat(20000)}</p></section>`) : null);
  await assert.rejects(plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:7' }), /not been truncated/);
});

test('source None and nopic placeholders are not registered as real covers', async t => {
  const { h } = await harness(t, u => /^\/read\/\d+\/$/u.test(u.pathname) ? new Response(detail('1').replace('ab/cd/abcdef0123456789abcdef0123456789.jpg', 'None')) : null);
  const info = await plugin.getDetail({ id: 'book:1' });
  assert.equal(info.coverUrl, null); assert.equal(h.resourceRequests.length, 0);
});
