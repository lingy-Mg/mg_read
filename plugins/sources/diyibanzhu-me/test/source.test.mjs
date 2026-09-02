import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import * as plugin from '../dist/index.mjs';

const origin = 'https://m.diyibanzhu.me';
const challenge = '<html><title>Just a moment...</title><div class="cf-challenge"></div></html>';
const ready = '<html><body>第一版主</body></html>';

async function fixture(t, options = {}) {
  const cacheDir = await mkdtemp(join(tmpdir(), 'diyibanzhu-cache-'));
  t.after(() => rm(cacheDir, { recursive: true, force: true }));
  const html = {
    list: await readFile(new URL('./fixtures/list.html', import.meta.url), 'utf8'),
    detail: await readFile(new URL('./fixtures/detail.html', import.meta.url), 'utf8'),
    content: await readFile(new URL('./fixtures/content.html', import.meta.url), 'utf8'),
  };
  const calls = [];
  const logs = [];
  let currentUrl = origin;
  let pageHtml = options.initialChallenge === true ? challenge : ready;
  let verificationPolls = 0;
  let fetchGate = options.fetchChallenge === true;
  const metrics = { activeFetches: 0, maximumActiveFetches: 0 };
  const record = (operation, request = {}) => calls.push({ operation, ...request });
  const page = {
    async navigate(url, callOptions) { currentUrl = url; record('navigate', { url, ...callOptions }); },
    async getHtml(callOptions) {
      record('getHtml', callOptions);
      if (pageHtml === challenge) {
        if (verificationPolls > 0) pageHtml = ready;
        verificationPolls += 1;
      }
      return pageHtml;
    },
    async fetch(request) {
      record('fetch', request);
      metrics.activeFetches += 1;
      metrics.maximumActiveFetches = Math.max(metrics.maximumActiveFetches, metrics.activeFetches);
      try {
        if (options.yieldFetch === true) await Promise.resolve();
        if (fetchGate) { fetchGate = false; pageHtml = challenge; return { status: 403, url: request.url, headers: {}, body: challenge }; }
        const url = new URL(request.url);
        const action = url.searchParams.get('action');
        const body = action === 'article' ? html.content : action === 'list' ? html.detail : html.list;
        return { status: 200, url: request.url, headers: { 'content-type': 'text/html' }, body };
      } finally {
        metrics.activeFetches -= 1;
      }
    },
    async getUrl(callOptions) { record('getUrl', callOptions); return currentUrl; },
    async show(callOptions) { record('show', callOptions); },
    async hide(callOptions) { record('hide', callOptions); },
  };
  await plugin.activate({
    dataDir: cacheDir,
    cacheDir,
    app: {},
    plugin: {},
    log: {
      debug(message) { logs.push({ level: 'debug', message }); },
      info(message) { logs.push({ level: 'info', message }); },
      warn(message) { logs.push({ level: 'warn', message }); },
      error(message) { logs.push({ level: 'error', message }); },
    },
    resource: { proxy() { return 'http://127.0.0.1/resource'; } },
    http: { async fetch() { return new Response(new Uint8Array()); } },
    webview: { async open(openOptions) { record('open', openOptions); return page; } },
  });
  return { calls, logs, metrics };
}

