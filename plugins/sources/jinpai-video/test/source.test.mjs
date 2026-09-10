/** Session HTTP fixtures prove that only the bootstrap is rendered by WebView. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

function fixtureHtml(url) {
  if (url.includes('/detail/fixture-100')) return '<h1>Fixture 金牌</h1><img src="https://img.example/cover.jpg"><div class="intro">Fixture 简介</div><a href="/vod/play/fixture-100/sid/1">第 1 集</a><a href="/vod/play/fixture-100/sid/2">第 2 集</a>';
  if (url.includes('/vod/play/fixture-100/sid/')) return '<script>const playUrl="https://media.example/fixture.m3u8";</script>';
  return '<a href="/detail/fixture-100" title="Fixture 金牌"><img src="https://img.example/cover.jpg">Fixture 金牌</a>';
}

test('uses one WebView bootstrap then host session HTTP for search, detail, episodes and HLS', async () => {
  const navigations = [];
  const requests = [];
  const resources = [];
  let opened = 0;
  const page = {
    async navigate(url) { navigations.push(url); },
    async show() { throw new Error('fixture is already verified'); },
    async executeJavaScript(code) {
      assert.ok(code.startsWith('return '));
      if (code.includes('captcha:')) return { title: '金牌影院', text: '影视首页', captcha: false };
      return null;
    },
  };
  await plugin.activate({
    dataDir: 'fixture-data', cacheDir: 'fixture-cache', app: { runtimeVersion: 'fixture', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.jinpai-video', version: '1.1.0' },
    log: { debug() {}, info() {}, warn() {}, error() {} }, webview: { async open() { opened += 1; return page; } },
    browser: { sessionV1: { async request(request) { requests.push(request); return { version: 1, status: 200, body: fixtureHtml(request.url), headers: {}, finalUrl: request.url, sessionUserAgent: 'fixture-webview-agent' }; } } },
    resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/resource/${resources.length}`; } }, http: { fetch },
    errors: { raise(error) { throw Object.assign(new Error(error.message ?? error), { publicCode: error.code ?? error }); } },
  });
  const search = await plugin.search({ query: 'Fixture', cursor: null, pageSize: 4 });
  const detail = await plugin.getDetail({ id: search.items[0].id });
  const chapters = await plugin.getChapters({ id: detail.id });
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.equal(search.items.length, 1);
  assert.equal(chapters.items.length, 2);
  assert.equal(content.media.resourceType, 'hls');
  assert.equal(resources.at(-1).url, 'https://media.example/fixture.m3u8');
  assert.equal(resources.at(-1).headers['User-Agent'], 'fixture-webview-agent');
  assert.equal(opened, 1);
  assert.deepEqual(navigations, ['https://www.vv3nwjk.com/']);
  assert.equal(requests.length, 4);
  for (const request of requests) {
    assert.equal(request.transport, 'http');
    assert.equal(request.sessionKey, 'jinpai-webview');
    assert.equal(Object.keys(request.headers).some((name) => /^(cookie|user-agent)$/iu.test(name)), false);
  }
});

test('shows the bootstrap WebView and surfaces an actionable verification error', async () => {
  let shown = false;
  const page = {
    async navigate() {}, async show() { shown = true; },
    async executeJavaScript(code) { assert.ok(code.startsWith('return ')); return code.includes('captcha:') ? { title: '请进行安全验证', text: '正在进行浏览器安全检查', captcha: true } : null; },
  };
  await plugin.activate({
    dataDir: 'fixture-data', cacheDir: 'fixture-cache', app: { runtimeVersion: 'fixture', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.jinpai-video', version: '1.1.0' },
    log: { debug() {}, info() {}, warn() {}, error() {} }, webview: { async open() { return page; } }, browser: { sessionV1: { async request() { throw new Error('must not request before validation'); } } },
    resource: { proxy() { return 'http://127.0.0.1/resource'; } }, http: { fetch }, errors: { raise(error) { throw Object.assign(new Error(error.message ?? error), { publicCode: error.code ?? error }); } },
  });
  await assert.rejects(() => plugin.search({ query: '测试', cursor: null, pageSize: 4 }), (error) => error.publicCode === 'source_access_blocked');
  assert.equal(shown, true);
});
