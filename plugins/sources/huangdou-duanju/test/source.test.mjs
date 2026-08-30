import assert from 'node:assert/strict';
import { createCipheriv, createDecipheriv, createHmac, randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { gunzipSync, gzipSync } from 'node:zlib';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

const apiKey = '7961beb44246e3012ce228d6b5ced05a';
const fixture = JSON.parse(await readFile(new URL('./fixtures/api.json', import.meta.url), 'utf8'));

test('encrypted fixture covers discovery, search, detail, episodes and HLS proxy metadata', async () => {
  const calls = [];
  const resources = [];
  await plugin.activate({
    log: { debug() {}, error() {}, info() {}, warn() {} },
    resource: {
      proxy(value) {
        resources.push(value);
        return `http://127.0.0.1:9000/v1/source-resource/${resources.length}`;
      },
    },
    http: {
      async fetch(input, init) {
        const url = new URL(String(input));
        const requestId = String(init.headers.requestId);
        const request = decryptRequest(init.body, requestId);
        calls.push({ path: url.pathname, request });
        const response = responseFor(url.pathname);
        return new Response(encryptResponse(response, requestId), { status: 200 });
      },
    },
  });

  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 1 });
  assert.equal(root.document.components[0].title, '热门短剧');
  assert.equal(root.document.components[0].children[0].items[0].content.contentKind, 'video');
  assert.equal(root.document.components[0].children[0].items[0].content.coverUrl.startsWith('http://127.0.0.1:'), true);
  const categories = root.document.components[1].children[0].categories;
  assert.equal(categories.some((item) => item.title === '排行榜'), true);
  assert.equal(categories.some((item) => item.title === '都市'), true);
  assert.equal(categories.some((item) => item.title === '国产传媒'), false);

  const category = categories.find((item) => item.title === '精选');
  const discovery = await plugin.discover({ target: category.target, cursor: null, collectionId: null, pageSize: 1 });
  assert.equal(discovery.document.components[0].children[0].items.length, 1);
  const continuation = discovery.document.components[0].children[0].continuation;
  const appended = await plugin.discover({ target: category.target, cursor: continuation.cursor, collectionId: discovery.document.components[0].children[0].id, pageSize: 1 });
  assert.equal(appended.kind, 'append');

  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 1 });
  assert.equal(search.items.length, 1);
  assert.notEqual(search.nextCursor, null);
  const detail = await plugin.getDetail({ id: search.items[0].id });
  assert.equal(detail.chapterCount, 2);
  assert.equal(detail.catalogUrl, null);
  const catalog = await plugin.getChapters({ id: detail.id });
  assert.equal(catalog.items.length, 2);
  assert.equal(catalog.items[0].isLocked, false);
  assert.equal(catalog.items[1].isLocked, true);
  assert.equal(catalog.items[1].attributes[0].value, '金币 3');

  const content = await plugin.getContent({ id: detail.id, chapterId: catalog.items[0].id });
  assert.equal(content.contentKind, 'video');
  assert.equal(content.text, null);
  assert.deepEqual(content.pages, []);
  assert.equal(content.media.resourceType, 'hls');
  assert.equal(content.media.resourcePolicy, 'sessionOnly');
  assert.equal(content.media.url.startsWith('http://127.0.0.1:'), true);
  const mediaResource = resources.find((value) => value.kind === 'hls');
  assert.equal(mediaResource.url, 'https://media.example/fixture.m3u8');
  assert.equal(mediaResource.headers.Range, undefined);
  assert.equal(calls[0].path, '/api/login/device');
  assert.equal(calls[0].request.token, '');
  assert.equal(typeof calls[0].request.deviceId, 'string');
  assert.equal(calls.slice(1).every((call) => call.request.token === 'fixture-session'), true);
  assert.equal(calls.some((call) => call.path === '/api/drama/navFilter' && call.request.data.cat_id === undefined), true);
});

function responseFor(path) {
  if (path === '/api/login/device') return { status: 'y', data: { token: 'fixture-session', user_id: 'fixture-user' } };
  const key = path.split('/').at(-1);
  const value = fixture[key];
  if (value === undefined) throw new Error(`Unexpected fixture route: ${path}`);
  return { status: 'y', ...value };
}

function decryptRequest(body, requestId) {
  const bytes = Buffer.from(body);
  const decipher = createDecipheriv('aes-256-cbc', requestKey(requestId), bytes.subarray(0, 16));
  const compressed = Buffer.concat([decipher.update(bytes.subarray(16)), decipher.final()]);
  return JSON.parse(gunzipSync(compressed).toString('utf8'));
}

function encryptResponse(value, requestId) {
  const iv = randomBytes(16);
  const cipher = createCipheriv('aes-256-cbc', requestKey(requestId), iv);
  const compressed = gzipSync(Buffer.from(JSON.stringify(value), 'utf8'));
  return Buffer.concat([iv, cipher.update(compressed), cipher.final()]);
}

function requestKey(requestId) {
  return createHmac('sha256', apiKey).update(Buffer.from(requestId, 'hex')).digest();
}
