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
    resource: {
      proxy(value) {
        resources.push(value);
        return `http://127.0.0.1:9000/v1/source-resource/${resources.length}`;
      },
    },
    http: {
      async fetch(input) {
        const url = new URL(input);
        requests.push(url);
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
  assert.equal(root.document.components[1].children[0].categories.length, 4);
  const discovery = await plugin.discover({ target: 'category:hot', cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(discovery.document.components[0].children[0].items.length, 2);
  const results = await plugin.search({ query: 'fixture', cursor: null, pageSize: 5 });
  assert.equal(results.items[0].id, 'video:101');
  assert.equal(results.items[0].coverUrl, 'https://www.yinhuadm.xyz/upload/fixture-one.jpg');
  assert.deepEqual(results.items[0].latestChapter, {
    id: null, title: '更新至第02集', updatedAt: null, url: null,
  });

  const info = await plugin.getDetail({ id: results.items[0].id });
  assert.equal(info.title, 'Fixture Animation One');
  assert.deepEqual(info.tags, ['Fixture Region']);
  assert.deepEqual(info.latestChapter, {
    id: null, title: '更新至第02集', updatedAt: null, url: null,
  });
  const catalog = await plugin.getChapters({ id: info.id });
  assert.deepEqual(catalog.groups.map((group) => group.title), ['线路 5', '线路 3']);
  assert.deepEqual(catalog.groups.map((group) => group.episodes.length), [2, 2]);
  assert.equal(catalog.items.length, 4);

  const direct = await plugin.getContent({ id: info.id, chapterId: 'video:101:3:1' });
  assert.equal(direct.media.resourceType, 'video');
  assert.equal(direct.media.resourcePolicy, 'sessionOnly');
  assert.equal(resources[0].url, 'https://media.invalid/fixture-direct.mp4');
  const decrypted = await plugin.getContent({ id: info.id, chapterId: 'video:101:5:1' });
  assert.equal(decrypted.media.resourceType, 'hls');
  assert.equal(resources[1].url, upstream);
  assert.equal(new URL(resources[1].headers.Referer).origin, 'https://player.mcue.cc');
  assert.ok(requests.some((url) => url.hostname === 'player.mcue.cc'));
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
});
