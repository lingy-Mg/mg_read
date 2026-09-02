import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import * as cheerio from 'cheerio/slim';
import * as plugin from '../dist/index.mjs';

test('synthetic fixture covers public discovery, search, detail, catalog, image manifest, proxy and restricted chapter refusal', async (t) => {
  const cacheDir = await mkdtemp(join(tmpdir(), '66manhua-cache-')); t.after(() => rm(cacheDir, { recursive: true, force: true }));
  const [homeFixture, list, detail, chapter, locked] = await Promise.all(['home.html', 'list.html', 'detail.html', 'chapter.html', 'locked-chapter.html'].map((name) => readFile(new URL(`./fixtures/${name}`, import.meta.url), 'utf8')));
  const home = saturateHomeFixture(homeFixture);
  const proxied = []; const requests = [];
  await plugin.activate({ dataDir: cacheDir, cacheDir, app: {}, plugin: {}, log: { debug(){}, info(){}, warn(){}, error(){} }, resource: { proxy(request) { proxied.push(request); const token = Buffer.from(JSON.stringify({ pluginId: 'org.mgread.66manhua-cc', request, version: 1 }), 'utf8').toString('base64url'); return `http://127.0.0.1:43210/v1/source-resource/${token}`; } }, http: { async fetch(input, init) { const url = new URL(input); requests.push({ url, init }); if (url.hostname === 'mh.aikanhanman.top') return new Response(new Uint8Array([7, 8]), { headers: { 'content-type': 'image/jpeg' } }); if (url.pathname === '/') return new Response(home); if (url.pathname === '/index.php/comic/sample') return new Response(detail); if (url.pathname === '/index.php/chapter/123') return new Response(chapter); if (url.pathname === '/index.php/chapter/124') return new Response(locked); return new Response(list); } } });
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 }); assert.equal(search.items.length, 1); assert.equal(search.nextCursor, null);
  const discover = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 }); assert.equal(discover.kind, 'document');
  assert.deepEqual(discover.document.components.map((component) => component.type === 'group' ? `${component.type}:${component.layout}` : `${component.type}:${component.children[0].layout}`), ['section:carousel', 'section:coverGrid', 'group:vertical', 'section:shelf', 'group:vertical']);
  const sections = discover.document.components.flatMap((component) => component.type === 'group' ? component.children : [component]);
  assert.deepEqual(sections.map((section) => section.title), ['精选推荐', '最近更新', '上升最快', '人气排行榜', '完结大作', '收藏榜', '打赏榜', '月票榜']);
  assert.deepEqual(sections.slice(2, 4).concat(sections.slice(-3)).map((section) => section.children[0].layout), ['compact', 'compact', 'compact', 'compact', 'compact']);
  assert.deepEqual(sections.map((section) => section.children[0].items.length), [6, 8, 8, 8, 8, 4, 4, 4]);
  assert.ok(Buffer.byteLength(JSON.stringify(discover), 'utf8') < 48 * 1_024);
  assert.equal(sections[0].children[0].items[0].content.author, 'Fixture Author');
  assert.equal(sections[1].children[0].items[0].content.latestChapter.title, '第 8 话');
  assert.deepEqual(sections.slice(-3).map((section) => section.children[0].items[0].metric), [{ label: '收藏', value: '110' }, { label: '打赏', value: '2' }, { label: '月票', value: '9' }]);
  assert.equal(new Set(sections.flatMap((section) => section.children[0].items.map((item) => item.content.coverUrl).filter(Boolean))).size, 7);
  const detailResult = await plugin.getDetail({ id: search.items[0].id }); const chapters = await plugin.getChapters({ id: detailResult.id });
  assert.equal(detailResult.title, 'Sample'); assert.equal(detailResult.author, 'Fixture Author'); assert.equal(detailResult.description, 'Complete fixture summary.'); assert.deepEqual(detailResult.categories, ['都市']);
  assert.equal(chapters.items.length, 2); assert.equal(chapters.items[1].isLocked, true);
  const content = await plugin.getContent({ id: detailResult.id, chapterId: chapters.items[0].id }); assert.equal(content.text, null); assert.equal(content.pages.length, 2);
  await assert.rejects(plugin.getContent({ id: detailResult.id, chapterId: chapters.items[1].id }), /requires public access/u);
  assert.equal(new URL(proxied.at(-1).url).hostname, 'mh.aikanhanman.top');
  assert.equal(requests.some(({ url }) => url.hostname === 'mh.aikanhanman.top'), false);
});

function saturateHomeFixture(html) {
  const $ = cheerio.load(html);
  const section = (title) => $('.in-sec-wr').filter((_, element) => $(element).find('.in-sec__head span').first().text().trim() === title).first();
  const roots = [
    $('.in-fine__big').first(),
    $('.recent-wr .in-sec-update .in-comic--type-b').first(),
    section('上升最快').find('.in-comic--type-b').first(),
    $('.recent-wr .in-rank-box--aside .rank-item').first(),
    section('完结大作').find('.in-comic--type-b').first(),
    ...$('.in-rank-box > .rank-item').toArray().map((element) => $(element)),
  ];
  for (const root of roots) {
    const parent = root.parent();
    for (let index = 2; index <= 20; index += 1) {
      const clone = root.clone();
      clone.find('a[href*="/index.php/comic/"]').each((_, element) => {
        const link = $(element); const href = link.attr('href');
        if (href !== undefined) link.attr('href', href.replace(/(\/index\.php\/comic\/[^/?#]+)/u, `$1-${index}`));
      });
      parent.append(clone);
    }
  }
  return $.html();
}
