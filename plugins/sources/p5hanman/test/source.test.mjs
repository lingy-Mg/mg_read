/** Deterministic sanitized-fixture coverage for HTML, manga pages and Referer proxying. */
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('fixture chain emits proxied ordered manga pages with guarded Referer requests', async (t) => {
  const cacheDir = await mkdtemp(join(tmpdir(), 'p5hanman-cache-'));
  t.after(() => rm(cacheDir, { recursive: true, force: true }));
  const fixtures = Object.fromEntries(
    await Promise.all(
      ['listing', 'listing-next', 'detail', 'chapter'].map(async (name) => [
        name,
        await readFile(new URL(`./fixtures/${name}.html`, import.meta.url), 'utf8'),
      ]),
    ),
  );
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
        if (url.hostname === 'cfpic.se8manhua.club' || url.hostname === 'cover.aabamh.com') {
          return new Response(new Uint8Array([1, 2, 3]), {
            status: 200,
            headers: { 'content-type': 'image/jpeg' },
          });
        }
        if (url.pathname === '/chapter/9001') return html(fixtures.chapter);
        if (url.pathname === '/book/100') return html(fixtures.detail);
        if (url.pathname === '/booklist' && url.searchParams.get('page') === '2') {
          return html(fixtures['listing-next']);
        }
        return html(fixtures.listing);
      },
    },
  });

  const firstSearch = await plugin.search({ query: 'fixture-secret', cursor: null, pageSize: 1 });
  assert.equal(firstSearch.items.length, 1);
  assert.equal(firstSearch.nextCursor, 'search:1');
  const secondSearch = await plugin.search({ query: 'fixture-secret', cursor: firstSearch.nextCursor, pageSize: 1 });
  assert.equal(secondSearch.items.length, 1);
  assert.equal(secondSearch.nextCursor, null);

  const discovery = await plugin.discover({
    target: 'category:latest',
    cursor: null,
    collectionId: null,
    pageSize: 20,
  });
  assert.equal(discovery.kind, 'document');
  const collection = discovery.document.components[0].children[0];
  assert.equal(collection.items.length, 2);
  assert.equal(collection.items[0].content.contentKind, 'manga');
  assert.equal(collection.continuation.cursor, 'category:latest:2:0');
  const append = await plugin.discover({
    target: 'category:latest',
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
  assert.equal(detail.chapterCount, 2);
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.deepEqual(chapters.items.map((chapter) => chapter.order), [0, 1]);
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.equal(content.text, null);
  assert.equal(content.pages.length, 2);
  assert.deepEqual(content.pages.map((page) => page.index), [0, 1]);
  assert.ok(content.pages.every((page) => page.resourcePolicy === 'sessionOnly'));
  assert.ok(content.pages.every((page) => page.expiresAt === null));
  assert.match(content.pages[0].url, /^http:\/\/127\.0\.0\.1\/resource\//u);

  const pageRequest = proxied.find((request) => request.purpose === 'page');
  assert.deepEqual(pageRequest, {
    kind: 'p5-image',
    purpose: 'page',
    url: 'https://cfpic.se8manhua.club/fixture/001.jpg',
    referer: 'https://www.4p5mha.work/chapter/9001',
  });
  const image = await plugin.resource(pageRequest);
  assert.equal(image.status, 200);
  assert.equal(image.headers['content-type'], 'image/jpeg');
  const imageCall = calls.find((call) => call.url.hostname === 'cfpic.se8manhua.club');
  assert.equal(imageCall.init.headers.referer, 'https://www.4p5mha.work/chapter/9001');
  assert.ok(
    calls.every((call) => {
      const headers = call.init.headers ?? {};
      return headers.cookie === undefined && headers['user-agent'] === undefined;
    }),
  );
  assert.ok(logs.every((entry) => !entry.includes('fixture-secret')));
  assert.ok(logs.every((entry) => !entry.includes('Fixture')));
});

test('rejects cross-book chapters, off-host images and forged Referers', async () => {
  await assert.rejects(
    plugin.getContent({ id: 'manga:200', chapterId: 'chapter:100:9001' }),
    /does not belong/u,
  );
  const offHost = await plugin.resource({
    kind: 'p5-image',
    purpose: 'page',
    url: 'https://example.com/001.jpg',
    referer: 'https://www.4p5mha.work/chapter/9001',
  });
  assert.equal(offHost.status, 400);
  const forgedReferer = await plugin.resource({
    kind: 'p5-image',
    purpose: 'page',
    url: 'https://cfpic.se8manhua.club/fixture/001.jpg',
    referer: 'https://example.com/chapter/9001',
  });
  assert.equal(forgedReferer.status, 400);
});

function html(body) {
  return new Response(body, {
    status: 200,
    headers: { 'content-type': 'text/html; charset=utf-8' },
  });
}
