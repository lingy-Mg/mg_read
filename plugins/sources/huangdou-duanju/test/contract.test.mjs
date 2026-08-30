import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { buildPluginArtifact } from '../tools/mgread.mjs';

test('exports the standard source surface and deterministically packages video', async () => {
  assert.deepEqual(Object.keys(plugin).sort(), ['activate', 'discover', 'getChapters', 'getContent', 'getDetail', 'search', 'searchSuggestions']);
  const descriptor = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.deepEqual(descriptor.mgread.contentKinds, ['video']);
  const first = await buildPluginArtifact();
  const second = await buildPluginArtifact();
  assert.equal(first.format, 'singleFile');
  assert.deepEqual(first.bytes, second.bytes);
});
