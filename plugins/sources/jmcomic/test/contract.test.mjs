import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import * as plugin from '../dist/index.mjs';
import { buildPluginArtifact } from '../tools/mgread.mjs';

test('JM source exports the optional image handler and builds one deterministic artifact', async () => {
  assert.deepEqual(Object.keys(plugin).sort(), ['activate', 'discover', 'getChapters', 'getContent', 'getDetail', 'getResource', 'search', 'searchSuggestions']);
  const first = await buildPluginArtifact();
  const second = await buildPluginArtifact();
  const metadata = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(first.fileName, `${metadata.mgread.id}-${metadata.version}.mgplugin.js`);
  assert.deepEqual(first.bytes, second.bytes);
  assert.ok(first.bytes.byteLength < 32 * 1024 * 1024);
});
