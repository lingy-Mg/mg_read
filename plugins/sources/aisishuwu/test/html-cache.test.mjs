import assert from 'node:assert/strict';
import { mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { PluginHtmlCache } from '../dist/html-cache.js';

test('stores only below the supplied cache root and serves a fresh hit', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-aisishuwu-cache-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  let calls = 0;
  const cache = new PluginHtmlCache(join(root, 'org.mgread.aisishuwu'));
  const policy = { namespace: 'listing', staleAfterMs: 10 * 60 * 1000 };
  const url = new URL('https://www.alicesw.com/lists/71.html?page=1');

  assert.equal(await cache.getOrFetch(url, policy, async () => {
    calls += 1;
    return '<html>first</html>';
  }), '<html>first</html>');
  const reloadedCache = new PluginHtmlCache(join(root, 'org.mgread.aisishuwu'));
  assert.equal(await reloadedCache.getOrFetch(url, policy, async () => {
    calls += 1;
    return '<html>second</html>';
  }), '<html>first</html>');
  assert.equal(calls, 1);
  assert.deepEqual(await readdir(root), ['org.mgread.aisishuwu']);
});

test('uses stale data only as an offline fallback after the refresh window', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-aisishuwu-cache-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  let now = 0;
  const cache = new PluginHtmlCache(root, { now: () => now });
  const policy = { namespace: 'detail', staleAfterMs: 10 };
  const url = new URL('https://www.alicesw.com/novel/52801.html');

  await cache.getOrFetch(url, policy, async () => '<html>cached</html>');
  now = 11;
  assert.equal(
    await cache.getOrFetch(url, policy, async () => {
      throw new Error('offline');
    }),
    '<html>cached</html>',
  );
});

test('serves an expired discovery projection first and refreshes it once in the background', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-aisishuwu-cache-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  let now = 0;
  let refreshes = 0;
  const cache = new PluginHtmlCache(root, { now: () => now });
  const policy = { namespace: 'discovery', staleAfterMs: 10, serveStaleWhileRevalidate: true };
  const url = new URL('https://www.alicesw.com/lists/71.html');

  await cache.getOrFetch(url, policy, async () => '<html>old</html>');
  now = 11;
  assert.equal(await cache.getOrFetch(url, policy, async () => {
    refreshes += 1;
    return '<html>new</html>';
  }), '<html>old</html>');
  await new Promise((resolve) => setTimeout(resolve, 25));
  assert.equal(refreshes, 1);
  assert.equal(await cache.getOrFetch(url, policy, async () => '<html>unexpected</html>'), '<html>new</html>');
});

test('does not use expired detail data when a strict refresh fails', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-aisishuwu-cache-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  let now = 0;
  const cache = new PluginHtmlCache(root, { now: () => now });
  const policy = { namespace: 'detail', staleAfterMs: 10, allowStaleOnError: false };
  const url = new URL('https://www.alicesw.com/novel/52801.html');
  await cache.getOrFetch(url, policy, async () => '<html>old detail</html>');
  now = 11;
  await assert.rejects(cache.getOrFetch(url, policy, async () => { throw new Error('offline'); }), /offline/u);
});

test('a strict detail request joins an active discovery refresh for the same HTML', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-aisishuwu-cache-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  let now = 0;
  let release;
  let started;
  const refreshStarted = new Promise((resolve) => { started = resolve; });
  const refreshReleased = new Promise((resolve) => { release = resolve; });
  const cache = new PluginHtmlCache(root, { now: () => now });
  const url = new URL('https://www.alicesw.com/novel/52801.html');
  await cache.getOrFetch(url, { namespace: 'detail', staleAfterMs: 10 }, async () => '<html>old</html>');
  now = 11;
  await cache.getOrFetch(url, { namespace: 'detail', staleAfterMs: 10, serveStaleWhileRevalidate: true }, async () => {
    started();
    await refreshReleased;
    return '<html>fresh</html>';
  });
  await refreshStarted;
  let strictFetches = 0;
  const strict = cache.getOrFetch(url, { namespace: 'detail', staleAfterMs: 10, allowStaleOnError: false }, async () => {
    strictFetches += 1;
    return '<html>unexpected</html>';
  });
  release();
  assert.equal(await strict, '<html>fresh</html>');
  assert.equal(strictFetches, 0);
});

test('does not write when Runtime did not provide an absolute cache directory', async () => {
  let calls = 0;
  const cache = new PluginHtmlCache('relative-cache');
  const result = await cache.getOrFetch(
    new URL('https://www.alicesw.com/lists/71.html'),
    { namespace: 'listing', staleAfterMs: 10 },
    async () => {
      calls += 1;
      return '<html>uncached</html>';
    },
  );
  assert.equal(result, '<html>uncached</html>');
  assert.equal(calls, 1);
});

test('coalesces concurrent reads of the same request into one remote fetch', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-aisishuwu-cache-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  let calls = 0;
  let release;
  const fetched = new Promise((resolve) => { release = resolve; });
  const cache = new PluginHtmlCache(root);
  const policy = { namespace: 'listing', staleAfterMs: 10 * 60 * 1000 };
  const url = new URL('https://www.alicesw.com/lists/71.html');
  const request = () => cache.getOrFetch(url, policy, async () => {
    calls += 1;
    return fetched;
  });

  const first = request();
  const second = request();
  release('<html>shared</html>');
  assert.deepEqual(await Promise.all([first, second]), ['<html>shared</html>', '<html>shared</html>']);
  assert.equal(calls, 1);
});

test('evicts least-recently-used entries and never stores oversized HTML', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-aisishuwu-cache-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  const cache = new PluginHtmlCache(root, {
    maximumCacheBytes: 240,
    maximumEntryBytes: 120,
  });
  const policy = { namespace: 'listing', staleAfterMs: 10 * 60 * 1000 };
  let calls = 0;
  const load = (id, body = `<html>${id.padEnd(45, '_')}</html>`) =>
    cache.getOrFetch(
      new URL(`https://www.alicesw.com/lists/${id}.html`),
      policy,
      async () => {
        calls += 1;
        return body;
      },
    );

  await load('1');
  await load('2');
  await load('3');
  await load('1');
  await load('oversized', '<html>xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx</html>');
  await load('oversized', '<html>xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx</html>');
  assert.equal(calls, 6);
});

test('treats corrupted files as a cache miss without escaping the cache root', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-aisishuwu-cache-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  const policy = { namespace: 'listing', staleAfterMs: 10 * 60 * 1000 };
  const url = new URL('https://www.alicesw.com/lists/71.html');
  const cache = new PluginHtmlCache(root);
  await cache.getOrFetch(url, policy, async () => '<html>first</html>');
  const cacheRoot = join(root, 'html-cache-v1');
  const [entry] = await readdir(cacheRoot);
  await writeFile(join(cacheRoot, entry), 'not-json', 'utf8');
  assert.equal(
    await new PluginHtmlCache(root).getOrFetch(url, policy, async () => '<html>recovered</html>'),
    '<html>recovered</html>',
  );
});
