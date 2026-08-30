/** Static exports, descriptor and deterministic single-file artifact contract. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { buildPluginArtifact } from '../tools/mgread.mjs';
test('exports Plugin API v1 and builds a deterministic self-contained artifact', async () => {
  assert.deepEqual(Object.keys(plugin).sort(), ['activate', 'discover', 'getChapters', 'getContent', 'getDetail', 'search', 'searchSuggestions']);
  const descriptor = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(descriptor.mgread.id, 'org.mgread.35ge-info'); assert.equal(descriptor.mgread.displayName, '35小说'); assert.equal(descriptor.mgread.packageMode, 'single-file');
  const first = await buildPluginArtifact(); const second = await buildPluginArtifact();
  assert.equal(first.format, 'singleFile'); assert.deepEqual(first.bytes, second.bytes); assert.ok(first.bytes.subarray(0, 24).toString().startsWith('// @mgread-plugin-v1 ')); assert.equal(first.bytes.includes(Buffer.from('sourceMappingURL=')), false);
});
