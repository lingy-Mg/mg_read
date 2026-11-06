/** Fictional data verifies HTML+JSONP catalog completeness without evaluating source scripts. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { createSourceTestHarness } from '@mgread/source-testkit';

const info = slug => `<meta property="og:novel:book_name" content="虚构作品${slug}"><meta property="og:novel:author" content="虚构作者">
 <meta property="og:description" content="虚构简介"><meta property="og:image" content="https://img.c0m.io/quanben.io/upload/thumbnail/book_0_999/book_3.jpg">
 <meta property="og:novel:category" content="玄幻小说"><meta property="og:novel:status" content="完结">`;
const link = (slug, key) => `<li><a href="/n/${slug}/${key}.html">虚构章节${key}</a></li>`;
const catalog = slug => `<ul class="list3">${link(slug, 7)}</ul><script>var callback = 'fictionCb';load_more('3');</script><ul class="list3">${link(slug, 20)}</ul>`;
async function harness(t, custom) {
  const requests = [];
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.quanben-novel', version: '1.0.0', fetch: async (input, init) => {
    const u = new URL(input); requests.push(u.href); assert.equal(u.origin, 'https://www.quanben.io');
    assert.match(new Headers(init.headers).get('user-agent'), /^MgRead-Source\/1\.0\.0/u);
    const replacement = custom?.(u, init); if (replacement) return replacement;
    if (u.searchParams.get('a') === 'list.jsonp') {
      assert.equal(new Headers(init.headers).get('referer'), 'https://www.quanben.io/n/fiction_a/list.html');
      assert.equal(u.searchParams.get('book_id'), '3');
      const alphabet = 'PXhw7UT1B0a9kQDKZsjIASmOezxYG4CHo5Jyfg2b8FLpEvRr3WtVnlqMidu6cN';
      const encoded = u.searchParams.get('b'), cb = u.searchParams.get('callback');
      assert.equal(encoded.length, cb.length * 3);
      assert.equal([...cb].map((_, i) => { const c = encoded[i * 3 + 1], pos = alphabet.indexOf(c); return pos < 0 ? c : alphabet[(pos + 59) % 62]; }).join(''), cb);
      return new Response(`d${cb} (${JSON.stringify({ id: 3, content: link('fiction_a', 11) })});`);
    }
    const m = u.pathname.match(/^\/n\/([a-z0-9_-]+)\/(.*)$/u);
    if (m?.[2] === 'list.html') return new Response(catalog(m[1]));
    if (m?.[2].endsWith('.html')) return new Response('<h1>虚构章节7</h1><div id="content"><p>虚构章节7</p><p>虚构第一段。</p><p>虚构第二段。</p></div>');
    if (m) return new Response(info(m[1]));
    const ids = ['fiction_a', 'fiction_b', 'fiction_c'];
    if (u.searchParams.get('a') === 'search') return new Response(ids.map(id => `<div class="row"><div class="list2"><h3><a href="/n/${id}/">搜索</a></h3></div></div>`).join('') + '<a href="/n/unrelated/">页脚推荐</a>');
    return new Response(ids.map(id => `<a href="/n/${id}/">推荐</a>`).join(''));
  } });
  t.after(() => h.cleanup()); return { h, requests };
}
test('search retains all source results and excludes unrelated footer links', async t => {
  await harness(t); const first = await plugin.search({ query: '虚构', cursor: null, pageSize: 2 });
  assert.deepEqual(first.items.map(x => x.id), ['book:fiction_a', 'book:fiction_b']);
  const next = await plugin.search({ query: '虚构', cursor: first.nextCursor, pageSize: 2 });
  assert.deepEqual(next.items.map(x => x.id), ['book:fiction_c']); assert.equal(next.nextCursor, null);
  await assert.rejects(plugin.search({ query: '其他', cursor: first.nextCursor, pageSize: 2 }), /another scope/);
});
test('HTML head, JSONP middle and HTML tail form one ordered catalog with upstream IDs', async t => {
  await harness(t); const c = await plugin.getChapters({ id: 'book:fiction_a' });
  assert.deepEqual(c.items.map(x => x.id), ['chapter:fiction_a:7', 'chapter:fiction_a:11', 'chapter:fiction_a:20']);
  assert.deepEqual(c.items.map(x => x.order), [0, 1, 2]);
  const body = await plugin.getContent({ id: 'book:fiction_a', chapterId: c.items[0].id });
  assert.equal(body.text, '虚构第一段。\n\n虚构第二段。');
  await assert.rejects(plugin.getContent({ id: 'book:fiction_b', chapterId: c.items[0].id }), /identity/);
});
test('the upstream envelope label may start with a digit and is never treated as JavaScript', async t => {
  await harness(t, u => u.pathname.endsWith('/list.html') ? new Response(catalog('fiction_a').replaceAll('fictionCb', '123abc')) : null);
  assert.equal((await plugin.getChapters({ id: 'book:fiction_a' })).items.length, 3);
});
test('missing middle, foreign book identity and executable envelopes cannot become a partial catalog', async t => {
  for (const response of [JSON.stringify({ id: 3, content: '' }), JSON.stringify({ id: 4, content: link('fiction_a', 11) }), null]) {
    await harness(t, u => u.searchParams.get('a') === 'list.jsonp' ? new Response(response ? `dfictionCb(${response});` : `globalThis.untrustedExecuted=true;dfictionCb({});`) : null);
    await assert.rejects(plugin.getChapters({ id: 'book:fiction_a' }));
    assert.equal(globalThis.untrustedExecuted, undefined);
  }
});
test('duplicate catalog IDs and over-limit catalogs fail without truncation', async t => {
  await harness(t, u => u.searchParams.get('a') === 'list.jsonp' ? new Response(`dfictionCb(${JSON.stringify({ id: 3, content: link('fiction_a', 7) })})`) : null);
  await assert.rejects(plugin.getChapters({ id: 'book:fiction_a' }), /duplicate/);
  await harness(t, u => u.pathname.endsWith('/list.html') ? new Response(`<ul class="list3">${Array.from({ length: 5001 }, (_, i) => link('fiction_a', i + 1)).join('')}</ul>`) : null);
  await assert.rejects(plugin.getChapters({ id: 'book:fiction_a' }), /not been truncated/);
});
test('source URL slug stays stable while metadata changes, and unknown fields stay null', async t => {
  const { h } = await harness(t); const d = await plugin.getDetail({ id: 'book:fiction_a' });
  assert.equal(d.id, 'book:fiction_a'); assert.equal(d.author, '虚构作者'); assert.equal(d.status, 'completed');
  assert.equal(d.wordCount, null); assert.equal(d.updatedAt, null); assert.equal(d.latestChapter, null);
  assert.ok(h.resourceRequests.every(x => x.url === 'https://img.c0m.io/quanben.io/upload/thumbnail/book_0_999/book_3.jpg'));
  const other = await harness(t, u => u.pathname === '/n/fiction_a/' ? new Response(info('fiction_a').replace('img.c0m.io', 'unrelated.invalid')) : null);
  assert.equal((await plugin.getDetail({ id: 'book:fiction_a' })).coverUrl, null); assert.equal(other.h.resourceRequests.length, 0);
});
test('placeholder, empty and oversized content fails rather than masquerading as a chapter', async t => {
  for (const text of ['', '正在手打中，请稍等片刻。', '文'.repeat(20000)]) {
    await harness(t, u => /\/7\.html$/u.test(u.pathname) ? new Response(`<div id="content"><p>${text}</p></div>`) : null);
    await assert.rejects(plugin.getContent({ id: 'book:fiction_a', chapterId: 'chapter:fiction_a:7' }));
  }
});
test('recommendation snapshots keep continuation order across homepage rotations', async t => {
  let count = 0;
  await harness(t, u => u.pathname === '/' ? new Response((++count === 1 ? ['fiction_a', 'fiction_b', 'fiction_c'] : ['fiction_c', 'fiction_a', 'fiction_b']).map(id => `<a href="/n/${id}/">推荐</a>`).join('')) : null);
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 }); const c = root.document.components[0].children[0];
  await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 });
  const next = await plugin.discover({ ...c.continuation, collectionId: c.id, pageSize: 2 });
  assert.equal(next.items[0].content.id, 'book:fiction_c'); assert.equal(next.continuation, null);
});
