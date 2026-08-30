/** Contract and deterministic single-file packaging checks. */
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { BoundedTextCache } from '../dist/cache.js';
import * as plugin from '../dist/index.mjs';
import { buildPluginArtifact } from '../tools/mgread.mjs';

test('exports Plugin API v1 and builds a deterministic single-file artifact', async () => {
  assert.deepEqual(Object.keys(plugin).sort(), [
    'activate',
    'discover',
    'getChapters',
    'getContent',
    'getDetail',
    'search',
    'searchSuggestions',
  ]);
  const descriptor = JSON.parse(
    await readFile(new URL('../package.json', import.meta.url), 'utf8'),
  );
  assert.equal(
    descriptor.mgread.id,
    'org.mgread.douyinxiaoshuo-biquge',
  );
  assert.equal(descriptor.mgread.packageMode, 'single-file');
  assert.deepEqual(descriptor.dependencies, { cheerio: '1.1.0' });
  assert.ok(
    Object.values(descriptor.dependencies).every(
      (dependency) => !dependency.startsWith('file:'),
    ),
  );
  const first = await buildPluginArtifact();
  const second = await buildPluginArtifact();
  assert.equal(first.format, 'singleFile');
  assert.deepEqual(first.bytes, second.bytes);
  const headerPrefix = Buffer.from('// @mgread-plugin-v1 ');
  const headerEnd = first.bytes.indexOf(10);
  const envelope = JSON.parse(
    Buffer.from(
      first.bytes.subarray(headerPrefix.length, headerEnd).toString('utf8'),
      'base64url',
    ).toString('utf8'),
  );
  const icon = await readFile(new URL('../assets/icon.png', import.meta.url));
  assert.equal(envelope.descriptor.mgread.icon, 'assets/icon.png');
  assert.equal(envelope.icon.mediaType, 'image/png');
  assert.deepEqual(Buffer.from(envelope.icon.data, 'base64'), icon);
});

test('source-local cache persists a bounded public text response', async (t) => {
  const cacheDir = await mkdtemp(join(tmpdir(), 'mgread-source-cache-'));
  t.after(() => rm(cacheDir, { recursive: true, force: true }));
  const cache = new BoundedTextCache(cacheDir);
  let fetches = 0;
  const fetcher = async () => {
    fetches += 1;
    return '<html>public fixture</html>';
  };
  const policy = { namespace: 'fixture', staleAfterMs: 60_000 };
  const url = new URL('https://example.invalid/list');
  assert.equal(
    await cache.getOrFetchText(url, policy, fetcher),
    '<html>public fixture</html>',
  );
  assert.equal(
    await cache.getOrFetchText(url, policy, fetcher),
    '<html>public fixture</html>',
  );
  assert.equal(fetches, 1);
});
