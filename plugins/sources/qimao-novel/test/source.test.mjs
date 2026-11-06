/** Synthetic API responses exercise page ownership, complete catalogs and body decoding. */
import assert from 'node:assert/strict';
import { createCipheriv, createHash } from 'node:crypto';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { createSourceTestHarness } from '@mgread/source-testkit';

const book = id => ({ id: String(id), title: `虚构小说${id}`, original_title: `虚构小说${id}`, author: '虚构作者', intro: '虚构简介', image_link: 'https://cdn.qimao.com/bookimg/test.jpg', words_num: '0' });
function encrypted(text) {
  const iv = Buffer.alloc(16, 17);
  const cipher = createCipheriv('aes-128-cbc', Buffer.from('242ccb8230d709e1'), iv);
  return Buffer.concat([iv, cipher.update(text), cipher.final()]).toString('base64');
}
async function harness(t, custom) {
  const h = await createSourceTestHarness({ plugin, pluginId: 'org.mgread.qimao-novel', version: '1.0.0', fetch: async (input, init) => {
    const url = new URL(input);
    assert.ok(['api-bc.wtzw.com', 'api-ks.wtzw.com'].includes(url.hostname));
    assert.equal(init.redirect, 'error');
    assert.match(new Headers(init.headers).get('sign'), /^[a-f0-9]{32}$/);
    const parameters = Object.fromEntries(url.searchParams);
    const suppliedSign = parameters.sign;
    delete parameters.sign;
    const expected = createHash('md5').update(Object.keys(parameters).sort().map(k => `${k}=${parameters[k]}`).join('') + 'd3dGiJc651gSQ8w1').digest('hex');
    assert.equal(suppliedSign, expected);
    const override = custom?.(url);
    if (override) return override;
    if (url.pathname.endsWith('/words') || url.pathname.endsWith('/get-list')) {
      const page = Number(url.searchParams.get('page'));
      return Response.json({ data: { books: Array.from({ length: 10 }, (_, i) => book((page - 1) * 10 + i + 1)),
        meta: { page: String(url.pathname.endsWith('/words') ? page - 1 : page), total_page: '2', total_pages: '2' } } });
    }
    if (url.pathname.endsWith('/detail')) return Response.json({ data: { book: book(url.searchParams.get('id')) } });
    if (url.pathname.endsWith('/chapter-list')) return Response.json({ data: { meta: { pay_status: '0' }, chapter_lists: [
      { id: '101', title: '虚构首章', words: '0' }, { id: '102', title: '虚构末章', words: '123' },
    ] } });
    return Response.json({ data: { content: encrypted('虚构第一段。\n\n虚构第二段。') } });
  } });
  t.after(() => h.cleanup());
  return h;
}

test('search preserves every item when pageSize is smaller than an upstream page', async t => {
  await harness(t);
  const ids = [];
  let cursor = null;
  do {
    const result = await plugin.search({ query: '虚构', cursor, pageSize: 3 });
    ids.push(...result.items.map(b => b.id)); cursor = result.nextCursor;
  } while (cursor !== null);
  assert.equal(ids.length, 20);
  assert.equal(new Set(ids).size, 20);
  assert.equal(ids.at(-1), 'book:20');
  const first = await plugin.search({ query: '虚构', cursor: null, pageSize: 3 });
  await assert.rejects(plugin.search({ query: '另一个查询', cursor: first.nextCursor, pageSize: 3 }), /another query/);
});

test('discovery append keeps collection and category ownership', async t => {
  await harness(t);
  const result = await plugin.discover({ target: 'category:205', cursor: null, collectionId: null, pageSize: 3 });
  const collection = result.document.components[0].children[0];
  const next = await plugin.discover({ ...collection.continuation, collectionId: collection.id, pageSize: 3 });
  assert.equal(next.kind, 'append');
  assert.equal(next.items[0].content.id, 'book:4');
  await assert.rejects(plugin.discover({ ...collection.continuation, target: 'category:202', collectionId: 'qimao:202', pageSize: 3 }), /another query/);
});

test('detail preserves zero and null, validates image origin, and catalogs keep source order', async t => {
  const h = await harness(t);
  const detail = await plugin.getDetail({ id: 'book:1' });
  assert.equal(detail.wordCount, 0);
  assert.equal(detail.chapterCount, null);
  assert.equal(detail.author, '虚构作者');
  assert.equal(detail.access, 'unknown');
  assert.ok(h.resourceRequests.every(r => r.url === 'https://cdn.qimao.com/bookimg/test.jpg'));
  const catalog = await plugin.getChapters({ id: 'book:1' });
  assert.deepEqual(catalog.items.map(c => c.id), ['chapter:1:101', 'chapter:1:102']);
  assert.equal(catalog.items[0].isLocked, false);
  const content = await plugin.getContent({ id: 'book:1', chapterId: catalog.items[1].id });
  assert.equal(content.text, '虚构第一段。\n\n虚构第二段。');
  await assert.rejects(plugin.getContent({ id: 'book:2', chapterId: catalog.items[0].id }), /identity/);
});

test('duplicate and oversized catalogs fail without silently dropping chapters', async t => {
  await harness(t, () => Response.json({ data: { chapter_lists: [{ id: '1', title: '一' }, { id: '1', title: '重复' }] } }));
  await assert.rejects(plugin.getChapters({ id: 'book:1' }), /duplicate/);
  await harness(t, () => Response.json({ data: { chapter_lists: Array.from({ length: 5001 }, (_, i) => ({ id: String(i + 1), title: '虚构章' })) } }));
  await assert.rejects(plugin.getChapters({ id: 'book:1' }), /host limit/);
});

test('blocked, malformed and oversized bodies cannot appear as readable content', async t => {
  await harness(t, () => new Response('blocked', { status: 403 }));
  await assert.rejects(plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:101' }));
  await harness(t, () => Response.json({ data: { content: 'AAAA' } }));
  await assert.rejects(plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:101' }), /length/);
  await harness(t, () => Response.json({ data: { content: encrypted('文'.repeat(20000)) } }));
  await assert.rejects(plugin.getContent({ id: 'book:1', chapterId: 'chapter:1:101' }), /not been truncated/);
});