test('one hidden WebView page covers search, discovery, detail, catalog and content', async t => {
  const { calls, logs } = await fixture(t);
  const home = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 10 });
  assert.equal(home.document.components[0].children[0].layout, 'shelf');
  assert.equal(home.document.components[1].children[0].layout, 'chips');
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 });
  assert.equal(search.items[0].coverUrl, null);
  const detail = await plugin.getDetail({ id: search.items[0].id });
  assert.equal(detail.author, 'Fixture Author');
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.equal(chapters.items.length, 2);
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.match(content.text, /第一段/u);
  assert.equal(content.pages.length, 0);

  assert.equal(calls.filter(call => call.operation === 'open').length, 1);
  assert.equal(calls.find(call => call.operation === 'open').visible, false);
  assert.equal(calls.filter(call => call.operation === 'hide').length, 0);
  assert.equal(calls.filter(call => call.operation === 'show').length, 0);
  assert.deepEqual(calls.slice(0, 4).map(call => call.operation), ['open', 'navigate', 'getHtml', 'fetch']);
  assert.equal(logs.some(log => log.message.includes('force_show')), false);
  assert.ok(logs.some(log => log.message === 'source_browser_initial_fetch_completed_2xx'));
  const fetches = calls.filter(call => call.operation === 'fetch');
  assert.ok(fetches.length >= 5);
  assert.ok(fetches.every(call => new URL(call.url).origin === origin && call.responseType === 'text'));
  assert.ok(fetches.every(call => call.headers.cookie === undefined && call.headers['user-agent'] === undefined));
  assert.deepEqual(fetches[0], {
    operation: 'fetch',
    url: `${origin}/wap.php?action=shuku`,
    method: 'GET',
    headers: { accept: 'text/html' },
    body: null,
    responseType: 'text',
    timeoutMs: 120000,
  });
  assert.deepEqual(fetches[1], {
    operation: 'fetch',
    url: `${origin}/wap.php?action=search`,
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'text/html' },
    body: 'objectType=2&wd=fixture',
    responseType: 'text',
    timeoutMs: 120000,
  });
});

test('initial verification shows the page only while needed and hides it after success', async t => {
  const { calls } = await fixture(t, { initialChallenge: true });
  const result = await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 });
  assert.equal(result.items.length, 1);
  assert.deepEqual(calls.slice(0, 7).map(call => call.operation), [
    'open', 'navigate', 'getHtml', 'show', 'getHtml', 'getUrl', 'getHtml',
  ]);
  assert.equal(calls.find(call => call.operation === 'open').visible, false);
  assert.equal(calls.filter(call => call.operation === 'show').length, 1);
  assert.equal(calls.filter(call => call.operation === 'hide').length, 1);
  assert.equal(calls.filter(call => call.operation === 'getHtml').length, 3);
});

test('discovery follows the live WAP pagination template instead of removed book routes', async t => {
  const { calls } = await fixture(t);
  const result = await plugin.discover({
    target: 'category:fantasy',
    cursor: 'category:fantasy:2',
    collectionId: 'category-books:fantasy',
    pageSize: 20,
  });
  assert.equal(result.kind, 'append');
  assert.equal(result.items.length, 1);
  const fetches = calls.filter(call => call.operation === 'fetch');
  assert.equal(fetches.length, 2);
  assert.equal(fetches[0].url, `${origin}/wap.php?action=shuku&order=3&tid=4`);
  assert.equal(fetches[1].url, `${origin}/wap.php?action=shuku&tid=4&over=&order=3&uid=&totalresult=30&pageno=2`);
});

test('a fetch verification response is completed visibly and retried once', async t => {
  const { calls } = await fixture(t, { fetchChallenge: true });
  const result = await plugin.search({ query: 'fixture', cursor: null, pageSize: 20 });
  assert.equal(result.items.length, 1);
  assert.equal(calls.filter(call => call.operation === 'fetch').length, 2);
  assert.equal(calls.filter(call => call.operation === 'show').length, 1);
  assert.equal(calls.filter(call => call.operation === 'getHtml').length >= 4, true);
  assert.equal(calls.filter(call => call.operation === 'hide').length, 1);
  assert.equal(calls.at(-2).operation, 'hide');
  assert.equal(calls.at(-1).operation, 'fetch');
});

test('concurrent source calls keep their complete browser request sequences serialized', async t => {
  const { calls, metrics } = await fixture(t, { yieldFetch: true });
  const [first, second] = await Promise.all([
    plugin.search({ query: 'first', cursor: null, pageSize: 20 }),
    plugin.search({ query: 'second', cursor: null, pageSize: 20 }),
  ]);
  assert.equal(first.items.length, 1);
  assert.equal(second.items.length, 1);
  assert.equal(metrics.maximumActiveFetches, 1);
  assert.equal(calls.filter(call => call.operation === 'open').length, 1);
  assert.deepEqual(calls.filter(call => call.operation === 'fetch').map(call => call.body), [
    'objectType=2&wd=first',
    'objectType=2&wd=second',
  ]);
});
