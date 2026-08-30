import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

const entry = {
  title: 'Fixture Webtoon', title_normalized: '1234567', description: 'Fixture description', thumbnail: '1234567/thumbnail.jpg',
  authors: [{ name: 'Fixture Author' }], genres: [{ name: 'Fixture Tag' }], created_date: '2026-08-01T00:00:00.000Z', modified_date: '2026-08-02T00:00:00.000Z', status: 'completed',
  entries_data: { volume_name: '00', chapters: [
    { name: 'Episode 1', index: 0, images: ['1234567/token/0001.jpg', '1234567/token/0002.webp'] },
    { name: 'Episode 2', index: 1, images: ['1234567/token/0001.png'] },
  ] }, entries_setting: [{ premium: false, isHide: false }],
};
const bookHtml = page({ entrySSR: entry });
const listingJson = JSON.stringify({ data: { entries: { docs: [entry], page: 1, totalPages: 2, totalDocs: 2 } } });

test('fixture chain emits Runtime-proxied session manga manifests and restricts the image proxy', async () => {
  const requests = []; const proxied = [];
  await plugin.activate({ dataDir: 'unused', app: {}, plugin: {}, log: { debug() {}, info() {}, warn() {}, error() {} }, resource: { proxy(request) { proxied.push(request); return `http://127.0.0.1/resource/${proxied.length}`; } }, http: { async fetch(input) { const url = new URL(input); requests.push(url); if (url.origin === 'https://img.rehanman.com') return new Response(new Uint8Array([1, 2]), { headers: { 'content-type': 'image/jpeg' } }); return new Response(url.origin === 'https://api.rehanman.com' ? listingJson : bookHtml, { headers: { 'content-type': 'application/json' } }); } } });
  const discovery = await plugin.discover({ target: null, collectionId: null, cursor: null, pageSize: 1 });
  const item = discovery.document.components[0].children[0].items[0].content;
  assert.deepEqual(discovery.document.components[0].children[0].continuation, { target: 'latest', cursor: 'latest:2' });
  assert.equal(item.id, 'webtoon:1234567'); assert.equal(item.contentKind, 'manga');
  assert.equal(item.coverUrl, 'https://img.rehanman.com/uploads/data/china18sky/1234567/thumbnail.jpg');
  const search = await plugin.search({ query: 'Fixture', cursor: null, pageSize: 20 }); assert.deepEqual(search.items.map((value) => value.id), ['webtoon:1234567']);
  const detail = await plugin.getDetail({ id: item.id }); assert.equal(detail.author, 'Fixture Author');
  const chapters = await plugin.getChapters({ id: item.id }); assert.deepEqual(chapters.items.map((chapter) => chapter.id), ['chapter:1234567:0', 'chapter:1234567:1']);
  const content = await plugin.getContent({ id: item.id, chapterId: chapters.items[0].id }); assert.equal(content.text, null); assert.equal(content.pages.length, 2); assert.deepEqual(proxied, [{ kind: 'rehanman-image', url: 'https://img.rehanman.com/uploads/data/china18sky/1234567/token/0001.jpg', headers: { Accept: 'image/*', Referer: 'https://rehanman.com/' } }, { kind: 'rehanman-image', url: 'https://img.rehanman.com/uploads/data/china18sky/1234567/token/0002.webp', headers: { Accept: 'image/*', Referer: 'https://rehanman.com/' } }]); assert.equal(content.pages[0].url, 'http://127.0.0.1/resource/1'); assert.equal(content.pages[0].resourcePolicy, undefined);
  assert.equal(requests.some((url) => url.origin === 'https://img.rehanman.com'), false);
});

test('refuses premium chapters before emitting image resources', async () => {
  await plugin.activate({ dataDir: 'unused', app: {}, plugin: {}, log: { debug() {}, info() {}, warn() {}, error() {} }, resource: { proxy() { return ''; } }, http: { async fetch() { return new Response(page({ entrySSR: { title: 'Premium', title_normalized: '1234567', entries_data: { volume_name: '00', chapters: [{ name: 'Episode', index: 0, images: ['1234567/token/0001.jpg'] }] }, entries_setting: [{ premium: true, isHide: false }] } })); } } });
  await assert.rejects(() => plugin.getChapters({ id: 'webtoon:1234567' }), /not publicly available/u);
});

function page(pageProps) { return `<html><script id="__NEXT_DATA__" type="application/json">${JSON.stringify({ props: { pageProps } })}</script></html>`; }
