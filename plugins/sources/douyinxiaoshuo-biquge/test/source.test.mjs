/** Deterministic sanitized-fixture coverage for every source capability. */
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('fixture covers search paging discovery continuation detail full catalog and multipage text', async (t) => {
  const cacheDir = await mkdtemp(join(tmpdir(), 'douyinxs-cache-'));
  t.after(() => rm(cacheDir, { recursive: true, force: true }));
  const fixtures = Object.fromEntries(
    await Promise.all(
      ['search', 'category', 'category-next', 'detail', 'catalog-next', 'content', 'content-next'].map(
        async (name) => [
          name,
          await readFile(new URL(`./fixtures/${name}.html`, import.meta.url), 'utf8'),
        ],
      ),
    ),
  );
  const calls = [];
  const logs = [];
  const resources = [];

  await plugin.activate({
    dataDir: cacheDir,
    cacheDir,
    app: {},
    plugin: {},
    log: {
      debug(value) { logs.push(value); },
      info(value) { logs.push(value); },
      warn(value) { logs.push(value); },
      error(value) { logs.push(value); },
    },
    resource: {
      proxy(request) {
        resources.push(request);
        return `http://127.0.0.1/resource/${resources.length}`;
      },
    },
    http: {
      async fetch(input, init = {}) {
        const url = new URL(input);
        calls.push({ url, init });
        if (url.hostname === 'img.douyinxs.com') {
          return new Response(new Uint8Array([1, 2, 3]), {
            status: 200,
            headers: { 'content-type': 'image/jpeg' },
          });
        }
        if (init.method === 'POST') return html(fixtures.search);
        if (url.pathname === '/fenlei/') return html(fixtures.category);
        if (url.pathname === '/fenlei/2/') return html(fixtures['category-next']);
        if (url.pathname === '/bqg/100/') return html(fixtures.detail);
        if (url.pathname === '/bqg/100_2/') return html(fixtures['catalog-next']);
        if (url.pathname === '/bqg/100/1001.html') return html(fixtures.content);
        if (url.pathname === '/bqg/100/1001_2.html') return html(fixtures['content-next']);
        throw new Error('Unexpected fixture request.');
      },
    },
  });

  const firstSearchPage = await plugin.search({
    query: 'fixture-secret',
    cursor: null,
    pageSize: 1,
  });
  assert.equal(firstSearchPage.items.length, 1);
  assert.equal(firstSearchPage.nextCursor, 'search:1');
  const secondSearchPage = await plugin.search({
    query: 'fixture-secret',
    cursor: firstSearchPage.nextCursor,
    pageSize: 1,
  });
  assert.equal(secondSearchPage.items.length, 1);
  assert.equal(secondSearchPage.nextCursor, null);

  const home = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 10 });
  assert.equal(home.document.components[0].children[0].layout, 'shelf');
  assert.equal(home.document.components[0].children[0].items[0].content.contentKind, 'novel');
  assert.equal(home.document.components[1].children[0].layout, 'chips');

  const discovery = await plugin.discover({
    target: 'category:all',
    cursor: null,
    collectionId: null,
    pageSize: 20,
  });
  assert.equal(discovery.kind, 'document');
  const collection = discovery.document.components[0].children[0];
  assert.equal(collection.items.length, 2);
  assert.equal(collection.continuation.cursor, 'category:all:2:0');
  const append = await plugin.discover({
    target: 'category:all',
    cursor: collection.continuation.cursor,
    collectionId: collection.id,
    pageSize: 20,
  });
  assert.equal(append.kind, 'append');
  assert.equal(append.items.length, 1);
  assert.equal(append.continuation, null);

  const detail = await plugin.getDetail({ id: firstSearchPage.items[0].id });
  assert.equal(detail.author, 'Fixture Author');
  assert.equal(detail.status, 'ongoing');
  assert.equal(detail.attributes[0].key, 'source_update_time');
  assert.match(detail.coverUrl, /^http:\/\/127\.0\.0\.1\/resource\//u);

  const chapters = await plugin.getChapters({ id: detail.id });
  assert.deepEqual(
    chapters.items.map((chapter) => chapter.order),
    [0, 1, 2, 3],
  );
  const content = await plugin.getContent({
    id: detail.id,
    chapterId: chapters.items[0].id,
  });
  assert.match(content.text, /Fixture first page paragraph/u);
  assert.match(content.text, /Fixture second page paragraph/u);
  assert.doesNotMatch(content.text, /加入书签/u);
  assert.deepEqual(content.pages, []);
  await assert.rejects(
    plugin.getContent({
      id: secondSearchPage.items[0].id,
      chapterId: chapters.items[0].id,
    }),
    /does not belong/u,
  );

  assert.equal(resources[0].kind, 'image');
  assert.ok(resources[0].url.startsWith('https://'));
  const sourceCalls = calls.filter((call) => call.url.hostname === 'm.douyinxs.com');
  assert.ok(
    sourceCalls.every((call) => {
      const headers = call.init.headers ?? {};
      return headers.cookie === undefined && headers['user-agent'] === undefined;
    }),
  );
  const post = sourceCalls.find((call) => call.init.method === 'POST');
  assert.equal(post.init.body, 'searchkey=fixture-secret');
  assert.ok(logs.every((entry) => !entry.includes('fixture-secret')));
  assert.ok(logs.every((entry) => !entry.includes('Fixture')));
});

test('rejects forged opaque ids and invalid continuation state', async () => {
  await assert.rejects(
    plugin.getDetail({ id: 'book:aHR0cHM6Ly9leGFtcGxlLmNvbS8' }),
    /Opaque ID/u,
  );
  await assert.rejects(
    plugin.discover({
      target: 'category:all',
      cursor: 'category:urban:2:0',
      collectionId: 'category-books:all',
      pageSize: 20,
    }),
    /cursor/u,
  );
});

function html(body) {
  return new Response(body, {
    status: 200,
    headers: { 'content-type': 'text/html; charset=utf-8' },
  });
}
