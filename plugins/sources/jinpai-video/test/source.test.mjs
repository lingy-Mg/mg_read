/** Deterministic fake WebView verifies session reuse, projections and the human-only verification boundary. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('uses one WebView session for search, detail, episodes and HLS', async () => {
  const navigations = [];
  const resources = [];
  let current = '';
  let opened = 0;
  const page = {
    async navigate(url) { current = url; navigations.push(url); },
    async hide() {},
    async executeJavaScript(code) {
      if (code.includes('captcha:')) return { title: '金牌影院', text: '影视首页', captcha: false };
      if (code.includes('performance.getEntriesByType')) return 'https://media.example/fixture.m3u8';
      if (current.includes('/voddetail/') && code.includes('vodplay')) return [
        { line: '1', episode: '1', title: '第 1 集', group: '高清线路' },
        { line: '1', episode: '2', title: '第 2 集', group: '高清线路' },
      ];
      if (current.includes('/voddetail/')) return { title: 'Fixture 金牌', cover: 'https://img.example/cover.jpg', latest: '更新至第 2 集', author: 'Fixture 演员', updatedAt: '2026', description: 'Fixture 简介' };
      if (code.includes('voddetail')) return [{ id: 'fixture-100', title: 'Fixture 金牌', cover: 'https://img.example/cover.jpg', latest: '更新至第 2 集' }];
      return [];
    },
  };
  await plugin.activate({
    dataDir: 'fixture-data', cacheDir: 'fixture-cache',
    app: { runtimeVersion: 'fixture', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.jinpai-video', version: '1.0.0' },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    webview: { async open() { opened += 1; return page; } },
    resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/resource/${resources.length}`; } },
    errors: { raise(error) { throw Object.assign(new Error(error.message ?? error), { publicCode: error.code ?? error }); } },
    http: { fetch }, browser: {},
  });
  const search = await plugin.search({ query: 'Fixture', cursor: null, pageSize: 4 });
  assert.equal(search.items.length, 1);
  const detail = await plugin.getDetail({ id: search.items[0].id });
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.equal(chapters.items.length, 2);
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.equal(content.media.resourceType, 'hls');
  assert.equal(resources.at(-1).url, 'https://media.example/fixture.m3u8');
  assert.equal(opened, 4);
  assert.ok(navigations.some((url) => url.includes('/vodsearch/Fixture')));
});

test('shows the same WebView and surfaces an actionable error for human verification', async () => {
  let shown = false;
  const page = {
    async navigate() {}, async hide() {}, async show() { shown = true; },
    async executeJavaScript(code) { if (code.includes('captcha:')) return { title: '请进行安全验证', text: '正在进行浏览器安全检查', captcha: true }; return []; },
  };
  await plugin.activate({
    dataDir: 'fixture-data', cacheDir: 'fixture-cache', app: { runtimeVersion: 'fixture', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.jinpai-video', version: '1.0.0' },
    log: { debug() {}, info() {}, warn() {}, error() {} }, webview: { async open() { return page; } }, resource: { proxy() { return 'http://127.0.0.1/resource'; } }, http: { fetch }, browser: {},
    errors: { raise(error) { throw Object.assign(new Error(error.message ?? error), { publicCode: error.code ?? error }); } },
  });
  await assert.rejects(() => plugin.search({ query: '测试', cursor: null, pageSize: 4 }), (error) => error.publicCode === 'source_access_blocked');
  assert.equal(shown, true);
});
