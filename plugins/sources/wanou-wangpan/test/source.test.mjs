import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

const detailUrl = 'https://www.wogg.net/voddetail/fixture.html';
const html = `
<div class="module-item module-search-item"><a href="/voddetail/fixture.html" title="玩偶测试片"><img data-src="/cover.jpg" alt="玩偶测试片"></a><div class="module-item-note">更新至 2 集</div></div>
<h1 class="page-title">玩偶测试片</h1><div id="download-list"><a class="fzlj" href="https://pan.quark.cn/s/fixture01">夸克</a></div>`;

test('projects Wogg listing, share files and a user-login action through public APIs', async () => {
  const requests = []; let current = '';
  const page = {
    async navigate(url) { current = url; }, async show() { requests.push(`show:${current}`); },
    async getHtml() { return html; },
    async fetch(request) {
      requests.push(request.url);
      if (request.url.includes('/token?')) return { body: { data: { stoken: 'fixture-token' } }, headers: {}, status: 200, url: request.url };
      return { body: { data: { list: [{ fid: 'file-1', file_name: '第一集.mp4', size: 1024, file: true, share_fid_token: 'share-token' }] } }, headers: {}, status: 200, url: request.url };
    },
    async executeJavaScript() { return 'https://media.example/fixture.mp4'; },
  };
  const resources = [];
  await plugin.activate({ dataDir: 'fixture-data', cacheDir: 'fixture-cache', app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 }, plugin: { id: 'org.mgread.wanou-wangpan', version: '1.0.0' }, log: { debug() {}, info() {}, warn() {}, error() {} }, webview: { async open() { return page; } }, resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/resource/${resources.length}`; } }, http: { async fetch(url) { assert.ok(String(url).includes('wogg.net')); return new Response(html); } } });
  const search = await plugin.search({ query: '测试', cursor: null, pageSize: 10 });
  const detail = await plugin.getDetail({ id: search.items[0].id });
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.equal(chapters.groups[0].title, '夸克网盘');
  assert.equal(chapters.items[0].title, '第一集.mp4');
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.equal(content.media.resourceType, 'video');
  assert.equal(resources.at(-1).url, 'https://media.example/fixture.mp4');
  await plugin.discover({ target: 'login:quark', cursor: null, collectionId: null, pageSize: 10 });
  assert.ok(requests.includes('show:https://pan.quark.cn/'));
});
