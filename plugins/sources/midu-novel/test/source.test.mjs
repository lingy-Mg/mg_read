/** Deterministic fixtures cover native H5 discovery, signing, cold detail, catalog and text. */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

const bookId = '07f41e40fbc4d856d96a7237a459f29c';

test('native source covers recommendation, search, cold detail, catalog and content without secure storage', async () => {
  const calls = [];
  const resources = [];
  await plugin.activate(context(async (input, init = {}) => {
    const url = new URL(input);
    calls.push({ url, init });
    if (url.pathname === '/fiction/search/search') {
      assert.equal(new URLSearchParams(init.body).get('page'), '0');
      return json({ data: [fixtureBook] });
    }
    if (url.pathname === '/fiction/recommend/searchPage') {
      return json({ data: { recommendNode: [{ nodeData: { books: [{ bookData: fixtureBook }] } }] } });
    }
    if (url.pathname === '/content/chapterList') {
      const enc = new URLSearchParams(init.body).get('EncStr');
      assert.ok(enc);
      const signed = JSON.parse(Buffer.from(enc, 'base64').toString('utf8'));
      assert.equal(signed.hash_id, bookId);
      assert.match(signed.sign, /^[0-9a-f]{128}$/u);
      const canonical = `${Object.keys(signed).filter((key) => key !== 'sign').sort().map((key) => `${key}=${signed[key]}`).join('&')}&key=T^xS0x31XL%wEowC`;
      const md5 = createHash('md5').update(canonical).digest('hex');
      assert.equal(signed.sign, Buffer.from([...md5].map((character) => character.charCodeAt(0) ^ 5)).toString('hex'));
      return json({ code: 0, data: { title: 'Fixture Midu', url: 'https://book.midukanshu.com/catalog.json' } });
    }
    if (url.pathname === '/catalog.json') return json([{ bookId, chapterId: 'c1', title: '第一章' }, { bookId, chapterId: 'c2', title: '第二章' }]);
    if (url.pathname.endsWith(`/${bookId}_c1.txt`)) return new Response('第一段\r\n第二段');
    throw new Error(`Unexpected URL: ${url}`);
  }, resources));

  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 10 });
  assert.equal(root.document.components[0].children[0].items[0].content.title, 'Fixture Midu');
  assert.equal(root.document.components.at(-1).children[0].categories.length, 13);
  const search = await plugin.search({ query: 'Fixture', cursor: null, pageSize: 10 });
  assert.equal(search.items[0].id, `midu:${bookId}`);
  assert.equal(resources.length, 2);

  await plugin.activate(context(async (input, init = {}) => {
    const url = new URL(input);
    calls.push({ url, init });
    if (url.pathname === '/content/chapterList') return json({ code: 0, data: { title: 'Fixture Midu', url: 'https://book.midukanshu.com/catalog.json' } });
    if (url.pathname === '/catalog.json') return json([{ bookId, chapterId: 'c1', title: '第一章' }]);
    if (url.pathname.endsWith(`/${bookId}_c1.txt`)) return new Response('第一段\r\n第二段');
    throw new Error(`Unexpected URL: ${url}`);
  }, resources));
  const detail = await plugin.getDetail({ id: `midu:${bookId}` });
  assert.equal(detail.title, 'Fixture Midu');
  assert.equal(detail.author, null);
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.equal(chapters.items[0].title, '第一章');
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.equal(content.text, '第一段\n第二段');
  assert.equal(calls.filter(({ url }) => url.pathname === '/content/chapterList').length, 1);
});

test('invalid content and chapter ids are rejected before network access', async () => {
  await assert.rejects(plugin.getDetail({ id: 'midu:invalid' }), /Content ID is invalid/u);
  await assert.rejects(plugin.getContent({ id: `midu:${bookId}`, chapterId: `midu:${bookId}:bad%2Fid` }), /Chapter ID is invalid/u);
});

const fixtureBook = {
  book_id: bookId,
  title: 'Fixture Midu',
  author: 'Fixture Author',
  cover: 'https://img.midukanshu.com/fixture.jpg',
  description: 'Fixture description',
  category: '玄幻',
  chapterNum: 2,
  end_status: 1,
};

function context(fetch, resources = []) {
  return {
    dataDir: 'fixture-data', cacheDir: 'fixture-cache',
    app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.midu-novel', version: '1.0.0' },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/resource/${resources.length}`; } },
    http: { fetch },
  };
}

function json(value, init) { return new Response(JSON.stringify(value), { ...init, headers: { 'content-type': 'application/json' } }); }
