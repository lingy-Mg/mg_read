import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

const listing = `<a class="sp-bcarousel-item" href="/book/test" title="测试漫画"><div class="cropped" data-src="https://bmigmi-global-wuwu.ccavbox.com/break_2/static/upload/book/test/cover_pc.jpg"></div></a>`;
const detail = `<meta property="og:title" content="测试漫画 - 污污漫畫"><meta property="og:image" content="https://bmigmi-global-wuwu.ccavbox.com/break_2/static/upload/book/test/cover.jpg"><h1 class="sp-book-title">测试漫画</h1><p class="sp-book-summary">简介</p><div class="sp-chapter-grid"><a class="sp-chapter-item" href="/free-chapter/test-1" title="第一话">第一话</a></div>`;
const chapter = `<div class="sp-reader-title">第一话</div><div class="comiclist"><div class="comicpage"><div><div id="page1" data-bmi-manifest="" class="cropped" data-src="https://bmigmi-global-wuwu.ccavbox.com/break_2/static/upload/book/test/test-1/page1.jpg"></div></div></div></div>`;

test('ComicBox source reads catalog and chapter pages through Node HTTP', async () => {
  const resources = [];
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/r/${resources.length}`; } },
    http: { async fetch(input) {
      const url = String(input);
      return new Response(url.includes('/free-chapter/') ? chapter : url.includes('/book/test') ? detail : listing, { status: 200 });
    } },
  });

  const listingResult = await plugin.discover({ target: 'channel:0', cursor: null, collectionId: null, pageSize: 5 });
  const item = listingResult.document.components[0].children[0].items[0].content;
  assert.equal(item.title, '测试漫画');
  assert.match(item.coverUrl ?? '', /^http:\/\/127\.0\.0\.1\/r\//u);
  assert.equal(resources[0].resourceTransform, 'aes-cbc-split-image-v1');
  assert.equal(resources[0].urls.length, 2);

  const chapters = await plugin.getChapters({ id: item.id });
  const content = await plugin.getContent({ id: item.id, chapterId: chapters.items[0].id });
  assert.equal(content.title, '第一话');
  assert.equal(content.pages.length, 1);
  assert.equal(content.pages[0].resourcePolicy, 'sessionOnly');
  assert.equal(resources.at(-1).resourceTransform, 'aes-cbc-split-image-v1');
  assert.match(resources.at(-1).urls[0], /page1\.b_0$/u);
});
