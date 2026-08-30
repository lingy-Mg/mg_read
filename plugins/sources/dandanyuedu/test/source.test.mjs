/** Deterministic fixtures cover public QQ API fields and anonymous content-client behavior. */
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('fixture chain covers paged search discovery detail complete catalog and real text projection', async (t) => {
  const cacheDir = await mkdtemp(join(tmpdir(), 'dandan-cache-'));
  t.after(() => rm(cacheDir, { recursive: true, force: true }));
  const listing = await readFile(new URL('./fixtures/listing.html', import.meta.url), 'utf8');
  const listingNext = await readFile(new URL('./fixtures/listing-next.html', import.meta.url), 'utf8');
  const searchFixture = JSON.parse(await readFile(new URL('./fixtures/search.json', import.meta.url), 'utf8'));
  const detailFixture = await readFile(new URL('./fixtures/detail.json', import.meta.url), 'utf8');
  const catalogFixture = await readFile(new URL('./fixtures/catalog.json', import.meta.url), 'utf8');
  const contentFixture = await readFile(new URL('./fixtures/content.json', import.meta.url), 'utf8');
  const calls = [];
  const logs = [];
  const proxied = [];
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
        proxied.push(request);
        return `http://127.0.0.1/resource/${proxied.length}`;
      },
    },
    http: {
      async fetch(input, init = {}) {
        const url = new URL(input);
        calls.push({ url, init });
        if (url.hostname === 'wfqqreader-1252317822.image.myqcloud.com') {
          return new Response(new Uint8Array([1, 2, 3]), {
            status: 200,
            headers: { 'content-type': 'image/jpeg' },
          });
        }
        if (url.hostname === 'newopensearch.reader.qq.com') {
          const start = Number(url.searchParams.get('start'));
          const end = Number(url.searchParams.get('end'));
          const books = searchFixture.booklist.slice(start, end + 1);
          return json({ ...searchFixture, booklist: books, booknum: books.length, nextstart: start + books.length });
        }
        if (url.pathname.endsWith('/intro-info')) return jsonText(detailFixture);
        if (url.pathname.endsWith('/all-chapter')) return jsonText(catalogFixture);
        if (url.pathname.endsWith('/ads-read')) return jsonText(contentFixture);
        if (url.pathname.endsWith('_2')) return html(listingNext);
        return html(listing);
      },
    },
  });

  const firstSearch = await plugin.search({ query: 'fixture-secret', cursor: null, pageSize: 1 });
  assert.equal(firstSearch.items.length, 1);
  assert.equal(firstSearch.nextCursor, 'search:1');
  const secondSearch = await plugin.search({ query: 'fixture-secret', cursor: firstSearch.nextCursor, pageSize: 1 });
  assert.equal(secondSearch.items.length, 1);
  assert.equal(secondSearch.items[0].id, 'qqbook:1100000200');

  const home = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 10 });
  assert.equal(home.document.components[0].children[0].layout, 'shelf');
  assert.equal(home.document.components[0].children[0].items[0].content.contentKind, 'novel');
  assert.equal(home.document.components[1].children[0].layout, 'chips');

  const discovery = await plugin.discover({
    target: 'category:ancient-romance',
    cursor: null,
    collectionId: null,
    pageSize: 20,
  });
  assert.equal(discovery.kind, 'document');
  const collection = discovery.document.components[0].children[0];
  assert.equal(collection.items.length, 20);
  assert.equal(collection.continuation.cursor, 'category:ancient-romance:2:0');
  const append = await plugin.discover({
    target: 'category:ancient-romance',
    cursor: collection.continuation.cursor,
    collectionId: collection.id,
    pageSize: 20,
  });
  assert.equal(append.kind, 'append');
  assert.equal(append.items.length, 1);
  assert.equal(append.continuation, null);

  const detail = await plugin.getDetail({ id: firstSearch.items[0].id });
  assert.equal(detail.author, 'Fixture Author');
  assert.equal(detail.status, 'ongoing');
  assert.equal(detail.access, 'mixed');
  assert.equal(detail.chapterCount, 2);
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.equal(chapters.items.length, 2);
  assert.equal(chapters.items[1].isLocked, true);
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.equal(content.text, 'Fixture paragraph one.\nFixture paragraph two.');
  assert.deepEqual(content.pages, []);

  const contentCall = calls.find((call) => call.url.pathname.endsWith('/ads-read'));
  assert.match(contentCall.init.headers['q-guid'], /^[a-f0-9]{32}$/u);
  assert.notEqual(contentCall.init.headers['q-guid'], '4aa27c7cf2d9aca3359656ea186488cb');
  assert.equal(contentCall.init.headers.referer, 'https://bookshelf.html5.qq.com/');
  assert.ok(
    calls.every((call) => {
      const headers = call.init.headers ?? {};
      return headers.cookie === undefined && headers['user-agent'] === undefined;
    }),
  );
  const coverRequest = proxied.find((request) => request.kind === 'qq-cover');
  assert.ok(coverRequest.url.startsWith('https://'));
  assert.ok(logs.every((entry) => !entry.includes('fixture-secret')));
  assert.ok(logs.every((entry) => !entry.includes('Fixture')));
});

test('rejects cross-book chapters and missing source content', async () => {
  await assert.rejects(
    plugin.getContent({ id: 'qqbook:1100000200', chapterId: 'chapter:1100000100:1' }),
    /does not belong/u,
  );
});

function html(body) {
  return new Response(body, { status: 200, headers: { 'content-type': 'text/html; charset=utf-8' } });
}

function json(value) {
  return new Response(JSON.stringify(value), { status: 200, headers: { 'content-type': 'application/json' } });
}

function jsonText(value) {
  return new Response(value, { status: 200, headers: { 'content-type': 'application/json' } });
}
