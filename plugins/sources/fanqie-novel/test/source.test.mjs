import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('Fanqie source keeps book/item IDs and formats paragraphs', async () => {
  const proxied = [];
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(value) { proxied.push(value); return 'http://127.0.0.1/r'; } },
    http: { async fetch(input) {
      const url = String(input);
      if (url.includes('book_list')) return Response.json({ code: 0, data: { data: [{ book_id: '12', book_name: '测试书', author: '作者', thumb_url: 'https://img.example/a~tplv.heic' }] } });
      if (url.includes('/info?')) return Response.json({ data: { data: { book_name: '测试书', author: '作者', thumb_url: 'https://img.example/a.jpg' } } });
      if (url.includes('/directory/')) return Response.json({ data: { chapterListWithVolume: [[{ itemId: '34', title: '第一章' }]] } });
      if (url.includes('/content?')) return Response.json({ code: 0, data: { content: '<article><p>第一段</p><p>第二段</p></article>' } });
      throw new Error(url);
    } },
  });
  const home = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 3 });
  const result = await plugin.discover({ target: 'channel:1', cursor: null, collectionId: null, pageSize: 3 });
  const item = result.document.components[0].children[0].items[0].content;
  const chapters = await plugin.getChapters({ id: item.id });
  const content = await plugin.getContent({ id: item.id, chapterId: chapters.items[0].id });
  assert.equal(item.id, 'novel:12');
  assert.equal(home.document.components[0].children[0].type, 'profileCard');
  assert.equal(home.document.components[0].children[0].badge, '待确认');
  assert.equal(home.document.components[1].icon, 'book');
  assert.equal(home.document.components[1].children[0].categories[0].icon, 'book');
  assert.equal(chapters.items[0].id, 'novel:12:34');
  assert.equal(content.text, '第一段\n\n第二段');
  assert.match(proxied[0].url, /p6-novel\.byteimg\.com/u);
});

test('Fanqie chapter order is local and contiguous inside each volume', async () => {
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(value) { return value.url; } },
    http: { async fetch(input) {
      assert.ok(String(input).includes('/directory/'));
      return Response.json({ data: { chapterListWithVolume: [
        [{ itemId: '1', title: '第1章' }, { itemId: '2', title: '第2章' }],
        [{ itemId: '3', title: '第3章' }],
      ] } });
    } },
  });
  const result = await plugin.getChapters({ id: 'novel:12' });
  assert.deepEqual(result.items.map((item) => item.order), [0, 1, 2]);
  assert.deepEqual(result.groups.map((group) => group.episodes.map((item) => item.order)), [[0, 1], [0]]);
});

test('Fanqie home shows account state and login still imports bookshelf IDs through source details', async () => {
  const calls = [];
  const page = {
    async navigate(url, options) { calls.push(['navigate', url, options]); },
    async show(options) { calls.push(['show', options]); },
  };
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(value) { return value.url; } },
    http: { async fetch(input) {
      const url = String(input);
      const bookId = /book_id=(\d+)/u.exec(url)?.[1];
      if (bookId) return Response.json({ data: { data: { book_id: bookId, book_name: `书${bookId}`, author: '作者' } } });
      throw new Error(`unexpected HTTP request: ${url}`);
    } },
    webview: { async open(options) { calls.push(['open', options]); return page; } },
    browser: { sessionV1: { async request(request) {
      calls.push(['session', request]);
      if (request.url.includes('/api/user/info/v2')) return { version: 1, status: 200, body: JSON.stringify({ code: -1, data: {} }), headers: {}, finalUrl: request.url };
      return { version: 1, status: 200, body: JSON.stringify({ code: 0, data: { book_shelf_info: [{ book_id: '12' }, { book_id: '55' }, { book_id: '12' }] } }), headers: {}, finalUrl: request.url };
    } } },
  });
  const home = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 10 });
  const account = home.document.components[0];
  assert.equal(account.children[0].badge, '未登录');
  const actions = account.children[1].categories;
  assert.deepEqual(actions.map((action) => action.target), ['login']);
  await assert.rejects(plugin.discover({ target: 'login-status', cursor: null, collectionId: null, pageSize: 10 }), /invalid/u);

  const login = await plugin.discover({ target: 'login', cursor: null, collectionId: null, pageSize: 10 });
  assert.equal(login.document.components[0].title, '番茄网页登录已打开');
  const webviewCalls = calls.filter(([kind]) => kind !== 'session');
  assert.equal(webviewCalls[0][0], 'open');
  assert.deepEqual(webviewCalls[0][1], { visible: true, timeoutMs: 30_000 });
  assert.deepEqual(webviewCalls[1], ['navigate', 'https://fanqienovel.com/', { timeoutMs: 45_000 }]);
  assert.deepEqual(webviewCalls[2], ['show', { timeoutMs: 15_000 }]);

  const shelf = await plugin.discover({ target: 'bookshelf', cursor: null, collectionId: null, pageSize: 10 });
  const items = shelf.document.components[0].children[0].items;
  assert.equal(shelf.document.components[0].children[0].layout, 'coverGrid');
  assert.deepEqual(items.map((item) => item.content.id), ['novel:12', 'novel:55']);
  assert.match(shelf.document.components[0].subtitle, /读取 2 本书的 ID/u);
  const sessionCalls = calls.filter(([kind]) => kind === 'session').map(([, request]) => request);
  assert.equal(sessionCalls.length, 2);
  assert.equal(sessionCalls[0].url, 'https://fanqienovel.com/api/user/info/v2');
  assert.equal(sessionCalls[0].transport, 'http');
  assert.equal(sessionCalls[0].presentation, 'hidden');
  assert.equal(sessionCalls[0].timeoutMs, 8000);
  assert.equal('cookie' in sessionCalls[0].headers, false);
  assert.equal(sessionCalls[1].url, 'https://fanqienovel.com/reading/bookapi/bookshelf/info/v:version/?aid=1967&iid=0&version_code=57700&update_version_code=57700');
  assert.equal(calls.filter(([kind]) => kind === 'navigate').length, 1);
});

