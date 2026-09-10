/** Static exports, metadata and deterministic single-file artifact contract. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { buildPluginArtifact } from '../tools/mgread.mjs';

test('exports Plugin API v1 and builds a deterministic artifact', async () => {
  assert.deepEqual(Object.keys(plugin).sort(), ['activate', 'discover', 'getChapters', 'getContent', 'getDetail', 'search', 'searchSuggestions']);
  const descriptor = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(descriptor.mgread.id, 'org.mgread.jinpai-video');
  assert.equal(descriptor.mgread.displayName, '金牌影院');
  const first = await buildPluginArtifact();
  const second = await buildPluginArtifact();
  assert.deepEqual(first.bytes, second.bytes);
});
