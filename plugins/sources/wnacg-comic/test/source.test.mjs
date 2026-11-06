/** Fictional albums verify pagination, exact page counts and signature-independent page identities. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { createSourceTestHarness } from '@mgread/source-testkit';

const info = (id, count = 2) => `<div class="asTBcell uwthumb"><img alt="虚构图集${id}" src="////t4.qy0.ru/data/t/0/${id}/cover.jpg"></div><div class="asTBcell uwconn"><label>分類：一般向</label><label>頁數：${count}P</label></div>`;
const images = (nonce, count = 2) => `<script>var fast_img_host="";var imglist = [${Array.from({ length: count }, (_, i) => `{url: fast_img_host+"//img5.qy0.ru/data/0/1/${String(i).padStart(4, '0')}.jpg?verify=${nonce}", caption:"页面"}`).join(',')},{url:"https://unrelated.invalid/banner.jpg",caption:"广告"}];globalThis.untrustedExecuted=true;</script>`;
async function harness(t, custom) {
  const requests = [];
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.wnacg-comic', version: '1.0.0', fetch: async (input, init) => {
    const u = new URL(input); requests.push(u.href); assert.equal(u.origin, 'https://www.wnacg.com');
    assert.equal(new Headers(init.headers).has('cookie'), false); assert.match(new Headers(init.headers).get('user-agent'), /^MgRead-Source\/1\.0\.0/u);
    const replacement = custom?.(u, init); if (replacement) return replacement;
    const m = u.pathname.match(/^\/photos-index-aid-(\d+)\.html$/u); if (m) return new Response(info(m[1]));
    if (u.pathname.includes('photos-gallery')) return new Response(images('initial'));
    const second = u.searchParams.get('p') === '2', start = second ? 4 : 1;
    return new Response([start, start + 1, start + 2].map(id => `<div class="pic_box"><a href="/photos-index-aid-${id}.html">图集</a></div>`).join('') +
      (u.pathname === '/search/' && !second ? `<a href="/search/?q=${encodeURIComponent(u.searchParams.get('q'))}&p=2">下一頁</a>` : ''));
  } });
  t.after(() => h.cleanup()); return { h, requests };
}
test('search keeps every upstream page remainder and binds cursors to their original query', async t => {
  await harness(t); let cursor = null; const ids = [];
  do { const r = await plugin.search({ query: '虚构', cursor, pageSize: 2 }); ids.push(...r.items.map(x => x.id)); cursor = r.nextCursor; } while (cursor);
  assert.deepEqual(ids, ['manga:1', 'manga:2', 'manga:3', 'manga:4', 'manga:5', 'manga:6']);
  const first = await plugin.search({ query: '虚构', cursor: null, pageSize: 2 });
  await assert.rejects(plugin.search({ query: '其他', cursor: first.nextCursor, pageSize: 2 }), /another scope/);
});
test('one upstream album is one gallery chapter; declared page count is not a word count', async t => {
  const { h } = await harness(t); const d = await plugin.getDetail({ id: 'manga:1' });
  assert.equal(d.title, '虚构图集1'); assert.equal(d.wordCount, null); assert.equal(d.author, null); assert.equal(d.chapterCount, 1);
  assert.deepEqual(d.attributes, [{ key: 'pageCount', label: '页数', value: '2' }]);
  assert.equal(h.resourceRequests[0].url, 'https://t4.qy0.ru/data/t/0/1/cover.jpg');
  const c = await plugin.getChapters({ id: 'manga:1' }); assert.equal(c.items[0].id, 'gallery:1'); assert.equal(c.items[0].title, d.title);
  const content = await plugin.getContent({ id: 'manga:1', chapterId: 'gallery:1' });
  assert.equal(content.text, null); assert.equal(content.pages.length, 2); assert.deepEqual(content.pages.map(x => x.index), [0, 1]);
  assert.ok(content.pages.every(x => x.mimeType === null)); assert.equal(globalThis.untrustedExecuted, undefined);
});
test('each content read refreshes supplied image signatures without changing stable page IDs', async t => {
  let nonce = 0; const { h } = await harness(t, u => u.pathname.includes('photos-gallery') ? new Response(images(String(++nonce))) : null);
  const first = await plugin.getContent({ id: 'manga:1', chapterId: 'gallery:1' });
  const next = await plugin.getContent({ id: 'manga:1', chapterId: 'gallery:1' });
  assert.deepEqual(first.pages.map(x => x.id), next.pages.map(x => x.id)); assert.notEqual(first.pages[0].url, next.pages[0].url);
  assert.ok(h.resourceRequests.some(x => x.url.endsWith('verify=1'))); assert.ok(h.resourceRequests.some(x => x.url.endsWith('verify=2')));
});
test('a changed upstream page count is read afresh together with gallery data', async t => {
  let metadataCalls = 0;
  await harness(t, u => u.pathname.includes('photos-index') ? new Response(info('1', ++metadataCalls === 1 ? 2 : 3)) : u.pathname.includes('photos-gallery') ? new Response(images('new', 3)) : null);
  await plugin.getDetail({ id: 'manga:1' });
  assert.equal((await plugin.getContent({ id: 'manga:1', chapterId: 'gallery:1' })).pages.length, 3);
});
test('missing, duplicated or unexpected image hosts fail instead of returning an incomplete gallery', async t => {
  for (const html of [images('one', 1), images('dup').replace('0001.jpg', '0000.jpg'), images('bad').replaceAll('img5.qy0.ru', 'unrelated.invalid'), '<p>访问受限</p>']) {
    await harness(t, u => u.pathname.includes('photos-gallery') ? new Response(html) : null);
    await assert.rejects(plugin.getContent({ id: 'manga:1', chapterId: 'gallery:1' }));
  }
});
test('mismatched gallery identity and unrelated thumbnail origins are rejected', async t => {
  const { h } = await harness(t, u => u.pathname.includes('photos-index') ? new Response(info('1').replace('t4.qy0.ru', 'unrelated.invalid')) : null);
  assert.equal((await plugin.getDetail({ id: 'manga:1' })).coverUrl, null); assert.equal(h.resourceRequests.length, 0);
  await assert.rejects(plugin.getContent({ id: 'manga:1', chapterId: 'gallery:2' }), /identity/);
});
test('recommendation continuation keeps its original snapshot when the homepage order changes', async t => {
  let count = 0;
  await harness(t, u => u.pathname === '/' ? new Response((++count === 1 ? [1, 2, 3] : [3, 1, 2]).map(id => `<div class="pic_box"><a href="/photos-index-aid-${id}.html">推荐</a></div>`).join('')) : null);
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 }); const c = root.document.components[0].children[0];
  await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 2 });
  const next = await plugin.discover({ ...c.continuation, collectionId: c.id, pageSize: 2 }); assert.equal(next.items[0].content.id, 'manga:3'); assert.equal(next.continuation, null);
});
