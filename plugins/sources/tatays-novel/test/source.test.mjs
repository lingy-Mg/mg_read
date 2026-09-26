import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('126 native HTML flow uses the live mobile search entry and keeps first/middle/last novel content readable', async () => {
  const resources = [];
  const search = '<div class="blockcontent"><div class="c_row cf"><a class="db cf" href="/book/109/"><div class="row_cover"><img src="/cover.jpg"></div><div class="search_text"><h2><i>斗破苍穹</i>之无上之境</h2><p><span>夜雨闻铃0</span> | <span>玄幻奇幻</span></p></div></a></div></div>';
  const listing = '<ul class="list-title"><li><a href="/book/109/"><img src="/cover.jpg"><h2>斗破苍穹之无上之境</h2><p class="info">作者：夜雨闻铃0 | 连载</p></a></li></ul>';
  const detail = '<div class="chapter-list-info"><div class="mid"><h2>斗破苍穹之无上之境</h2><div class="clearfix"><dd>作者：夜雨闻铃0</dd><dd>类型：玄幻</dd></div></div></div><div class="chapter-img"><img src="/cover.jpg"></div><div class="info"><div class="intro">小说简介</div></div><div class="lastchapter"><a>第三章</a></div><div class="chapter-box"><div class="chapter-list clears"><a href="/book/109/224613.html">第一章</a><a href="/book/109/224614.html">第二章</a><a href="/book/109/224615.html">第三章</a></div></div>';
  const content = '<div class="chapter-content">第一段<br>第二段<br>加入书签</div>';
  await plugin.activate({ log: { info() {}, warn() {} }, resource: { proxy(value) { resources.push(value); return 'http://127.0.0.1/resource/image'; } }, http: { async fetch(input, init = {}) {
    const url = String(input);
    if (url.includes('search.php')) {
      assert.equal(url, 'https://m.tatays.com/modules/article/search.php');
      assert.equal(init.method, 'POST');
      if (String(init.body).includes('searchkey=%E7%B2%BE%E7%A1%AE%E4%B9%A6%E5%90%8D')) return new Response(detail);
      assert.match(String(init.body), /searchkey=%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9/u);
      return new Response(search);
    }
    if (/22461[3-5]\.html$/u.test(url)) return new Response(content);
    if (url.includes('/book/109/')) return new Response(detail);
    return new Response(listing);
  } } });
  const found = await plugin.search({ query: '斗破苍穹', cursor: null, pageSize: 5 });
  assert.equal(found.items[0].author, '夜雨闻铃0');
  assert.equal(found.items[0].categories[0], '玄幻奇幻');
  const exact = await plugin.search({ query: '精确书名', cursor: null, pageSize: 5 });
  assert.equal(exact.items[0].id, 'novel:109');
  const discovery = await plugin.discover({ target: 'category:xuanhuan', cursor: null, collectionId: null, pageSize: 5 });
  const id = discovery.document.components[0].children[0].items[0].content.id;
  assert.equal(id, 'novel:109');
  const info = await plugin.getDetail({ id });
  assert.equal(info.description, '小说简介');
  const chapters = await plugin.getChapters({ id });
  assert.equal(chapters.items.length, 3);
  for (const chapter of [chapters.items[0], chapters.items[1], chapters.items[2]]) {
    const body = await plugin.getContent({ id, chapterId: chapter.id });
    assert.equal(body.chapterId, chapter.id);
    assert.equal(body.text, '第一段\n\n第二段');
  }
  assert.ok(resources.some((value) => value.kind === 'image'));
});
