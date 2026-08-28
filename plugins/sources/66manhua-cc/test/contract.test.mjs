import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { buildPluginArtifact } from '../tools/mgread.mjs';

test('exports Plugin API v1 and produces a deterministic single-file artifact', async () => {
  assert.deepEqual(Object.keys(plugin).sort(), ['activate', 'discover', 'getChapters', 'getContent', 'getDetail', 'resource', 'search', 'searchSuggestions']);
  const descriptor = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(descriptor.mgread.id, 'org.mgread.66manhua-cc');
  const first = await buildPluginArtifact(); const second = await buildPluginArtifact();
  assert.equal(first.format, 'singleFile'); assert.deepEqual(first.bytes, second.bytes); assert.ok(first.bytes.subarray(0, 24).toString().startsWith('// @mgread-plugin-v1 '));
});
