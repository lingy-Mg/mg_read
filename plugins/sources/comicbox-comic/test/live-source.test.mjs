import assert from 'node:assert/strict';
import { createDecipheriv } from 'node:crypto';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('live ComicBox catalog, cover and chapter image descriptors remain reachable', { timeout: 60000 }, async () => {
  const resources = [];
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(request) { resources.push(request); return request.url; } },
    http: { fetch: (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(20000) }) },
  });

  const result = await plugin.discover({ target: 'channel:0', cursor: null, collectionId: null, pageSize: 3 });
  const item = result.document.components[0].children[0].items[0]?.content;
  assert.ok(item);
  assert.ok(item.title);
  assert.match(item.coverUrl ?? '', /^https:\/\//u);
  const cover = resources.find((value) => value.url === item.coverUrl);
  assert.notEqual(cover, undefined);
  await assertDecodedJpeg(cover);

  const detail = await plugin.getDetail({ id: item.id });
  assert.equal(detail.id, item.id);
  assert.equal(detail.title, item.title);
  const chapters = await plugin.getChapters({ id: item.id });
  assert.ok(chapters.items.length > 0);
  const content = await plugin.getContent({ id: item.id, chapterId: chapters.items[0].id });
  assert.equal(content.contentKind, 'manga');
  assert.ok(content.pages.length > 0);
  const page = resources.find((value) => value.url === content.pages[0].url);
  assert.notEqual(page, undefined);
  await assertDecodedJpeg(page);
});

async function assertDecodedJpeg(request) {
  assert.equal(request.resourceTransform, 'aes-cbc-split-image-v1');
  assert.equal(request.urls.length, 2);
  const encrypted = await Promise.all(request.urls.map(async (url) => {
    const response = await fetch(url, { headers: request.headers, signal: AbortSignal.timeout(20000) });
    assert.equal(response.ok, true);
    return Buffer.from(await response.arrayBuffer());
  }));
  const plain = encrypted.map((body) => {
    const decipher = createDecipheriv('aes-128-cbc', Buffer.from('aaaaaaaaaaaaaaaa'), Buffer.from('0123456789aaaaaa'));
    return Buffer.concat([decipher.update(body), decipher.final()]);
  });
  const body = Buffer.concat(plain);
  assert.equal(body[0], 0);
  assert.ok(body.length > 12);
  assert.deepEqual([...body.subarray(0, 2)], [0, 0]);
}