test('Fanqie discovery home shows only profile fields returned by the browser session', async () => {
  const proxied = [];
  let userData = { id: 12345, name: '番茄读者', desc: '喜欢阅读', avatar: 'https://img.example/avatar.png' };
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(value) { proxied.push(value); return 'http://127.0.0.1/avatar'; } },
    browser: { sessionV1: { async request(request) {
      assert.equal(request.url, 'https://fanqienovel.com/api/user/info/v2');
      assert.equal('cookie' in request.headers, false);
      return { version: 1, status: 200, body: JSON.stringify({ code: 0, data: userData }), headers: {}, finalUrl: request.url };
    } } },
  });
  const account = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 10 });
  const [profile, actions] = account.document.components[0].children;
  assert.equal(profile.type, 'profileCard');
  assert.equal(profile.name, '番茄读者');
  assert.equal(profile.subtitle, '喜欢阅读');
  assert.equal(profile.avatarUrl, 'http://127.0.0.1/avatar');
  assert.deepEqual(profile.details, [{ label: '用户 ID', value: '12345' }]);
  assert.deepEqual(actions.categories.map((item) => item.target), ['bookshelf', 'login']);
  assert.equal(proxied[0].url, 'https://img.example/avatar.png');

  userData = {};
  const minimal = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 10 });
  const fallback = minimal.document.components[0].children[0];
  assert.equal(fallback.name, '番茄用户');
  assert.equal(fallback.avatarUrl, null);
  assert.deepEqual(fallback.details, []);
});

test('Fanqie source migrates legacy search payloads and web detail fallback', async () => {
  const resources = [];
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(value) { resources.push(value); return 'http://127.0.0.1/resource'; } },
    http: { async fetch(input) {
      const url = String(input);
      if (url.includes('fq-book.netsite.cc/search?')) return Response.json({ data: { has_more: false, search_tabs: [{ data: [{ book_data: { 0: { book_id: '55', book_name: '<em>旧版书</em>', author: '<em>旧作者</em>', thumb_url: 'https://img.example/cover~tplv.jpg' } } }] }] } });
      if (url.includes('fq-book.netsite.cc/info?')) return Response.json({ data: { data: {} } });
      if (url.includes('fanqienovel.com/page/66')) return new Response('<html><head><title>网页书_番茄小说</title><meta name="description" content="网页简介"></head><body><script type="application/ld+json">{"headline":"网页书","author":{"name":"网页作者"},"image":"https://img.example/web.jpg"}</script></body></html>');
      throw new Error(url);
    } },
  });
  const result = await plugin.search({ query: '旧版书', cursor: null, pageSize: 5 });
  const detail = await plugin.getDetail({ id: 'novel:66' });
  assert.equal(result.items[0].id, 'novel:55');
  assert.equal(result.items[0].title, '旧版书');
  assert.equal(detail.title, '网页书');
  assert.equal(detail.author, '网页作者');
  assert.equal(detail.description, '网页简介');
  assert.equal(resources.length, 2);
});

