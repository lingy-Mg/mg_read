/** Bounded public-API/media checks; never download complete videos or signed URLs to logs. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

function activate() {
  const resources = [];
  return plugin.activate({
    log: { info() {} },
    errors: { raise(value) { throw Object.assign(new Error(value.message), { code: value.code }); } },
    resource: { proxy(value) { resources.push(value); return `http://127.0.0.1/resource/${resources.length}`; } },
    http: { fetch: (input, init) => fetch(input, { ...init, signal: AbortSignal.timeout(20000) }) },
  }).then(() => resources);
}

async function prefix(resource) {
  const response = await fetch(resource.url, {
    headers: { ...resource.headers, Range: 'bytes=0-4095' }, signal: AbortSignal.timeout(20000),
  });
  try {
    assert.ok([200, 206].includes(response.status), `resource HTTP ${response.status}`);
    assert.match(response.headers.get('content-type') ?? '', resource.kind === 'video' ? /video\/mp4|octet-stream/u : /image\//u);
    const reader = response.body.getReader();
    const chunks = []; let length = 0;
    try {
      while (length < 32) {
        const next = await reader.read();
        if (next.done) break;
        chunks.push(Buffer.from(next.value.subarray(0, 4096 - length))); length += chunks.at(-1).length;
      }
    } finally { await reader.cancel(); }
    const bytes = Buffer.concat(chunks);
    if (resource.kind === 'video') assert.equal(bytes.toString('ascii', 4, 8), 'ftyp');
    else assert.ok(bytes.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff]))
      || bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
      || (bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP'), 'cover signature');
  } finally { if (!response.bodyUsed) await response.body?.cancel(); }
}

test('live URL lookup, complete multipart catalog, cover and first/middle/last MP4 prefixes', async () => {
  const resources = await activate();
  const result = await plugin.search({ query: 'https://www.bilibili.com/video/BV1tGe36YEap/', cursor: null, pageSize: 20 });
  assert.equal(result.items[0].id, 'bvid:BV1tGe36YEap');
  const id = result.items[0].id;
  const detail = await plugin.getDetail({ id });
  assert.equal(detail.contentKind, 'video');
  await prefix(resources.find((item) => item.kind === 'image'));
  const catalog = await plugin.getChapters({ id });
  assert.equal(catalog.items.length, 34);
  assert.equal(catalog.items.at(-1).title, '711-760完结');
  assert.deepEqual(catalog.groups.flatMap((group) => group.episodes), catalog.items);
  for (const index of [0, Math.floor(catalog.items.length / 2), catalog.items.length - 1]) {
    const chapter = catalog.items[index];
    const content = await plugin.getContent({ id, chapterId: chapter.id });
    assert.equal(content.chapterId, chapter.id);
    assert.equal(content.media.resourceType, 'video');
    await prefix(resources.at(-1));
  }
});

test('live keyword search returns video summaries and an accessible search cover', async (t) => {
  const resources = await activate();
  let result;
  try { result = await plugin.search({ query: '逃荒路上带飞全家', cursor: null, pageSize: 10 }); }
  catch (error) {
    if (error.code === 'source_access_blocked') { t.skip(error.message); return; }
    throw error;
  }
  assert.ok(result.items.length > 0);
  assert.ok(result.items.every((item) => item.contentKind === 'video'));
  await prefix(resources.find((item) => item.kind === 'image'));
});
