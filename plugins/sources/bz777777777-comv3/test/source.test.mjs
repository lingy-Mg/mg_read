import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import * as plugin from '../dist/index.mjs';

const origin = 'https://www.bz777777777.com';
const challenge = '<html><title>Just a moment...</title><div class="cf-challenge"></div></html>';

test('browser fixture covers search detail full catalog text and cover proxy', async (t) => {
  const cacheDir = await mkdtemp(join(tmpdir(), 'bz-cache-'));
  t.after(() => rm(cacheDir, { recursive: true, force: true }));
  const list = await readFile(new URL('./fixtures/list.html', import.meta.url), 'utf8');
  const detail = await readFile(new URL('./fixtures/detail.html', import.meta.url), 'utf8');
  const content = await readFile(new URL('./fixtures/content.html', import.meta.url), 'utf8');
  const calls = [];
  const resources = [];
  let currentUrl = origin;
  let pageHtml = challenge;
  let verificationPolls = 0;
  const page = {
    async navigate(url, callOptions) { currentUrl = url; calls.push({ operation: 'navigate', url, ...callOptions }); },
    async getHtml(callOptions) {
      calls.push({ operation: 'getHtml', ...callOptions });
      if (pageHtml === challenge) {
        if (verificationPolls > 0) pageHtml = list;
        verificationPolls += 1;
      }
      return pageHtml;
    },
    async fetch(request) {
      calls.push({ operation: 'fetch', ...request });
      const url = new URL(request.url);
      const path = url.pathname;
      const body = path.endsWith('.html') && path.startsWith('/book/') ? content : path === '/book/123/' ? detail : list;
      return { status: 200, url: request.url, headers: { 'content-type': 'text/html' }, body };
    },
    async getUrl(callOptions) { calls.push({ operation: 'getUrl', ...callOptions }); return currentUrl; },
    async show(callOptions) { calls.push({ operation: 'show', ...callOptions }); },
    async hide(callOptions) { calls.push({ operation: 'hide', ...callOptions }); },
  };
  await plugin.activate({
    dataDir: cacheDir,
    cacheDir,
    app: {},
    plugin: {},
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/r/${resources.length}`; } },
    http: { async fetch() { return new Response(new Uint8Array([9])); } },
    webview: { async open(openOptions) { calls.push({ operation: 'open', ...openOptions }); return page; } },
  });
  const home = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 10 });
  assert.equal(home.document.components[0].children[0].layout, 'shelf');
  assert.equal(home.document.components[1].children[0].layout, 'chips');
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 });
  assert.equal(search.items[0].title, 'Fixture Novel');
  const discovery = await plugin.discover({ target: 'category:all', cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(discovery.kind, 'document');
  const info = await plugin.getDetail({ id: search.items[0].id });
  assert.ok(info.coverUrl);
  const chapters = await plugin.getChapters({ id: info.id });
  assert.equal(chapters.items.length, 2);
  const body = await plugin.getContent({ id: info.id, chapterId: chapters.items[0].id });
  assert.match(body.text, /Fixture text/u);
  assert.ok(calls.some(call => call.operation === 'open'));
});

test('protected challenge becomes a stable source access error when verification cannot start', async () => {
  const plugin = await import(`../dist/index.mjs?blocked=${Date.now()}`);
  const cacheDir = await mkdtemp(join(tmpdir(), 'bz-blocked-cache-'));
  try {
    const page = {
      async navigate() {},
      async getHtml() { return challenge; },
      async fetch() { return { status: 403, url: origin, headers: {}, body: challenge }; },
      async getUrl() { return origin; },
      async show() { throw new Error('visible browser interaction is unavailable'); },
      async hide() {},
    };
    const raised = [];
    await plugin.activate({
      dataDir: cacheDir,
      cacheDir,
      app: {},
      plugin: {},
      errors: { raise(error) {
        raised.push(error);
        const thrown = new Error(error.message);
        thrown.name = 'PluginManagerError';
        thrown.code = error.code;
        thrown.detail = error.annotation === undefined ? error.message : `${error.message}\n注释：${error.annotation}`;
        throw thrown;
      } },
      log: { debug() {}, info() {}, warn() {}, error() {} },
      resource: { proxy() { return 'http://127.0.0.1/r/blocked'; } },
      http: { async fetch() { return new Response(''); } },
      webview: { async open() { return page; } },
    });
    await assert.rejects(
      () => plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 10 }),
      (error) => error?.code === 'source_access_blocked'
        && error?.detail === '访问异常，请完成来源页面的浏览器验证后重试。\n注释：检测到来源的安全验证页面；请在来源页面完成验证，然后点击“刷新”。',
    );
    assert.equal(raised[0].code, 'source_access_blocked');
  } finally {
    await rm(cacheDir, { recursive: true, force: true });
  }
});
