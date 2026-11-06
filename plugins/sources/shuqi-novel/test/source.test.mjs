/** Minimal fictional HTML fixtures cover canonical names, pagination and VIP boundaries. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { createSourceTestHarness } from '@mgread/source-testkit';

const detail = id => `<div class="view"><img src="https://img-tailor.11222.cn/bcv/big/${id}.jpg"></div>
  <span class="bname">正式书名${id}</span><div class="bauthor">作者：虚构作者</div><p class="bookDesc">虚构简介</p>
  <ul class="lastchapter"><li>虚构分类</li><li>0字</li><li>连载</li><li>2026-11-06 08:30更新</li></ul>`;
const catalog = `<div class="chapterbox"><div class="vol_name"><span>正文卷</span></div><table><tr>
  <td><a href="/reader?bid=1&cid=101">首章</a></td><td><a href="/reader?bid=1&cid=102">末章</a></td>
  <td><a href="/reader?bid=1&cid=103">付费章<i class="vip-tag">VIP</i></a></td></tr></table></div>`;
async function harness(t, custom) {
  const requests = [];
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.shuqi-novel', version: '1.0.0', fetch: async input => {
    const url = new URL(input); requests.push(url.href);
    const override = custom?.(url); if (override) return override;
    if (url.hostname.endsWith('.shuqireader.com')) {
      const cid = /_1_(\d+)_3111111111/u.exec(url.pathname)?.[1];
      return new Response('callback (' + JSON.stringify([{ id: cid, content: '<p>虚构第一段。</p><p>虚构第二段。</p>' }]) + ');');
    }
    if (url.pathname.startsWith('/book/')) return new Response(detail(/\d+/u.exec(url.pathname)[0]));
    if (url.pathname === '/chapter') return new Response(catalog);
    const start = url.searchParams.get('page') === '2' ? 4 : 1;
    return new Response(Array.from({ length: 3 }, (_, i) => `<a href="/book/${start + i}.html">宣传短标题${i}</a>`).join('') +
      '<a href="https://evil.example/book/999.html">外站</a>' +
      (url.pathname === '/search' && start === 1 ? `<a href="/search?keyword=${encodeURIComponent(url.searchParams.get('keyword'))}&page=2">下一页</a>` : ''));
  } });
  t.after(() => h.cleanup());
  return { h, requests };
}

test('discovery uses canonical titles and preserves remaining homepage items', async t => {
  const { h } = await harness(t);
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 });
  const c = root.document.components[0].children[0];
  assert.deepEqual(c.items.map(x => x.content.title), ['正式书名1', '正式书名2']);
  const next = await plugin.discover({ ...c.continuation, collectionId: c.id, pageSize: 2 });
  assert.equal(next.items[0].content.id, 'book:3');
  assert.equal(next.continuation, null);
  assert.ok(h.resourceRequests.every(x => x.kind === 'image' && new URL(x.url).hostname === 'img-tailor.11222.cn'));
});

test('discovery append uses its original snapshot even when recommendations rotate', async t => {
  let pages = 0;
  await harness(t, u => u.pathname === '/' ? new Response((++pages === 1 ? [1, 2, 3] : [3, 1, 2]).map(id => `<a href="/book/${id}.html">宣传</a>`).join('')) : null);
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 });
  const c = root.document.components[0].children[0];
  await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 });
  const next = await plugin.discover({ ...c.continuation, collectionId: c.id, pageSize: 2 });
  assert.equal(next.items[0].content.id, 'book:3');
  assert.equal(pages, 2);
});

test('search follows only the actual next link and does not drop partial pages', async t => {
  await harness(t);
  let cursor = null; const ids = [];
  do { const result = await plugin.search({ query: '虚构', cursor, pageSize: 2 }); ids.push(...result.items.map(x => x.id)); cursor = result.nextCursor; } while (cursor);
  assert.deepEqual(ids, ['book:1', 'book:2', 'book:3', 'book:4', 'book:5', 'book:6']);
  const first = await plugin.search({ query: '虚构', cursor: null, pageSize: 2 });
  await assert.rejects(plugin.search({ query: '其他', cursor: first.nextCursor, pageSize: 2 }), /another scope/);
});

test('catalog preserves source order, volumes and locks; VIP bodies are never fetched', async t => {
  const { requests } = await harness(t);
  const info = await plugin.getDetail({ id: 'book:1' });
  assert.equal(info.wordCount, 0); assert.equal(info.author, '虚构作者');
  const chapters = await plugin.getChapters({ id: 'book:1' });
  assert.deepEqual(chapters.items.map(x => x.isLocked), [false, false, true]);
  assert.equal(chapters.items[0].volumeTitle, '正文卷');
  const body = await plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:101' });
  assert.equal(body.text, '虚构第一段。\n\n虚构第二段。');
  const before = requests.length;
  await assert.rejects(plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:103' }));
  assert.equal(requests.length, before);
  await assert.rejects(plugin.getContent({ id: 'book:2', chapterId: 'chapter:1:101' }), /identity/);
});

test('mismatched chapter payloads and access-error pages are not accepted as prose', async t => {
  await harness(t, u => u.hostname.endsWith('.shuqireader.com') ? Response.json([{ id: '999', content: '不属于此章的虚构正文' }]) : null);
  await assert.rejects(plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:101' }));
  await harness(t, () => new Response('<title>访问限制</title>'));
  await assert.rejects(plugin.getDetail({ id: 'book:1' }));
});

test('a failed first official CDN can fall back to the second without accessing VIP content', async t => {
  const { requests } = await harness(t, u => { if (u.hostname === 'c1.shuqireader.com') throw new Error('network unavailable'); });
  const body = await plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:101' });
  assert.match(body.text, /虚构第一段/u);
  assert.ok(requests.some(u => u.startsWith('https://c2.shuqireader.com/')));
});