test('Fanqie detail reuses a cover field from the same API response', async () => {
  const resources = [];
  let infoCalls = 0;
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(value) { resources.push(value); return 'http://127.0.0.1/resource'; } },
    http: { async fetch(input) {
      const url = String(input);
      if (url.includes('/info?')) {
        infoCalls += 1;
        return Response.json({ data: { data: { book_name: '同响应封面', author: '作者' }, cover: 'https://img.example/reused.jpg' } });
      }
      throw new Error(url);
    } },
  });
  const detail = await plugin.getDetail({ id: 'novel:77' });
  assert.equal(infoCalls, 1);
  assert.equal(detail.title, '同响应封面');
  assert.equal(resources.length, 1);
  assert.equal(resources[0].url, 'https://p6-novel.byteimg.com/origin/reused.jpg');
  assert.equal(resources[0].headers.Referer, 'https://fanqienovel.com/');
});

test('Fanqie bookshelf keeps grid covers and continuation across pages with web image arrays', async () => {
  const resources = [];
  const ids = ['11', '22', '33', '44', '55'];
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(value) { resources.push(value); return value.url; } },
    browser: { sessionV1: { async request(request) {
      return { version: 1, status: 200, body: JSON.stringify({ code: 0, data: {
        book_shelf_info: ids.map((book_id) => ({ book_id })),
      } }), headers: {}, finalUrl: request.url };
    } } },
    http: { async fetch(input) {
      const url = String(input);
      if (url.includes('/info?')) {
        const id = new URL(url).searchParams.get('book_id');
        // Both an unavailable API and a successful detail without a cover need the web metadata.
        return Response.json({ data: { data: id === '22' ? {} : { book_name: `书${id}`, author: '接口作者' } } });
      }
      const id = /\/page\/(\d+)$/u.exec(url)?.[1];
      if (id) return new Response(`<html><head><title>书${id}_番茄小说</title></head><body><script type="application/ld+json">${JSON.stringify({
        headline: `书${id}`, image: [`https://p9-novel-sign.byteimg.com/novel-pic/${id}~tplv-resize:225:300.image?x-signature=fixture`],
      })}</script></body></html>`);
      throw new Error(url);
    } },
  });
  const first = await plugin.discover({ target: 'bookshelf', cursor: null, collectionId: null, pageSize: 3 });
  const grid = first.document.components[0].children[0];
  assert.equal(grid.layout, 'coverGrid');
  assert.deepEqual(grid.items.map(({ content }) => content.id), ['novel:11', 'novel:22', 'novel:33']);
  assert.equal(grid.items[0].content.author, '接口作者');
  assert.deepEqual(grid.continuation, { target: 'bookshelf', cursor: 'bookshelf:3' });
  const next = await plugin.discover({ ...grid.continuation, collectionId: grid.id, pageSize: 3 });
  assert.equal(next.kind, 'append');
  assert.equal(next.collectionId, grid.id);
  assert.deepEqual(next.items.map(({ content }) => content.id), ['novel:44', 'novel:55']);
  assert.equal(next.continuation, null);
  assert.deepEqual([...grid.items, ...next.items].map(({ content }) => content.coverUrl),
    ids.map((id) => `https://p6-novel.byteimg.com/origin/novel-pic/${id}`));
  assert.equal(resources.length, 5);
  assert.ok(resources.every((resource) => resource.kind === 'image' && resource.headers.Referer === 'https://fanqienovel.com/'));
});

test('Fanqie optional web cover failure preserves a usable API detail', async () => {
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(value) { return value.url; } },
    http: { async fetch(input) {
      if (String(input).includes('/info?')) return Response.json({ data: { book_name: '无封面作品', author: '作者' } });
      throw new Error('web unavailable');
    } },
  });
  const detail = await plugin.getDetail({ id: 'novel:77' });
  assert.equal(detail.title, '无封面作品');
  assert.equal(detail.coverUrl, null);
});

test('Fanqie source strips legacy inline image blocks from novel text', async () => {
  await plugin.activate({
    log: { info() {} },
    resource: { proxy() { return 'http://127.0.0.1/resource'; } },
    http: { async fetch(input) {
      if (String(input).includes('/content?')) return Response.json({ data: { content: '<article><p idx="0">第一段<img src="https://img.example/in-body.jpg"></p><div data-fanqie-type="image"><img src="https://img.example/only-image.jpg"></div><p idx="1">第二段</p></article>' } });
      throw new Error(String(input));
    } },
  });
  const content = await plugin.getContent({ id: 'novel:12', chapterId: 'novel:12:34' });
  assert.equal(content.text, '第一段\n\n第二段');
  assert.doesNotMatch(content.text, /img\.example/u);
});
