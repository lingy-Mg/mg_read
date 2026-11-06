/** Fictional public novels exercise real browser-page boundaries without adult content. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { createSourceTestHarness, collectDiscoveryContent, collectDiscoveryContinuations } from '@mgread/source-testkit';
const BOOK = '1164708399615709184', CHAPTERS = ['1164708399628292096', '1164708399657652224', '1164708399733149696'];
const cover = 'https://cdn.uameta.ai/file/bucket-media/image/cover/abc123.webp';
function intro() {
  return `<h1 class="nd-t2">虚构故事</h1><a class="nd-author__lk">虚构作者</a><div class="nd-cover"><img src="${cover}"></div><span class="nd-tag">连载中</span><div class="nd-synopsis">虚构简介。</div><div class="nd-stat"><div class="n">2.5万</div><div class="l">字数</div></div><div id="ndcBody"><button class="ndc-vol__h">第一卷3 章</button>${CHAPTERS.map((id, i) => `<a class="ndc-row" href="/novel/chapter?id=${id}" title="第${i + 1}章" data-no="${i + 1}"><span class="ndc-acc">${i === 2 ? '注册会员' : '游客'}</span></a>`).join('')}</div>`;
}
function cards(ids = [BOOK, '2', '3']) { return ids.map(id => `<a class="cn-lcard" href="/novel/intro?id=${id}"><h3 class="cn-lcard__t">虚构故事${id}</h3><span class="cn-lcard__byname">虚构作者</span><img src="${cover}"></a>`).join(''); }
function reader() { return `<h1 class="reader-chap">第一章</h1><a href="/novel/intro?id=${BOOK}">目录</a><div class="reader-body"><p>清晨的花园十分安静。</p><p>旅人收拾行装，踏上新的旅途。</p></div>`; }
async function setup(t, replacement) {
  const calls = [];
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.uaa-novel', version: '1.0.0', fetch: async (input, init = {}) => {
    const url = new URL(input); calls.push({ url, at: Date.now() });
    assert.equal(url.origin, 'https://www.uaa.com');
    assert.equal(new Headers(init.headers).has('cookie'), false);
    let body = replacement?.(url);
    if (body === undefined) {
      if (url.pathname === '/novel/list') body = cards();
      else if (url.pathname === '/novel/intro') body = intro();
      else if (url.pathname === '/novel/chapter') body = reader();
      else if (url.pathname === '/novel/load') {
        const page = Number(url.searchParams.get('page'));
        body = JSON.stringify({ code: 0, model: { totalCount: 6, totalPage: 2, data: [0, 1, 2].map(n => ({ id: String((page - 1) * 3 + n + 1), title: `虚构故事${n}`, authors: '虚构作者', coverUrl: cover, wordCount: 200, chapterCount: 3 })) } });
      } else throw new Error('Unexpected source route.');
    }
    const response = new Response(body); Object.defineProperty(response, 'url', { value: url.href }); return response;
  } });
  t.after(() => h.cleanup()); return { h, calls };
}
test('search preserves page remainders, query binding and cached upstream order', async t => {
  const { calls } = await setup(t); let cursor = null; const ids = [];
  do { const result = await plugin.search({ query: '虚构', cursor, pageSize: 2 }); ids.push(...result.items.map(x => x.id)); cursor = result.nextCursor; } while (cursor);
  assert.deepEqual(ids, ['book:1', 'book:2', 'book:3', 'book:4', 'book:5', 'book:6']);
  assert.equal(calls.filter(x => x.url.pathname === '/novel/load').length, 2);
  const first = await plugin.search({ query: '虚构', cursor: null, pageSize: 2 });
  await assert.rejects(plugin.search({ query: '另一查询', cursor: first.nextCursor, pageSize: 2 }), /another scope/);
});
test('discovery append retains the original snapshot after a root refresh', async t => {
  let count = 0; await setup(t, url => url.pathname === '/novel/list' ? cards(++count === 1 ? [BOOK, '2', '3'] : ['3', '2', BOOK]) : undefined);
  const root = await plugin.discover({ target: null, collectionId: null, cursor: null, pageSize: 2 });
  const continuation = collectDiscoveryContinuations(root)[0];
  await plugin.discover({ target: null, collectionId: null, cursor: null, pageSize: 2 });
  const next = await plugin.discover({ ...continuation, pageSize: 2 });
  assert.deepEqual(collectDiscoveryContent(next).map(x => x.id), ['book:3']); assert.equal(next.continuation, null);
});
test('large IDs remain exact strings and locked catalog entries are retained without body requests', async t => {
  const { h, calls } = await setup(t), detail = await plugin.getDetail({ id: `book:${BOOK}` });
  assert.equal(detail.id, `book:${BOOK}`); assert.equal(detail.wordCount, 25000); assert.equal(detail.chapterCount, 3);
  const catalog = await plugin.getChapters({ id: detail.id }); assert.equal(catalog.items.length, 3);
  assert.deepEqual(catalog.items.map(x => x.id), CHAPTERS.map(id => `chapter:${BOOK}:${id}`));
  assert.deepEqual(catalog.items.map(x => x.isLocked), [false, false, true]);
  await assert.rejects(plugin.getContent({ id: detail.id, chapterId: catalog.items[2].id }), /会员/);
  assert.equal(calls.filter(x => x.url.pathname === '/novel/chapter').length, 0);
  assert.ok(h.resourceRequests.every(x => x.url === cover));
});
test('body requests use complete paragraph text and are spaced rather than burst-fetched', async t => {
  const { calls } = await setup(t);
  const results = await Promise.all(CHAPTERS.slice(0, 2).map(id => plugin.getContent({ id: `book:${BOOK}`, chapterId: `chapter:${BOOK}:${id}` })));
  assert.equal(results[0].text, '清晨的花园十分安静。\n\n旅人收拾行装，踏上新的旅途。');
  const reads = calls.filter(x => x.url.pathname === '/novel/chapter'); assert.equal(reads.length, 2); assert.ok(reads[1].at - reads[0].at >= 3450);
});
test('hidden previews, empty bodies, unrelated book backlinks and oversized bodies fail explicitly', async t => {
  for (const body of [reader().replace('清晨的花园十分安静。', '以下正文内容已隐藏'), reader().replace(/<p>.*?<\/p>/gu, ''), reader().replace(`id=${BOOK}`, 'id=99'), reader().replace('清晨的花园十分安静。', '景'.repeat(18000))]) {
    await setup(t, url => url.pathname === '/novel/chapter' ? body : undefined);
    await assert.rejects(plugin.getContent({ id: `book:${BOOK}`, chapterId: `chapter:${BOOK}:${CHAPTERS[0]}` }), /隐藏正文|未返回游客章节|identity|host text limit/);
  }
});
test('missing rows, duplicate IDs, foreign chapter origins and unknown permission fail closed', async t => {
  for (const body of [intro().replace(/<a class="ndc-row"[^>]*>.*?<\/a>/u, ''), intro().replace(CHAPTERS[1], CHAPTERS[0]), intro().replace('/novel/chapter?', 'https://unrelated.invalid/novel/chapter?'), intro().replace('游客', '')]) {
    await setup(t, url => url.pathname === '/novel/intro' ? body : undefined);
    await assert.rejects(plugin.getChapters({ id: `book:${BOOK}` }), /catalog identity|permission|incomplete/);
  }
});
test('foreign cover descriptors are never registered and refresh invalidates catalog cache', async t => {
  let count = 0; const { h } = await setup(t, url => url.pathname === '/novel/intro' ? (++count === 1 ? intro().replace(cover, 'https://unrelated.invalid/a.jpg') : intro().replace('注册会员', '游客')) : undefined);
  assert.equal((await plugin.getDetail({ id: `book:${BOOK}` })).coverUrl, null); assert.equal(h.resourceRequests.length, 0);
  assert.equal((await plugin.getChapters({ id: `book:${BOOK}`, refresh: true })).items[2].isLocked, false);
});
