import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import * as plugin from '../dist/index.mjs';

test('browser fixture covers search detail full catalog text cover proxy and no credential fields', async (t) => {
  const cacheDir = await mkdtemp(join(tmpdir(), 'bz-cache-'));
  t.after(() => rm(cacheDir, { recursive: true, force: true }));
  const list = await readFile(new URL('./fixtures/list.html', import.meta.url), 'utf8');
  const detail = await readFile(new URL('./fixtures/detail.html', import.meta.url), 'utf8');
  const content = await readFile(new URL('./fixtures/content.html', import.meta.url), 'utf8');
  const calls = [];
  const resources = [];
  await plugin.activate({
    dataDir: cacheDir,
    cacheDir,
    app: {},
    plugin: {},
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/r/${resources.length}`; } },
    http: { async fetch() { return new Response(new Uint8Array([9])); } },
    browser: { sessionV1: { async request(request) { calls.push(request); const path = new URL(request.url).pathname; return { status: 200, body: path.endsWith('.html') && path.startsWith('/book/') ? content : path === '/book/123/' ? detail : list }; } } },
  });
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
  assert.ok(calls.every((request) => request.headers.cookie === undefined && request.headers['user-agent'] === undefined && request.transport === 'webview' && request.presentation === 'visible' && request.headers.referer === 'https://www.bz777777777.com/'));
});
