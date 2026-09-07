import assert from 'node:assert/strict';
import { createCipheriv, createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('fixture flow covers discovery, search, detail, neutral groups and both player branches', async () => {
  const [list, detail, directPlayer, tokenPlayer, mcueTemplate] = await Promise.all([
    'list.html', 'detail.html', 'player-direct.html', 'player-token.html', 'mcue-player.html',
  ].map((name) => readFile(new URL(`./fixtures/${name}`, import.meta.url), 'utf8')));
  const upstream = 'https://media.invalid/fixture-encrypted.m3u8';
  const digest = createHash('md5').update('balemon').digest('hex');
  const cipher = createCipheriv('aes-128-cbc', Buffer.from(digest.slice(16)), Buffer.from(digest.slice(0, 16)));
  const encrypted = cipher.update(upstream, 'utf8', 'base64') + cipher.final('base64');
  const mcuePlayer = mcueTemplate.replace('__CIPHER__', encrypted);
  const requests = [];
  const resources = [];
  await plugin.activate({
    log: { info() {}, warn() {} },
    errors: { raise(code) { throw Object.assign(new Error(code), { code, name: 'PluginManagerError' }); } },
    resource: {
      proxy(value) {
        resources.push(value);
        return `http://127.0.0.1:9000/v1/source-resource/${resources.length}`;
      },
    },
    http: {
      async fetch(input, init = {}) {
        const url = new URL(input);
        requests.push({ init, url });
        if (url.hostname === 'player.mcue.cc') return new Response(mcuePlayer);
        if (url.pathname === '/v/101.html') return new Response(detail);
        if (url.pathname === '/p/101-3-1.html') return new Response(directPlayer);
        if (url.pathname === '/p/101-5-1.html') return new Response(tokenPlayer);
        return new Response(list);
      },
    },
  });

  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(root.document.components[0].title, '今日更新');
  assert.equal(root.document.components[0].children[0].items[0].content.contentKind, 'video');
  assert.equal(root.document.components[0].children[0].items[0].content.coverOrientation, 'portrait');
  assert.equal(root.document.components[1].children[0].categories.length, 4);
  const discovery = await plugin.discover({ target: 'category:hot', cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(discovery.document.components[0].children[0].items.length, 2);
  const results = await plugin.search({ query: 'fixture', cursor: null, pageSize: 5 });
  assert.equal(results.items[0].id, 'video:101');
  assert.equal(results.items[0].coverOrientation, 'portrait');
  assert.equal(results.items[0].coverUrl, 'https://www.yinhuadm.xyz/upload/fixture-one.jpg');
  assert.deepEqual(results.items[0].latestChapter, {
    id: null, title: '更新至第02集', updatedAt: null, url: null,
  });

  const info = await plugin.getDetail({ id: results.items[0].id });
  assert.equal(info.title, 'Fixture Animation One');
  assert.equal(info.coverOrientation, 'portrait');
  assert.deepEqual(info.tags, ['Fixture Region']);
  assert.deepEqual(info.latestChapter, {
    id: null, title: '更新至第02集', updatedAt: null, url: null,
  });
  const catalog = await plugin.getChapters({ id: info.id });
  assert.deepEqual(catalog.groups.map((group) => group.title), ['Laoz', 'Diff']);
  assert.deepEqual(catalog.groups.map((group) => group.episodes.length), [2, 2]);
  assert.deepEqual(catalog.groups.map((group) => group.episodes.map((episode) => episode.order)), [[0, 1], [0, 1]]);
  assert.deepEqual(catalog.items.map((episode) => episode.order), [0, 1, 2, 3]);
  assert.equal(catalog.items.length, 4);
  const detailRequestsBeforePlayback = requests.filter(({ url }) => url.pathname === '/v/101.html').length;

  const directRequestsBeforePlayback = requests.length;
  const direct = await plugin.getContent({ id: info.id, chapterId: 'video:101:3:1' });
  assert.deepEqual(
    requests.slice(directRequestsBeforePlayback).map(({ url }) => url.pathname),
    ['/p/101-3-1.html'],
  );
  assert.equal(direct.media.resourceType, 'video');
  assert.equal(direct.media.resourcePolicy, 'sessionOnly');
  assert.equal(resources[0].url, 'https://media.invalid/fixture-direct.mp4');
  assert.equal(resources[0].proxyMode, 'direct');
  const mcueRequestsBeforePlayback = requests.length;
  const decrypted = await plugin.getContent({ id: info.id, chapterId: 'video:101:5:1' });
  assert.equal(requests.length - mcueRequestsBeforePlayback, 2);
  assert.equal(requests[mcueRequestsBeforePlayback].url.pathname, '/p/101-5-1.html');
  assert.equal(requests[mcueRequestsBeforePlayback + 1].url.hostname, 'player.mcue.cc');
  assert.equal(decrypted.media.resourceType, 'hls');
  assert.equal(resources[1].url, upstream);
  assert.equal(resources[1].proxyMode, 'direct');
  assert.equal(new URL(resources[1].headers.Referer).origin, 'https://player.mcue.cc');
  assert.ok(requests.some(({ url }) => url.hostname === 'player.mcue.cc'));
  assert.ok(requests.every(({ init }) => init.proxyMode === 'direct'));
  assert.equal(
    requests.filter(({ url }) => url.pathname === '/v/101.html').length,
    detailRequestsBeforePlayback,
  );
});

test('MCUE retries one recoverable response inside one bounded timeout', async () => {
  const [tokenPlayer, mcueTemplate] = await Promise.all([
    'player-token.html', 'mcue-player.html',
  ].map((name) => readFile(new URL(`./fixtures/${name}`, import.meta.url), 'utf8')));
  const upstream = 'https://media.invalid/fixture-retried.m3u8';
  const digest = createHash('md5').update('balemon').digest('hex');
  const cipher = createCipheriv('aes-128-cbc', Buffer.from(digest.slice(16)), Buffer.from(digest.slice(0, 16)));
  const encrypted = cipher.update(upstream, 'utf8', 'base64') + cipher.final('base64');
  const mcuePlayer = mcueTemplate.replace('__CIPHER__', encrypted);
  const warnings = [];
  const signals = [];
  let mcueCalls = 0;
  await plugin.activate({
    log: { info() {}, warn(event) { warnings.push(event); } },
    errors: { raise(code) { throw Object.assign(new Error(code), { code, name: 'PluginManagerError' }); } },
    resource: { proxy(value) { return value.url; } },
    http: {
      async fetch(input, init = {}) {
        const url = new URL(input);
        if (url.hostname !== 'player.mcue.cc') return new Response(tokenPlayer);
        mcueCalls += 1;
        signals.push(init.signal);
        return mcueCalls === 1
          ? new Response('', { status: 503 })
          : new Response(mcuePlayer);
      },
    },
  });

  const content = await plugin.getContent({ id: 'video:101', chapterId: 'video:101:5:1' });

  assert.equal(content.media.url, upstream);
  assert.equal(mcueCalls, 2);
  assert.ok(signals[0] instanceof AbortSignal);
  assert.equal(signals[0], signals[1]);
  assert.deepEqual(warnings, ['source_request_retry']);
});

test('MCUE does not retry deterministic client failures and bounds server retries', async () => {
  const tokenPlayer = await readFile(new URL('./fixtures/player-token.html', import.meta.url), 'utf8');
  for (const [status, expectedCalls] of [[403, 1], [404, 1], [503, 2]]) {
    const warnings = [];
    let mcueCalls = 0;
    await plugin.activate({
      log: { info() {}, warn(event) { warnings.push(event); } },
      errors: { raise(code) { throw Object.assign(new Error(code), { code, name: 'PluginManagerError' }); } },
      resource: { proxy() { throw new Error('unreachable'); } },
      http: {
        async fetch(input) {
          const url = new URL(input);
          if (url.hostname !== 'player.mcue.cc') return new Response(tokenPlayer);
          mcueCalls += 1;
          return new Response('', { status });
        },
      },
    });

    await assert.rejects(
      plugin.getContent({ id: 'video:101', chapterId: 'video:101:5:1' }),
      (error) => error?.code === 'source_media_resolution_failed',
    );
    assert.equal(mcueCalls, expectedCalls);
    assert.equal(warnings.at(-1), 'mcue_resolution_failed');
    assert.equal(warnings.filter((event) => event === 'source_request_retry').length, expectedCalls - 1);
  }
});

test('rejects cursors and chapter identities outside the source-owned contract', async () => {
  await assert.rejects(
    plugin.search({ query: 'fixture', cursor: 'page:2', pageSize: 5 }),
    /Search cursor is invalid/u,
  );
  await assert.rejects(
    plugin.getDetail({ id: 'book:101' }),
    /Content ID is invalid/u,
  );
  await assert.rejects(
    plugin.getContent({ id: 'video:101', chapterId: 'video:101:0:1' }),
    /Chapter ID is invalid/u,
  );
});
