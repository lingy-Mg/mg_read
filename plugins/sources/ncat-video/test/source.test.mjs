/** Deterministic fake WebView covers serialized navigation, DOM projections and HLS proxying. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('native WebView source projects discovery, search, details, grouped episodes and HLS', async () => {
  const navigations = [];
  const resources = [];
  let current = '';
  const page = {
    async navigate(url) { current = url; navigations.push(url); },
    async executeJavaScript(code) {
      if (code.includes('input[name="t"]')) return 'fixture-token';
      if (current.includes('/show/') || current.includes('/search?')) return [{ id: '356989', title: 'Fixture Ncat', cover: '/cover.jpg', latest: '更新至 2 集' }];
      if (current.includes('/detail/') && code.includes('episode-list-box-main')) return [
        { href: 'https://www.ncat21.com/play/356989-41-4918517.html', title: '第1集', group: '高清线路' },
        { href: 'https://www.ncat21.com/play/356989-41-4918518.html', title: '第2集', group: '高清线路' },
      ];
      if (current.includes('/detail/')) return { title: 'Fixture Ncat', cover: '/cover.jpg', author: 'Fixture Actor', latest: '更新至 2 集', updatedAt: '2026', description: 'Fixture intro' };
      if (current.includes('/play/')) return 'https://media.example/fixture.m3u8';
      return [];
    },
  };
  await plugin.activate({
    dataDir: 'fixture-data', cacheDir: 'fixture-cache',
    app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.ncat-video', version: '1.0.0' },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    webview: { async open() { return page; } },
    resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/resource/${resources.length}`; } },
    http: { async fetch(input) {
      if (String(input) === 'https://media.example/fixture.m3u8') return new Response('#EXTM3U\n#EXT-X-ENDLIST');
      throw new Error(`Unexpected HTTP request: ${input}`);
    } },
  });
  const discovery = await plugin.discover({ target: 'category:movie', cursor: null, collectionId: null, pageSize: 5 });
  const item = discovery.document.components[0].children[0].items[0].content;
  assert.equal(item.id, 'video:356989');
  const search = await plugin.search({ query: 'Fixture', cursor: null, pageSize: 5 });
  assert.equal(search.items[0].title, 'Fixture Ncat');
  assert.match(navigations.at(-1), /t=fixture-token&k=Fixture&page=1/u);
  const detail = await plugin.getDetail({ id: item.id });
  assert.equal(detail.author, 'Fixture Actor');
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.equal(chapters.groups[0].title, '高清线路');
  assert.deepEqual(chapters.items.map((episode) => episode.title), ['第1集', '第2集']);
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.equal(content.media.resourceType, 'hls');
  assert.equal(resources.at(-1).url, 'https://media.example/fixture.m3u8');
  assert.match(resources.at(-1).headers.Referer, /\/play\/356989-41-4918517\.html/u);
});

test('invalid ids are rejected', async () => {
  await assert.rejects(plugin.getDetail({ id: 'video:invalid' }), /Content ID is invalid/u);
  await assert.rejects(plugin.getContent({ id: 'video:356989', chapterId: 'ncat:356989:broken' }), /Chapter ID is invalid/u);
});
