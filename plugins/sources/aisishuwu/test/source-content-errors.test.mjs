// Empty/missing source bodies must reach the reader as a failure with a chapter address.
import assert from 'node:assert/strict';
import test from 'node:test';
import { AliceBookHouseSource } from '../dist/source.js';
import { createSourceTestHarness } from '@mgread/source-testkit';
import * as plugin from '../dist/index.mjs';

const url = 'https://www.alicesw.com/book/42/first.html';
const chapterId = `chapter:${Buffer.from('/book/42/first.html').toString('base64url')}`;
const create = (body, status = 200) => new AliceBookHouseSource({
  cacheDir: 'unused-cache',
  http: {fetch: async () => new Response(body, {status})},
}, {origin: 'https://www.alicesw.com/', categories: []});

test('empty and missing chapter content include the failing address', async () => {
  for (const [body, reason] of [
    ['<div class="read-content"><script>ad()</script><br> </div>', '章节正文为空'],
    ['<h1>网页未提供正文</h1>', '未找到章节正文区域'],
  ]) {
    await assert.rejects(create(body).getContent({id: 'novel:42', chapterId}), error =>
      error.message.includes(reason) && error.message.includes(url));
  }
});

test('HTTP failures preserve the status and failing address', async () => {
  await assert.rejects(create('not found', 404).getContent({id: 'novel:42', chapterId}), error =>
    error.message.includes('HTTP 404') && error.message.includes(url));
});

test('long chapter is returned completely without truncation', async () => {
  const text = '长章节正文。'.repeat(8000);
  const result = await create(`<div class="read-content">${text}</div>`).getContent({id: 'novel:42', chapterId});
  assert.equal(result.text, text);
});

test('public entry preserves empty, HTTP and nested network errors for Runtime', async (t) => {
  let failure;
  let response = new Response('<div class="read-content"> </div>');
  const harness = await createSourceTestHarness({
    plugin, pluginId: 'org.mgread.aisishuwu', version: '0.2.19',
    fetch: async () => { if (failure) throw failure; return response.clone(); },
  });
  t.after(harness.cleanup);
  const request = {id: 'novel:42', chapterId};
  await assert.rejects(plugin.getContent(request), /章节正文为空.*book\/42\/first.html/u);
  response = new Response('missing', {status: 404});
  await assert.rejects(plugin.getContent(request), /HTTP 404.*book\/42\/first.html/u);
  failure = new TypeError('fetch failed', {cause: new Error('ECONNRESET')});
  await assert.rejects(plugin.getContent(request), error => error === failure && error.cause.message === 'ECONNRESET');
});
